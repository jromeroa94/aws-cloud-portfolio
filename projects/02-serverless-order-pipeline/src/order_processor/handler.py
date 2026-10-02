"""Procesador de pedidos: S3 -> EventBridge -> SQS -> Lambda -> DynamoDB + SNS (fan-out).

Diseño:
  * Idempotente: el pedido se inserta con una escritura condicional y se marca como
    publicado solo después de enviarlo a SNS. Si la publicación falla, el reintento
    encuentra el pedido sin marcar y lo vuelve a publicar (entrega "al menos una vez";
    los consumidores deduplican por order_id). Un duplicado ya publicado se ignora.
  * Fallos parciales de lote: solo se reintentan los mensajes que fallaron por causas
    transitorias (throttling, errores 5xx). Los pedidos inválidos no se reintentan
    nunca: se publican como ``order.rejected`` para que alguien los revise.
  * Sin dependencias externas: solo biblioteca estándar + boto3 del runtime de Lambda.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
SUPPORTED_CURRENCIES = frozenset({"CLP", "USD", "PEN"})
MAX_OBJECT_BYTES = 256 * 1024

# Códigos de error de AWS que sí merece la pena reintentar.
RETRYABLE_ERROR_CODES = frozenset(
    {
        "ProvisionedThroughputExceededException",
        "ThrottlingException",
        "Throttling",
        "RequestLimitExceeded",
        "InternalServerError",
        "InternalError",
        "ServiceUnavailable",
        "SlowDown",
    }
)


class JsonFormatter(logging.Formatter):
    """Logs en JSON de una línea: consultables con CloudWatch Logs Insights."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
        }
        payload.update(getattr(record, "extra_fields", {}))
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


logger = logging.getLogger("order_processor")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(JsonFormatter())
    logger.addHandler(_handler)
logger.setLevel(LOG_LEVEL)
logger.propagate = False


def log(level: int, message: str, **fields: Any) -> None:
    logger.log(level, message, extra={"extra_fields": fields})


class ValidationError(Exception):
    """El pedido es inválido: reintentar no lo arreglará."""


class TransientError(Exception):
    """Fallo temporal: el mensaje debe volver a la cola."""


@dataclass(frozen=True)
class Order:
    order_id: str
    customer_id: str
    currency: str
    items: list[dict[str, Any]]
    total: Decimal
    requires_shipping: bool

    def to_item(self, source: str) -> dict[str, Any]:
        return {
            "order_id": self.order_id,
            "customer_id": self.customer_id,
            "currency": self.currency,
            "items": self.items,
            "total": self.total,
            "requires_shipping": self.requires_shipping,
            "status": "ACCEPTED",
            "event_published": False,
            "source": source,
            "created_at": datetime.now(UTC).isoformat(),
        }

    def to_event(self) -> dict[str, Any]:
        return {
            "event_type": "order.accepted",
            "order_id": self.order_id,
            "customer_id": self.customer_id,
            "currency": self.currency,
            "total": str(self.total),
            "item_count": sum(int(i["quantity"]) for i in self.items),
            "requires_shipping": self.requires_shipping,
        }


def _to_decimal(value: Any, field: str) -> Decimal:
    if isinstance(value, bool):
        raise ValidationError(f"{field} debe ser numérico")
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise ValidationError(f"{field} debe ser numérico") from exc
    if not number.is_finite():
        raise ValidationError(f"{field} debe ser finito")
    return number


