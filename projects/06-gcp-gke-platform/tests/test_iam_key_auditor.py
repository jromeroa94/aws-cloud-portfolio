import json
from datetime import UTC, datetime, timedelta

import pytest
from google.api_core import exceptions as api_exceptions
from google.cloud import iam_admin_v1

import iam_key_auditor.auditor as auditor
from iam_key_auditor.auditor import IamClient, KeyInfo, Settings, evaluate, run

NOW = datetime(2026, 10, 2, 12, 0, tzinfo=UTC)
SA = "app@proyecto.iam.gserviceaccount.com"
SA_LEGACY = "legacy@proyecto.iam.gserviceaccount.com"


def key(sa_email=SA, key_id="k1", age_days=10, key_type="USER_MANAGED", disabled=False) -> KeyInfo:
    return KeyInfo(sa_email, key_id, key_type, NOW - timedelta(days=age_days), disabled)


def settings(**overrides) -> Settings:
    base = {"project_id": "proyecto", "max_key_age_days": 90, "grace_days": 14, "enforce": False}
    base.update(overrides)
    return Settings(**base)


class FakeIamClient:
    """Doble del envoltorio IamClient: sin red, registra las claves que se deshabilitan."""

    def __init__(self, keys_by_sa: dict[str, list[KeyInfo]]) -> None:
        self.keys_by_sa = keys_by_sa
        self.disabled: list[tuple[str, str]] = []

    def list_service_accounts(self, project_id: str) -> list[str]:
        return list(self.keys_by_sa)

    def list_user_keys(self, sa_email: str) -> list[KeyInfo]:
        return list(self.keys_by_sa[sa_email])

    def disable_key(self, sa_email: str, key_id: str) -> None:
        self.disabled.append((sa_email, key_id))


def evaluar(keys, **overrides):
    s = settings(**overrides)
    return evaluate(keys, NOW, s.max_key_age_days, s.grace_days, s.exclude_emails)


def lineas_json(capsys) -> list[dict]:
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


# ---------------------------------------------------------------------------
# evaluate(): lógica pura
# ---------------------------------------------------------------------------


def test_ignora_claves_system_managed():
    assert evaluar([key(key_type="SYSTEM_MANAGED", age_days=400)]) == []


def test_ignora_claves_deshabilitadas():
    assert evaluar([key(disabled=True, age_days=400)]) == []


def test_excluye_cuentas_de_servicio_sin_distinguir_mayusculas():
    keys = [key(sa_email=SA_LEGACY, age_days=400), key(sa_email=SA, age_days=5)]
    findings = evaluar(keys, exclude_emails=(SA_LEGACY.upper(),))
    assert [f.sa_email for f in findings] == [SA]


def test_clave_reciente_es_warning_con_accion_review():
    (finding,) = evaluar([key(age_days=30)])
    assert (finding.finding, finding.severity, finding.action, finding.age_days) == (
        "user_managed_key",
        "WARNING",
        "review",
        30,
    )


def test_clave_de_mas_de_90_dias_es_error_con_accion_rotate():
    (finding,) = evaluar([key(age_days=91)])
    assert (finding.finding, finding.severity, finding.action) == ("key_too_old", "ERROR", "rotate")


def test_en_el_limite_exacto_todavia_no_es_too_old():
    (finding,) = evaluar([key(age_days=90)])
    assert finding.severity == "WARNING"
    (finding,) = evaluar([key(age_days=104)])
    assert finding.severity == "ERROR"


def test_clave_de_mas_de_104_dias_es_critical_con_accion_disable():
    (finding,) = evaluar([key(age_days=105)])
    assert (finding.finding, finding.severity, finding.action) == ("key_expired_grace", "CRITICAL", "disable")


def test_umbrales_configurables():
    (finding,) = evaluar([key(age_days=40)], max_key_age_days=30, grace_days=5)
    assert finding.severity == "CRITICAL"


def test_una_clave_genera_un_solo_finding_el_mas_grave():
    keys = [key(key_id="k1", age_days=10), key(key_id="k2", age_days=95), key(key_id="k3", age_days=200)]
    findings = evaluar(keys)
    assert [f.key_id for f in findings] == ["k1", "k2", "k3"]
    assert [f.severity for f in findings] == ["WARNING", "ERROR", "CRITICAL"]


