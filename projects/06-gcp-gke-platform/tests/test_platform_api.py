import functools
import io
import json
import logging
import signal
import threading
from datetime import datetime

import httpx
import pytest
from fastapi.testclient import TestClient

import platform_api.main as main
from platform_api.main import JsonFormatter, Metrics, Settings, fetch_zone, parse_zone, trace_fields

ZONE_RAW = "projects/123456789/zones/us-central1-a"


@pytest.fixture(autouse=True)
def estado_limpio(monkeypatch):
    """Cada test arranca listo, con métricas vacías y sin tocar el metadata server."""
    main.mark_ready()
    monkeypatch.setattr(main, "metrics", Metrics.create())
    monkeypatch.setattr(main, "fetch_zone", lambda: "unknown")
    yield
    main.mark_ready()


@pytest.fixture
def entorno(monkeypatch):
    """Fija variables de entorno y reconstruye ``settings`` como haría un arranque real."""

    def aplicar(**variables: str) -> Settings:
        for name, value in variables.items():
            monkeypatch.setenv(name, value)
        nuevo = Settings.from_env()
        monkeypatch.setattr(main, "settings", nuevo)
        return nuevo

    return aplicar


@pytest.fixture
def client():
    with TestClient(main.app) as test_client:
        yield test_client


@pytest.fixture
def log_lines():
    """Captura lo que emite el logger de peticiones ya formateado en JSON."""
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter())
    main.request_logger.addHandler(handler)
    main.request_logger.setLevel(logging.INFO)
    yield lambda: [json.loads(line) for line in stream.getvalue().splitlines()]
    main.request_logger.removeHandler(handler)


def metadata_factory(handler):
    return lambda: httpx.Client(transport=httpx.MockTransport(handler))


# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------


