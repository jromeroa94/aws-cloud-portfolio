"""Auditor de claves de cuentas de servicio (Cloud Run Job).

Las claves user-managed de una service account son credenciales de larga duración:
un fichero JSON que, si se filtra, da acceso al proyecto hasta que alguien lo
revoque. Son el equivalente en Google Cloud a las access keys de IAM en AWS, y la
recomendación de Google es no tenerlas: las cargas en GKE deben usar Workload
Identity y los operadores humanos impersonation (``--impersonate-service-account``).

Este job, lanzado por Cloud Scheduler, recorre las service accounts del proyecto y
clasifica cada clave user-managed activa:

  * ``user_managed_key`` (WARNING, ``review``): existe; debería sustituirse por
    Workload Identity o impersonation.
  * ``key_too_old`` (ERROR, ``rotate``): supera ``MAX_KEY_AGE_DAYS``.
  * ``key_expired_grace`` (CRITICAL, ``disable``): supera además ``GRACE_DAYS``.

Cada clave genera un único hallazgo, el más grave que le aplique. Las claves
``SYSTEM_MANAGED`` (las rota Google), las ya deshabilitadas y las cuentas en
``EXCLUDE_SA`` se ignoran.

Modo de ejecución
-----------------
Por defecto el auditor es **dry-run**: solo informa. Deshabilitar una clave puede
tumbar un sistema que todavía dependa de ella, así que esa acción exige activar
``ENFORCE=true`` de forma explícita, y aun entonces solo afecta a las claves que ya
agotaron el periodo de gracia (acción ``disable``). Se deshabilita, nunca se borra:
una clave deshabilitada se puede reactivar en segundos si algo se rompe.

Salida
------
Una línea JSON por hallazgo y una final de resumen, escritas a stdout. Cloud Run
las ingiere como logs estructurados y respeta el campo ``severity``, con lo que se
pueden crear alertas en Cloud Monitoring sin ningún agente adicional.

Códigos de salida: 0 si la API respondió (los hallazgos no son errores del job),
2 si la API o la configuración fallan.
"""

from __future__ import annotations

import json
import os
import sys
from collections import Counter
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any

from google.api_core import exceptions as api_exceptions
from google.auth import exceptions as auth_exceptions
from google.cloud import iam_admin_v1

SYSTEM_MANAGED = "SYSTEM_MANAGED"
USER_MANAGED = "USER_MANAGED"

SEVERITY_ORDER = ("WARNING", "ERROR", "CRITICAL")


@dataclass(frozen=True)
class KeyInfo:
    sa_email: str
    key_id: str
    key_type: str
    created: datetime
    disabled: bool


@dataclass(frozen=True)
class Finding:
    sa_email: str
    key_id: str
    finding: str
    severity: str
    age_days: int
    action: str


@dataclass(frozen=True)
class Settings:
    project_id: str
    max_key_age_days: int = 90
    grace_days: int = 14
    enforce: bool = False
    exclude_emails: tuple[str, ...] = ()

    @classmethod
    def from_env(cls) -> Settings:
        project_id = os.environ.get("PROJECT_ID", "").strip()
        if not project_id:
            raise ValueError("PROJECT_ID es obligatorio")
        return cls(
            project_id=project_id,
            max_key_age_days=int(os.environ.get("MAX_KEY_AGE_DAYS", "90")),
            grace_days=int(os.environ.get("GRACE_DAYS", "14")),
            enforce=_env_bool(os.environ.get("ENFORCE", "false")),
            exclude_emails=tuple(e.strip() for e in os.environ.get("EXCLUDE_SA", "").split(",") if e.strip()),
        )


def _env_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


# ---------------------------------------------------------------------------
# Lógica pura
# ---------------------------------------------------------------------------


def evaluate(
    keys: Iterable[KeyInfo],
    now: datetime,
    max_age_days: int,
    grace_days: int,
    exclude_emails: Iterable[str],
) -> list[Finding]:
    """Clasifica las claves; una clave produce como mucho un hallazgo, el más grave."""
    excluded = {email.strip().lower() for email in exclude_emails if email.strip()}
    findings: list[Finding] = []
    for key in keys:
        if key.key_type == SYSTEM_MANAGED or key.disabled or key.sa_email.lower() in excluded:
            continue
        age_days = (now - key.created).days
        if age_days > max_age_days + grace_days:
            finding, severity, action = "key_expired_grace", "CRITICAL", "disable"
        elif age_days > max_age_days:
            finding, severity, action = "key_too_old", "ERROR", "rotate"
        else:
            finding, severity, action = "user_managed_key", "WARNING", "review"
        findings.append(
            Finding(
                sa_email=key.sa_email,
                key_id=key.key_id,
                finding=finding,
                severity=severity,
                age_days=age_days,
                action=action,
            )
        )
    return findings