# ---------------------------------------------------------------------------
# run(): orquestación y salida
# ---------------------------------------------------------------------------


def test_dry_run_no_deshabilita_nada(capsys):
    client = FakeIamClient({SA: [key(key_id="vieja", age_days=300)]})

    summary = run(client, settings(enforce=False), now=NOW)

    assert client.disabled == []
    assert summary["by_severity"]["CRITICAL"] == 1
    assert summary["keys_disabled"] == 0
    finding_line = lineas_json(capsys)[0]
    assert finding_line["action"] == "disable"
    assert finding_line["enforced"] is False


def test_enforce_deshabilita_solo_las_critical(capsys):
    client = FakeIamClient(
        {
            SA: [key(key_id="reciente", age_days=10), key(key_id="rotar", age_days=95)],
            SA_LEGACY: [key(sa_email=SA_LEGACY, key_id="caducada", age_days=120)],
        }
    )

    summary = run(client, settings(enforce=True), now=NOW)

    assert client.disabled == [(SA_LEGACY, "caducada")]
    assert summary["keys_disabled"] == 1
    enforced = {line["key_id"]: line["enforced"] for line in lineas_json(capsys) if "key_id" in line}
    assert enforced == {"reciente": False, "rotar": False, "caducada": True}


def test_resumen_con_conteos_correctos(capsys):
    client = FakeIamClient(
        {
            SA: [key(key_id="a", age_days=1), key(key_id="b", age_days=2), key(key_id="c", age_days=95)],
            SA_LEGACY: [key(sa_email=SA_LEGACY, key_id="d", age_days=500, key_type="SYSTEM_MANAGED")],
            "vacia@proyecto.iam.gserviceaccount.com": [],
        }
    )

    summary = run(client, settings(), now=NOW)

    assert summary["service_accounts"] == 3
    assert summary["user_managed_keys"] == 4
    assert summary["findings"] == 3
    assert summary["by_severity"] == {"WARNING": 2, "ERROR": 1, "CRITICAL": 0}
    assert summary["by_action"] == {"review": 2, "rotate": 1}
    assert summary["enforce"] is False


def test_salida_es_un_json_por_linea(capsys):
    client = FakeIamClient({SA: [key(key_id="k1", age_days=10), key(key_id="k2", age_days=120)]})

    run(client, settings(), now=NOW)

    lines = lineas_json(capsys)
    assert len(lines) == 3
    for line in lines[:2]:
        assert set(line) >= {"severity", "message", "finding", "sa_email", "key_id", "age_days", "action"}
        assert line["sa_email"] == SA
    assert lines[0]["severity"] == "WARNING" and lines[1]["severity"] == "CRITICAL"
    assert lines[2]["severity"] == "INFO"
    assert lines[2]["message"] == "iam-key-audit summary"
    assert lines[2]["summary"]["findings"] == 2


def test_sin_hallazgos_solo_se_emite_el_resumen(capsys):
    summary = run(FakeIamClient({SA: []}), settings(), now=NOW)
    assert summary["findings"] == 0
    assert [line["message"] for line in lineas_json(capsys)] == ["iam-key-audit summary"]


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------


def test_settings_desde_env(monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "mi-proyecto")
    monkeypatch.setenv("MAX_KEY_AGE_DAYS", "60")
    monkeypatch.setenv("GRACE_DAYS", "7")
    monkeypatch.setenv("ENFORCE", "true")
    monkeypatch.setenv("EXCLUDE_SA", f"{SA_LEGACY}, otra@proyecto.iam.gserviceaccount.com ,")

    s = Settings.from_env()

    assert s.project_id == "mi-proyecto"
    assert (s.max_key_age_days, s.grace_days, s.enforce) == (60, 7, True)
    assert s.exclude_emails == (SA_LEGACY, "otra@proyecto.iam.gserviceaccount.com")


def test_settings_valores_por_defecto(monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "p")
    for name in ("MAX_KEY_AGE_DAYS", "GRACE_DAYS", "ENFORCE", "EXCLUDE_SA"):
        monkeypatch.delenv(name, raising=False)
    s = Settings.from_env()
    assert (s.max_key_age_days, s.grace_days, s.enforce, s.exclude_emails) == (90, 14, False, ())