def parse_order(document: dict[str, Any]) -> Order:
    """Valida el documento de pedido y calcula el total con aritmética decimal."""
    if not isinstance(document, dict):
        raise ValidationError("el pedido debe ser un objeto JSON")

    for field in ("order_id", "customer_id", "currency", "items"):
        if field not in document:
            raise ValidationError(f"falta el campo obligatorio '{field}'")

    order_id = document["order_id"]
    customer_id = document["customer_id"]
    if not isinstance(order_id, str) or not order_id.strip():
        raise ValidationError("order_id debe ser un texto no vacío")
    if not isinstance(customer_id, str) or not customer_id.strip():
        raise ValidationError("customer_id debe ser un texto no vacío")

    currency = document["currency"]
    if currency not in SUPPORTED_CURRENCIES:
        raise ValidationError(f"moneda no soportada: {currency!r}")

    items = document["items"]
    if not isinstance(items, list) or not items:
        raise ValidationError("items debe ser una lista no vacía")

    clean_items: list[dict[str, Any]] = []
    total = Decimal("0")
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValidationError(f"items[{index}] debe ser un objeto")
        sku = item.get("sku")
        if not isinstance(sku, str) or not sku.strip():
            raise ValidationError(f"items[{index}].sku es obligatorio")

        quantity = item.get("quantity")
        if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity <= 0:
            raise ValidationError(f"items[{index}].quantity debe ser un entero positivo")

        unit_price = _to_decimal(item.get("unit_price"), f"items[{index}].unit_price")
        if unit_price <= 0:
            raise ValidationError(f"items[{index}].unit_price debe ser mayor que cero")

        clean_items.append({"sku": sku.strip(), "quantity": quantity, "unit_price": unit_price})
        total += unit_price * quantity

    # CLP no tiene decimales; USD y PEN usan dos.
    exponent = Decimal("1") if currency == "CLP" else Decimal("0.01")
    total = total.quantize(exponent)

    requires_shipping = document.get("requires_shipping", True)
    if not isinstance(requires_shipping, bool):
        raise ValidationError("requires_shipping debe ser booleano")

    return Order(
        order_id=order_id.strip(),
        customer_id=customer_id.strip(),
        currency=currency,
        items=clean_items,
        total=total,
        requires_shipping=requires_shipping,
    )


def extract_s3_location(sqs_body: str) -> tuple[str, str]:
    """Obtiene bucket y clave de un evento 'Object Created' de EventBridge."""
    try:
        event = json.loads(sqs_body)
        detail = event["detail"]
        return detail["bucket"]["name"], detail["object"]["key"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise ValidationError("el mensaje no es un evento 'Object Created' de S3") from exc


def _is_retryable(error: ClientError) -> bool:
    code = error.response.get("Error", {}).get("Code", "")
    status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 0)
    return code in RETRYABLE_ERROR_CODES or status >= 500