def describe(finding: Finding) -> str:
    """Mensaje legible para el campo ``message`` del log."""
    messages = {
        "user_managed_key": "clave user-managed activa ({age} días); migrar a Workload Identity o impersonation",
        "key_too_old": "clave con {age} días, supera el máximo permitido; rotar",
        "key_expired_grace": "clave con {age} días, agotado el periodo de gracia; deshabilitar",
    }
    return f"{finding.sa_email} key {finding.key_id}: " + messages[finding.finding].format(age=finding.age_days)


# ---------------------------------------------------------------------------
# Cliente IAM
# ---------------------------------------------------------------------------


def _to_key_info(sa_email: str, key: Any) -> KeyInfo:
    # name = projects/{p}/serviceAccounts/{email}/keys/{key_id}
    created = key.valid_after_time or datetime.now(UTC)
    if created.tzinfo is None:
        created = created.replace(tzinfo=UTC)
    key_type = key.key_type.name if hasattr(key.key_type, "name") else str(key.key_type)
    return KeyInfo(
        sa_email=sa_email,
        key_id=key.name.rsplit("/", 1)[-1],
        key_type=key_type,
        created=created,
        disabled=bool(key.disabled),
    )


class IamClient:
    """Envoltorio fino sobre ``iam_admin_v1.IAMClient``.

    El cliente real se crea en el constructor (necesita credenciales ADC); los tests
    sustituyen esta clase por un doble con la misma interfaz y no tocan la red.
    """

    def __init__(self, client: Any | None = None) -> None:
        self._client = client or iam_admin_v1.IAMClient()

    def list_service_accounts(self, project_id: str) -> list[str]:
        pager = self._client.list_service_accounts(name=f"projects/{project_id}")
        return [account.email for account in pager]

    def list_user_keys(self, sa_email: str) -> list[KeyInfo]:
        response = self._client.list_service_account_keys(
            name=f"projects/-/serviceAccounts/{sa_email}",
            key_types=[iam_admin_v1.ListServiceAccountKeysRequest.KeyType.USER_MANAGED],
        )
        return [_to_key_info(sa_email, key) for key in response.keys]

    def disable_key(self, sa_email: str, key_id: str) -> None:
        self._client.disable_service_account_key(name=f"projects/-/serviceAccounts/{sa_email}/keys/{key_id}")


# ---------------------------------------------------------------------------
# Ejecución
# ---------------------------------------------------------------------------


def _emit(record: dict[str, Any]) -> None:
    # Una línea JSON por evento: Cloud Run la convierte en una entrada estructurada de
    # Cloud Logging y usa ``severity`` como nivel.
    print(json.dumps(record, ensure_ascii=False, default=str), flush=True)


def run(client: Any, settings: Settings, now: datetime | None = None) -> dict[str, Any]:
    """Audita el proyecto, emite un JSON por hallazgo y devuelve el resumen."""
    now = now or datetime.now(UTC)
    by_severity: Counter[str] = Counter()
    by_action: Counter[str] = Counter()
    accounts = 0
    keys_total = 0
    enforced = 0

    for sa_email in client.list_service_accounts(settings.project_id):
        accounts += 1
        keys = client.list_user_keys(sa_email)
        keys_total += len(keys)
        findings = evaluate(keys, now, settings.max_key_age_days, settings.grace_days, settings.exclude_emails)
        for finding in findings:
            by_severity[finding.severity] += 1
            by_action[finding.action] += 1
            record: dict[str, Any] = {"severity": finding.severity, "message": describe(finding), **asdict(finding)}
            record["enforced"] = False
            if settings.enforce and finding.action == "disable":
                client.disable_key(finding.sa_email, finding.key_id)
                record["enforced"] = True
                enforced += 1
            _emit(record)

    summary = {
        "project_id": settings.project_id,
        "service_accounts": accounts,
        "user_managed_keys": keys_total,
        "findings": sum(by_severity.values()),
        "by_severity": {severity: by_severity.get(severity, 0) for severity in SEVERITY_ORDER},
        "by_action": dict(sorted(by_action.items())),
        "enforce": settings.enforce,
        "keys_disabled": enforced,
    }
    _emit({"severity": "INFO", "message": "iam-key-audit summary", "summary": summary})
    return summary


def main() -> int:
    try:
        settings = Settings.from_env()
    except ValueError as exc:
        _emit({"severity": "CRITICAL", "message": f"configuración inválida: {exc}"})
        return 2
    try:
        run(IamClient(), settings)
    except (api_exceptions.GoogleAPIError, auth_exceptions.GoogleAuthError) as exc:
        _emit({"severity": "CRITICAL", "message": "fallo al consultar la API de IAM", "error": str(exc)})
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