def test_healthz_ok(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_ok_antes_del_apagado(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_503_tras_mark_shutdown(client):
    main.mark_shutdown()
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json() == {"status": "draining"}
    # El liveness no cambia: el proceso sigue vivo y no debe reiniciarse.
    assert client.get("/healthz").status_code == 200


def test_mark_ready_revierte_el_drenaje(client):
    main.mark_shutdown()
    assert client.get("/readyz").status_code == 503
    main.mark_ready()
    assert client.get("/readyz").status_code == 200


def test_sigterm_marca_draining_y_reenvia_la_senal():
    if threading.current_thread() is not threading.main_thread():
        pytest.skip("los manejadores de señal solo se instalan en el hilo principal")
    reenviada = threading.Event()

    def manejador_uvicorn(signum, frame):
        reenviada.set()

    original = signal.signal(signal.SIGTERM, manejador_uvicorn)
    try:
        assert main.install_sigterm_handler(drain_seconds=0.2) is True
        signal.raise_signal(signal.SIGTERM)
        assert main.is_draining()
        assert not reenviada.is_set(), "la señal no debe llegar a uvicorn hasta terminar el drenaje"
        assert reenviada.wait(timeout=3.0)
    finally:
        signal.signal(signal.SIGTERM, original)


# ---------------------------------------------------------------------------
# Versión e identidad
# ---------------------------------------------------------------------------


def test_version_desde_env(client, entorno):
    entorno(APP_VERSION="1.4.2", GIT_SHA="abc1234", BUILD_DATE="2026-10-02T10:00:00Z")
    assert client.get("/version").json() == {
        "version": "1.4.2",
        "commit": "abc1234",
        "build_date": "2026-10-02T10:00:00Z",
    }


def test_version_valores_por_defecto(client, monkeypatch, entorno):
    for name in ("APP_VERSION", "GIT_SHA", "BUILD_DATE"):
        monkeypatch.delenv(name, raising=False)
    entorno()
    assert client.get("/version").json() == {"version": "dev", "commit": "unknown", "build_date": "unknown"}


def test_whoami_identidad_del_pod_y_zona_de_metadata(monkeypatch, entorno):
    entorno(POD_NAME="api-7d9f-x1", NODE_NAME="gke-pool-1-abc", POD_NAMESPACE="platform", APP_VERSION="2.0.0")

    def metadata(request: httpx.Request) -> httpx.Response:
        assert request.headers["Metadata-Flavor"] == "Google"
        assert str(request.url) == main.ZONE_URL
        return httpx.Response(200, text=ZONE_RAW)

    monkeypatch.setattr(main, "fetch_zone", functools.partial(fetch_zone, client_factory=metadata_factory(metadata)))

    with TestClient(main.app) as client:
        assert client.get("/api/v1/whoami").json() == {
            "pod": "api-7d9f-x1",
            "node": "gke-pool-1-abc",
            "namespace": "platform",
            "zone": "us-central1-a",
            "version": "2.0.0",
        }


def test_whoami_zona_unknown_si_metadata_no_responde(monkeypatch, entorno):
    entorno(POD_NAME="api-1")

    def sin_red(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("metadata.google.internal no resuelve", request=request)

    monkeypatch.setattr(main, "fetch_zone", functools.partial(fetch_zone, client_factory=metadata_factory(sin_red)))

    with TestClient(main.app) as client:
        body = client.get("/api/v1/whoami").json()
    assert body["zone"] == "unknown"
    assert body["pod"] == "api-1"


def test_fetch_zone_unknown_con_error_http():
    factory = metadata_factory(lambda request: httpx.Response(500, text="boom"))
    assert fetch_zone(client_factory=factory) == "unknown"


def test_parse_zone_se_queda_con_el_ultimo_segmento():
    assert parse_zone(ZONE_RAW) == "us-central1-a"
    assert parse_zone("europe-southwest1-b\n") == "europe-southwest1-b"
    with pytest.raises(ValueError, match="sin zona"):
        parse_zone("projects/123/zones/")


# ---------------------------------------------------------------------------
# Métricas
# ---------------------------------------------------------------------------


def test_metricas_cuentan_por_plantilla_de_ruta(client):
    client.get("/healthz")
    client.get("/healthz")

    labels = {"method": "GET", "route": "/healthz", "status": "200"}
    assert main.metrics.registry.get_sample_value("http_requests_total", labels) == 2.0

    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert 'http_requests_total{method="GET",route="/healthz",status="200"} 2.0' in response.text


def test_ruta_desconocida_se_agrupa_como_unmatched(client):
    assert client.get("/no-existe/42").status_code == 404
    assert client.get("/otra-cosa").status_code == 404

    labels = {"method": "GET", "route": "unmatched", "status": "404"}
    assert main.metrics.registry.get_sample_value("http_requests_total", labels) == 2.0
    assert "/no-existe" not in client.get("/metrics").text


def test_histograma_de_latencia_por_ruta(client):
    client.get("/version")
    labels = {"method": "GET", "route": "/version"}
    assert main.metrics.registry.get_sample_value("http_request_duration_seconds_count", labels) == 1.0
    assert main.metrics.registry.get_sample_value("http_request_duration_seconds_sum", labels) >= 0.0


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def test_log_de_peticion_es_json_con_http_request(client, log_lines):
    client.get("/version", headers={"User-Agent": "probe/1.0"})

    (entry,) = log_lines()
    assert entry["severity"] == "INFO"
    assert entry["route"] == "/version"
    http = entry["httpRequest"]
    assert http["requestMethod"] == "GET"
    assert http["requestUrl"].endswith("/version")
    assert http["status"] == 200
    assert http["latency"].endswith("s")
    assert http["userAgent"] == "probe/1.0"
    datetime.fromisoformat(entry["time"])  # ISO 8601 válido


def test_trace_header_enlaza_con_cloud_trace(client, log_lines, entorno):
    entorno(PROJECT_ID="mi-proyecto")
    client.get("/version", headers={"X-Cloud-Trace-Context": "105445aa7843bc8bf206b12000100000/1234;o=1"})

    (entry,) = log_lines()
    assert entry["logging.googleapis.com/trace"] == "projects/mi-proyecto/traces/105445aa7843bc8bf206b12000100000"
    assert entry["logging.googleapis.com/spanId"] == "00000000000004d2"
    assert entry["logging.googleapis.com/trace_sampled"] is True


def test_sin_project_id_no_se_anade_trace(client, log_lines, monkeypatch, entorno):
    monkeypatch.delenv("PROJECT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    entorno()
    client.get("/version", headers={"X-Cloud-Trace-Context": "abc/1;o=1"})

    (entry,) = log_lines()
    assert not any(key.startswith("logging.googleapis.com/") for key in entry)
    assert trace_fields("abc/1;o=1", None) == {}
    assert trace_fields(None, "p") == {}


def test_probes_y_metrics_no_generan_log(client, log_lines):
    client.get("/healthz")
    client.get("/readyz")
    client.get("/metrics")
    assert log_lines() == []


def test_errores_de_cliente_se_registran_como_warning(client, log_lines):
    client.get("/no-existe")
    (entry,) = log_lines()
    assert entry["severity"] == "WARNING"
    assert entry["httpRequest"]["status"] == 404
    assert entry["route"] == "unmatched"


def test_json_formatter_severity_time_y_extras():
    record = logging.LogRecord("x", logging.WARNING, __file__, 1, "aviso %s", ("ñ",), None)
    record.custom_field = {"a": 1}

    payload = json.loads(JsonFormatter().format(record))

    assert payload["severity"] == "WARNING"
    assert payload["message"] == "aviso ñ"
    assert payload["custom_field"] == {"a": 1}
    assert datetime.fromisoformat(payload["time"]).utcoffset().total_seconds() == 0