@pytest.mark.parametrize(
    ("value", "expected"),
    [("true", True), ("TRUE", True), ("1", True), ("yes", True), ("false", False), ("0", False), ("", False)],
)
def test_settings_enforce_acepta_varias_grafias(monkeypatch, value, expected):
    monkeypatch.setenv("PROJECT_ID", "p")
    monkeypatch.setenv("ENFORCE", value)
    assert Settings.from_env().enforce is expected


def test_settings_project_id_obligatorio(monkeypatch):
    monkeypatch.delenv("PROJECT_ID", raising=False)
    with pytest.raises(ValueError, match="PROJECT_ID"):
        Settings.from_env()


# ---------------------------------------------------------------------------
# IamClient: traducción de los mensajes de la API (sin credenciales)
# ---------------------------------------------------------------------------


class FakeGapicClient:
    """Imita la superficie de iam_admin_v1.IAMClient que usa el envoltorio."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def list_service_accounts(self, name: str):
        self.calls.append(("list_service_accounts", name))
        return [iam_admin_v1.ServiceAccount(email=SA), iam_admin_v1.ServiceAccount(email=SA_LEGACY)]

    def list_service_account_keys(self, name: str, key_types):
        self.calls.append(("list_service_account_keys", name, list(key_types)))
        return iam_admin_v1.ListServiceAccountKeysResponse(
            keys=[
                iam_admin_v1.ServiceAccountKey(
                    name=f"projects/proyecto/serviceAccounts/{SA}/keys/abc123",
                    key_type=iam_admin_v1.ListServiceAccountKeysRequest.KeyType.USER_MANAGED,
                    valid_after_time=datetime(2026, 1, 15, tzinfo=UTC),
                    disabled=True,
                )
            ]
        )

    def disable_service_account_key(self, name: str) -> None:
        self.calls.append(("disable_service_account_key", name))


def test_iam_client_traduce_cuentas_y_claves():
    gapic = FakeGapicClient()
    client = IamClient(gapic)

    assert client.list_service_accounts("proyecto") == [SA, SA_LEGACY]
    (info,) = client.list_user_keys(SA)
    client.disable_key(SA, "abc123")

    assert info == KeyInfo(SA, "abc123", "USER_MANAGED", datetime(2026, 1, 15, tzinfo=UTC), True)
    assert gapic.calls == [
        ("list_service_accounts", "projects/proyecto"),
        (
            "list_service_account_keys",
            f"projects/-/serviceAccounts/{SA}",
            [iam_admin_v1.ListServiceAccountKeysRequest.KeyType.USER_MANAGED],
        ),
        ("disable_service_account_key", f"projects/-/serviceAccounts/{SA}/keys/abc123"),
    ]


# ---------------------------------------------------------------------------
# main(): códigos de salida
# ---------------------------------------------------------------------------


def test_main_devuelve_0_aunque_haya_hallazgos(monkeypatch, capsys):
    monkeypatch.setenv("PROJECT_ID", "proyecto")
    monkeypatch.setattr(auditor, "IamClient", lambda: FakeIamClient({SA: [key(age_days=300)]}))

    assert auditor.main() == 0
    assert lineas_json(capsys)[-1]["summary"]["by_severity"]["CRITICAL"] == 1


def test_main_devuelve_2_si_falla_la_api(monkeypatch, capsys):
    monkeypatch.setenv("PROJECT_ID", "proyecto")

    class ClienteRoto(FakeIamClient):
        def list_service_accounts(self, project_id: str) -> list[str]:
            raise api_exceptions.PermissionDenied("iam.serviceAccounts.list denegado")

    monkeypatch.setattr(auditor, "IamClient", lambda: ClienteRoto({}))

    assert auditor.main() == 2
    (line,) = lineas_json(capsys)
    assert line["severity"] == "CRITICAL"
    assert "denegado" in line["error"]


def test_main_devuelve_2_sin_project_id(monkeypatch, capsys):
    monkeypatch.delenv("PROJECT_ID", raising=False)
    assert auditor.main() == 2
    assert lineas_json(capsys)[0]["severity"] == "CRITICAL"
