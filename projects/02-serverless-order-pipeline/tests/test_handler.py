import json
from decimal import Decimal
from unittest.mock import patch

import pytest
from botocore.exceptions import ClientError
from conftest import BUCKET, published_events, s3_event_message

from order_processor.handler import ValidationError, parse_order


def valid_order(**overrides):
    order = {
        "order_id": "ORD-1001",
        "customer_id": "CUS-42",
        "currency": "CLP",
        "items": [
            {"sku": "SKU-A", "quantity": 2, "unit_price": 12990},
            {"sku": "SKU-B", "quantity": 1, "unit_price": 4990},
        ],
    }
    order.update(overrides)
    return order


def put_order(aws, key, document):
    aws["s3"].put_object(Bucket=BUCKET, Key=key, Body=json.dumps(document).encode())


# ---------------------------------------------------------------------------
# Validación pura (sin AWS)
# ---------------------------------------------------------------------------
class TestParseOrder:
    def test_calcula_total_en_clp_sin_decimales(self):
        order = parse_order(valid_order())
        assert order.total == Decimal("30970")
        assert order.requires_shipping is True

    def test_redondea_a_centavos_en_usd(self):
        doc = valid_order(currency="USD", items=[{"sku": "X", "quantity": 3, "unit_price": "0.335"}])
        assert parse_order(doc).total == Decimal("1.00")

    def test_evita_errores_de_coma_flotante(self):
        doc = valid_order(currency="USD", items=[{"sku": "X", "quantity": 1, "unit_price": "0.1"}] * 3)
        assert parse_order(doc).total == Decimal("0.30")

    @pytest.mark.parametrize(
        "overrides, mensaje",
        [
            ({"currency": "EUR"}, "moneda no soportada"),
            ({"items": []}, "lista no vacía"),
            ({"order_id": "  "}, "order_id"),
            ({"items": [{"sku": "A", "quantity": 0, "unit_price": 10}]}, "entero positivo"),
            ({"items": [{"sku": "A", "quantity": True, "unit_price": 10}]}, "entero positivo"),
            ({"items": [{"sku": "A", "quantity": 1, "unit_price": -5}]}, "mayor que cero"),
            ({"items": [{"sku": "A", "quantity": 1, "unit_price": "abc"}]}, "numérico"),
            ({"requires_shipping": "si"}, "booleano"),
        ],
    )
    def test_rechaza_pedidos_invalidos(self, overrides, mensaje):
        with pytest.raises(ValidationError, match=mensaje):
            parse_order(valid_order(**overrides))

    def test_rechaza_campos_faltantes(self):
        doc = valid_order()
        del doc["customer_id"]
        with pytest.raises(ValidationError, match="customer_id"):
            parse_order(doc)