class OrderProcessor:
    def __init__(self, s3_client: Any, table: Any, sns_client: Any, topic_arn: str) -> None:
        self.s3 = s3_client
        self.table = table
        self.sns = sns_client
        self.topic_arn = topic_arn

    def _get_object(self, bucket: str, key: str) -> dict[str, Any]:
        """Lee el objeto tolerando claves URL-encoded (formato de las notificaciones
        clásicas de S3) además de claves literales (formato de EventBridge)."""
        candidates = [key]
        decoded = unquote_plus(key)
        if decoded != key:
            candidates.append(decoded)

        for index, candidate in enumerate(candidates):
            try:
                return self.s3.get_object(Bucket=bucket, Key=candidate)
            except ClientError as exc:
                if _is_retryable(exc):
                    raise TransientError(str(exc)) from exc
                code = exc.response.get("Error", {}).get("Code", "")
                if code in ("NoSuchKey", "404") and index + 1 < len(candidates):
                    continue
                raise ValidationError(f"no se pudo leer s3://{bucket}/{key}: {exc}") from exc
        raise ValidationError(f"no se pudo leer s3://{bucket}/{key}")  # pragma: no cover

    def _load_document(self, bucket: str, key: str) -> dict[str, Any]:
        response = self._get_object(bucket, key)

        if response.get("ContentLength", 0) > MAX_OBJECT_BYTES:
            raise ValidationError(f"el archivo supera {MAX_OBJECT_BYTES} bytes")

        try:
            return json.loads(response["Body"].read(), parse_float=Decimal)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ValidationError("el archivo no es JSON válido") from exc

    def _publish(self, event: dict[str, Any]) -> None:
        try:
            self.sns.publish(
                TopicArn=self.topic_arn,
                Message=json.dumps(event, default=str),
                MessageAttributes={
                    "event_type": {"DataType": "String", "StringValue": event["event_type"]},
                    "requires_shipping": {
                        "DataType": "String",
                        "StringValue": str(event.get("requires_shipping", False)).lower(),
                    },
                },
            )
        except ClientError as exc:
            raise TransientError(f"error publicando en SNS: {exc}") from exc

    def process(self, sqs_body: str) -> str:
        """Procesa un mensaje. Devuelve 'accepted', 'duplicate' o 'rejected'."""
        bucket, key = extract_s3_location(sqs_body)
        source = f"s3://{bucket}/{key}"

        try:
            order = parse_order(self._load_document(bucket, key))
        except ValidationError as exc:
            log(logging.WARNING, "pedido rechazado", source=source, reason=str(exc))
            self._publish({"event_type": "order.rejected", "source": source, "reason": str(exc)})
            return "rejected"

        try:
            self.table.put_item(
                Item=order.to_item(source),
                ConditionExpression="attribute_not_exists(order_id)",
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise TransientError(f"error escribiendo en DynamoDB: {exc}") from exc
            if self._already_published(order.order_id):
                log(logging.INFO, "pedido duplicado ignorado", order_id=order.order_id, source=source)
                return "duplicate"
            # Existe pero su evento no llegó a SNS en un intento anterior: se completa.
            log(logging.INFO, "reanudando publicación pendiente", order_id=order.order_id)

        self._publish(order.to_event())
        self._mark_published(order.order_id)
        log(
            logging.INFO,
            "pedido aceptado",
            order_id=order.order_id,
            total=str(order.total),
            currency=order.currency,
        )
        return "accepted"

    def _already_published(self, order_id: str) -> bool:
        try:
            item = self.table.get_item(Key={"order_id": order_id}, ConsistentRead=True).get("Item")
        except ClientError as exc:
            raise TransientError(f"error leyendo DynamoDB: {exc}") from exc
        return bool(item and item.get("event_published"))

    def _mark_published(self, order_id: str) -> None:
        try:
            self.table.update_item(
                Key={"order_id": order_id},
                UpdateExpression="SET event_published = :true, published_at = :now",
                ExpressionAttributeValues={
                    ":true": True,
                    ":now": datetime.now(UTC).isoformat(),
                },
            )
        except ClientError as exc:
            # El evento ya salió; si esto falla, el reintento lo publicará otra vez
            # (los consumidores deduplican por order_id).
            raise TransientError(f"error marcando el pedido como publicado: {exc}") from exc


_processor: OrderProcessor | None = None


def _get_processor() -> OrderProcessor:
    """Clientes creados una vez por contenedor (reutilizados entre invocaciones)."""
    global _processor
    if _processor is None:
        dynamodb = boto3.resource("dynamodb")
        _processor = OrderProcessor(
            s3_client=boto3.client("s3"),
            table=dynamodb.Table(os.environ["TABLE_NAME"]),
            sns_client=boto3.client("sns"),
            topic_arn=os.environ["TOPIC_ARN"],
        )
    return _processor


def handler(event: dict[str, Any], context: Any = None) -> dict[str, list[dict[str, str]]]:
    """Punto de entrada de Lambda para un lote SQS con ReportBatchItemFailures."""
    processor = _get_processor()
    failures: list[dict[str, str]] = []
    summary = {"accepted": 0, "duplicate": 0, "rejected": 0, "retry": 0}

    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            outcome = processor.process(record["body"])
            summary[outcome] += 1
        except ValidationError as exc:
            # Mensaje que no es un evento de S3: no tiene sentido reintentarlo.
            log(logging.ERROR, "mensaje descartado", message_id=message_id, reason=str(exc))
            summary["rejected"] += 1
        except TransientError as exc:
            log(logging.WARNING, "fallo transitorio, se reintentará", message_id=message_id, error=str(exc))
            failures.append({"itemIdentifier": message_id})
            summary["retry"] += 1
        except Exception:
            logger.exception("error inesperado", extra={"extra_fields": {"message_id": message_id}})
            failures.append({"itemIdentifier": message_id})
            summary["retry"] += 1

    log(logging.INFO, "lote procesado", **summary)
    return {"batchItemFailures": failures}