# ---------------------------------------------------------------------------
# Flujo completo con AWS simulado (moto)
# ---------------------------------------------------------------------------
class TestHandler:
    def test_pedido_valido_se_guarda_y_se_publica(self, aws):
        put_order(aws, "incoming/ord-1001.json", valid_order())

        result = aws["handler"].handler({"Records": [s3_event_message("incoming/ord-1001.json")]})

        assert result == {"batchItemFailures": []}
        item = aws["table"].get_item(Key={"order_id": "ORD-1001"})["Item"]
        assert item["status"] == "ACCEPTED"
        assert item["total"] == Decimal("30970")
        assert item["event_published"] is True

        events = published_events(aws)
        assert [e["event_type"] for e in events] == ["order.accepted"]
        assert events[0]["total"] == "30970"

    @pytest.mark.parametrize(
        "clave_en_evento",
        ["incoming/pedido 1001.json", "incoming/pedido+1001.json"],
        ids=["literal-eventbridge", "url-encoded-notificacion-clasica"],
    )
    def test_clave_con_espacios(self, aws, clave_en_evento):
        put_order(aws, "incoming/pedido 1001.json", valid_order())
        result = aws["handler"].handler({"Records": [s3_event_message(clave_en_evento)]})
        assert result == {"batchItemFailures": []}
        assert published_events(aws)[0]["event_type"] == "order.accepted"

    def test_duplicado_no_se_publica_dos_veces(self, aws):
        put_order(aws, "incoming/a.json", valid_order())
        put_order(aws, "incoming/a-copia.json", valid_order())

        aws["handler"].handler(
            {
                "Records": [
                    s3_event_message("incoming/a.json", "m1"),
                    s3_event_message("incoming/a-copia.json", "m2"),
                ]
            }
        )

        assert len(published_events(aws)) == 1

    def test_pedido_invalido_se_rechaza_sin_reintentar(self, aws):
        put_order(aws, "incoming/bad.json", valid_order(currency="EUR"))

        result = aws["handler"].handler({"Records": [s3_event_message("incoming/bad.json")]})

        assert result == {"batchItemFailures": []}
        assert "Item" not in aws["table"].get_item(Key={"order_id": "ORD-1001"})
        events = published_events(aws)
        assert events[0]["event_type"] == "order.rejected"
        assert "moneda" in events[0]["reason"]

    def test_json_corrupto_se_rechaza(self, aws):
        aws["s3"].put_object(Bucket=BUCKET, Key="incoming/x.json", Body=b"{no es json")
        result = aws["handler"].handler({"Records": [s3_event_message("incoming/x.json")]})
        assert result == {"batchItemFailures": []}
        assert published_events(aws)[0]["event_type"] == "order.rejected"

    def test_mensaje_que_no_es_evento_s3_se_descarta(self, aws):
        result = aws["handler"].handler({"Records": [{"messageId": "m1", "body": "hola"}]})
        assert result == {"batchItemFailures": []}

    def test_fallo_transitorio_solo_reintenta_ese_mensaje(self, aws):
        put_order(aws, "incoming/ok.json", valid_order(order_id="ORD-OK"))
        put_order(aws, "incoming/fail.json", valid_order(order_id="ORD-FAIL"))

        processor = aws["handler"]._get_processor()
        real_put = processor.table.put_item
        throttle = ClientError(
            {"Error": {"Code": "ProvisionedThroughputExceededException", "Message": "slow down"}},
            "PutItem",
        )

        def flaky_put(**kwargs):
            if kwargs["Item"]["order_id"] == "ORD-FAIL":
                raise throttle
            return real_put(**kwargs)

        with patch.object(processor.table, "put_item", side_effect=flaky_put):
            result = aws["handler"].handler(
                {
                    "Records": [
                        s3_event_message("incoming/ok.json", "m-ok"),
                        s3_event_message("incoming/fail.json", "m-fail"),
                    ]
                }
            )

        assert result == {"batchItemFailures": [{"itemIdentifier": "m-fail"}]}

    def test_si_sns_falla_el_reintento_publica_el_evento_pendiente(self, aws):
        put_order(aws, "incoming/a.json", valid_order())
        processor = aws["handler"]._get_processor()
        sns_down = ClientError({"Error": {"Code": "InternalError", "Message": "boom"}}, "Publish")

        with patch.object(processor.sns, "publish", side_effect=sns_down):
            first = aws["handler"].handler({"Records": [s3_event_message("incoming/a.json", "m1")]})
        assert first == {"batchItemFailures": [{"itemIdentifier": "m1"}]}
        assert published_events(aws) == []

        # SQS vuelve a entregar el mensaje: el pedido ya existe pero sin publicar.
        second = aws["handler"].handler({"Records": [s3_event_message("incoming/a.json", "m1")]})
        assert second == {"batchItemFailures": []}
        assert [e["event_type"] for e in published_events(aws)] == ["order.accepted"]
        assert aws["table"].get_item(Key={"order_id": "ORD-1001"})["Item"]["event_published"] is True

    def test_objeto_inexistente_no_bloquea_el_lote(self, aws):
        result = aws["handler"].handler({"Records": [s3_event_message("incoming/no-existe.json")]})
        assert result == {"batchItemFailures": []}
        assert published_events(aws)[0]["event_type"] == "order.rejected"
