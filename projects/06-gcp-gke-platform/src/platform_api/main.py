"""API de ejemplo para la plataforma GKE.

Es la carga de trabajo que el chart de Helm despliega. No hace nada de negocio: su
valor está en comportarse como debe comportarse un servicio dentro de Kubernetes y
de Google Cloud, de modo que la plataforma pueda demostrarse de extremo a extremo.

Qué la hace "cloud native" de verdad:
  * Probes separados: ``/healthz`` (liveness) solo dice que el proceso vive;
    ``/readyz`` (readiness) dice si debe recibir tráfico y pasa a 503 en cuanto
    empieza el apagado.
  * Apagado ordenado: al recibir SIGTERM la app se marca como "draining", espera
    ``DRAIN_SECONDS`` y solo entonces deja que uvicorn termine. Kubernetes retira el
    Pod del Service (y el balanceador de GCP del NEG) al ver el readiness en 503, así
    que cuando el proceso muere ya no le llega tráfico: cero errores en los rolling
    updates. ``terminationGracePeriodSeconds`` del Pod debe ser mayor que
    ``DRAIN_SECONDS`` más el tiempo de apagado de uvicorn.
  * Identidad del Pod vía downward API (``POD_NAME``, ``NODE_NAME``, ``POD_NAMESPACE``)
    y zona obtenida una sola vez del metadata server de GCE en el arranque.
  * Métricas Prometheus en ``/metrics`` con etiquetas de baja cardinalidad
    (plantilla de ruta, nunca el path crudo).
  * Logs JSON a stdout que Cloud Logging interpreta sin agentes: ``severity``,
    ``httpRequest`` y correlación con Cloud Trace a partir de ``X-Cloud-Trace-Context``.

Arranque::

    python -m uvicorn platform_api.main:app --host 0.0.0.0 --port 8080

El módulo reconfigura el logging de uvicorn al importarse: sus mensajes salen en el
mismo JSON y su access log se silencia, porque el middleware ya emite un registro por
petición en el formato que Cloud Logging entiende.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import threading
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from types import FrameType
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Histogram, generate_latest
from starlette.types import ASGIApp, Message, Receive, Scope, Send

# Endpoint del metadata server de GCE. Solo es alcanzable desde una VM/Pod de Google
# Cloud; fuera de GCP la llamada falla rápido (timeout corto) y la zona queda "unknown".
ZONE_URL = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
METADATA_HEADERS = {"Metadata-Flavor": "Google"}
METADATA_TIMEOUT_SECONDS = 0.3

# Etiqueta de ruta para peticiones que no casan con ninguna ruta registrada. Si se
# usara el path crudo, cada escaneo de bots (``/wp-admin``, ``/.env``...) crearía una
# serie nueva en Prometheus y la cardinalidad crecería sin límite.
UNMATCHED_ROUTE = "unmatched"

TRACE_HEADER = "x-cloud-trace-context"


# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------


def _csv_env(name: str, default: str) -> frozenset[str]:
    return frozenset(p.strip() for p in os.environ.get(name, default).split(",") if p.strip())


@dataclass(frozen=True)
class Settings:
    """Valores inyectados por el Deployment (downward API, metadatos de build, ajustes)."""

    app_version: str
    git_sha: str
    build_date: str
    pod_name: str
    node_name: str
    namespace: str
    project_id: str | None
    drain_seconds: float
    # Los probes y el scraping de Prometheus llegan cada pocos segundos; registrarlos
    # en Cloud Logging solo añade ruido y coste de ingesta.
    log_excluded_paths: frozenset[str]

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            app_version=os.environ.get("APP_VERSION", "dev"),
            git_sha=os.environ.get("GIT_SHA", "unknown"),
            build_date=os.environ.get("BUILD_DATE", "unknown"),
            pod_name=os.environ.get("POD_NAME", "unknown"),
            node_name=os.environ.get("NODE_NAME", "unknown"),
            namespace=os.environ.get("POD_NAMESPACE", "unknown"),
            project_id=os.environ.get("PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT") or None,
            drain_seconds=float(os.environ.get("DRAIN_SECONDS", "5")),
            log_excluded_paths=_csv_env("LOG_EXCLUDED_PATHS", "/healthz,/readyz,/metrics"),
        )


settings = Settings.from_env()


# ---------------------------------------------------------------------------
# Logging estructurado compatible con Cloud Logging
# ---------------------------------------------------------------------------

# Atributos que trae cualquier LogRecord; todo lo demás que llegue en ``extra`` se
# vuelca como campo JSON de primer nivel. ``color_message`` es un extra interno de uvicorn.
_RESERVED_RECORD_KEYS = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "message",
    "asctime",
    "color_message",
}


def _severity(levelno: int) -> str:
    """Traduce el nivel de Python a los valores de LogSeverity de Cloud Logging."""
    if levelno >= logging.CRITICAL:
        return "CRITICAL"
    if levelno >= logging.ERROR:
        return "ERROR"
    if levelno >= logging.WARNING:
        return "WARNING"
    if levelno >= logging.INFO:
        return "INFO"
    return "DEBUG"


class JsonFormatter(logging.Formatter):
    """Una línea JSON por registro, con los campos especiales que Cloud Logging reconoce.

    ``severity`` fija el nivel en el visor, ``time`` la marca temporal, ``httpRequest``
    se muestra como petición HTTP y ``logging.googleapis.com/trace`` enlaza el log con
    la traza de Cloud Trace.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "severity": _severity(record.levelno),
            "message": record.getMessage(),
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "logger": record.name,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED_RECORD_KEYS and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            # Cloud Error Reporting agrupa los errores a partir de este campo.
            payload["stack_trace"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, default=str)


def configure_logging() -> None:
    """Envía todo el logging a stdout en JSON. Idempotente: uvicorn puede importar el módulo varias veces."""
    root = logging.getLogger()
    if not any(isinstance(h.formatter, JsonFormatter) for h in root.handlers):
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(JsonFormatter())
        root.addHandler(handler)
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    # uvicorn configura sus loggers (texto plano, sin propagar) antes de importar la
    # app; se les quitan sus handlers para que sus mensajes salgan también en JSON y
    # Cloud Logging no los ingiera como texto con severidad DEFAULT.
    for name in ("uvicorn", "uvicorn.error"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers.clear()
        uvicorn_logger.propagate = True
    # El access log de uvicorn se silencia: el middleware ya emite un registro por
    # petición con el campo ``httpRequest`` que Cloud Logging entiende.
    access_logger = logging.getLogger("uvicorn.access")
    access_logger.handlers.clear()
    access_logger.propagate = False


configure_logging()
logger = logging.getLogger("platform_api")
request_logger = logging.getLogger("platform_api.request")


def trace_fields(header: str | None, project_id: str | None) -> dict[str, Any]:
    """Convierte ``X-Cloud-Trace-Context`` (``TRACE_ID/SPAN_ID;o=1``) en campos de Cloud Logging.

    Sin ``PROJECT_ID`` no se puede construir el nombre completo de la traza, así que
    no se añade nada: un campo a medias solo confundiría al visor.
    """
    if not header or not project_id:
        return {}
    trace_id, _, rest = header.partition("/")
    trace_id = trace_id.strip()
    if not trace_id:
        return {}
    span_id, _, options = rest.partition(";")
    fields: dict[str, Any] = {"logging.googleapis.com/trace": f"projects/{project_id}/traces/{trace_id}"}
    if span_id.strip().isdigit():
        # La cabecera trae el span en decimal; Cloud Logging lo espera en hexadecimal de 16 cifras.
        fields["logging.googleapis.com/spanId"] = format(int(span_id), "016x")
    fields["logging.googleapis.com/trace_sampled"] = "o=1" in options
    return fields


# ---------------------------------------------------------------------------
# Métricas Prometheus
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Metrics:
    """Registro propio en lugar del global de prometheus_client.

    Así cada test (o cada instancia de la app) puede crear el suyo sin que los
    colectores choquen por nombre, y la exposición en ``/metrics`` no arrastra las
    métricas de proceso de Python que aquí no aportan nada.
    """

    registry: CollectorRegistry
    requests: Counter
    latency: Histogram

    @classmethod
    def create(cls) -> Metrics:
        registry = CollectorRegistry()
        return cls(
            registry=registry,
            requests=Counter(
                "http_requests_total",
                "Peticiones HTTP atendidas",
                ["method", "route", "status"],
                registry=registry,
            ),
            latency=Histogram(
                "http_request_duration_seconds",
                "Latencia de las peticiones HTTP",
                ["method", "route"],
                registry=registry,
            ),
        )


metrics = Metrics.create()


def _route_template(scope: Scope) -> str:
    # FastAPI deja la ruta que casó en ``scope["route"]``; su ``path_format`` es la
    # plantilla (``/items/{item_id}``), que es lo que queremos como etiqueta: el path
    # real (``/items/42``) tendría tantos valores como ids y haría inútil la métrica.
    route = scope.get("route")
    template = getattr(route, "path_format", None) or getattr(route, "path", None)
    return template or UNMATCHED_ROUTE


class ObservabilityMiddleware:
    """Middleware ASGI puro: métricas y un log JSON por petición.

    Se implementa a bajo nivel (en vez de ``BaseHTTPMiddleware``) para no interferir
    con respuestas en streaming ni con la propagación de excepciones.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        started = time.perf_counter()
        status = 500  # si la aplicación falla antes de responder, es un 500 de facto

        async def send_wrapper(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            elapsed = time.perf_counter() - started
            route = _route_template(scope)
            method = scope["method"]
            metrics.requests.labels(method=method, route=route, status=str(status)).inc()
            metrics.latency.labels(method=method, route=route).observe(elapsed)
            _log_request(scope, route, status, elapsed)


def _log_request(scope: Scope, route: str, status: int, elapsed: float) -> None:
    request = Request(scope)
    if request.url.path in settings.log_excluded_paths:
        return
    http_request = {
        "requestMethod": request.method,
        "requestUrl": str(request.url),
        "status": status,
        "latency": f"{elapsed:.6f}s",
        "userAgent": request.headers.get("user-agent"),
        "remoteIp": request.client.host if request.client else None,
    }
    extra: dict[str, Any] = {"httpRequest": http_request, "route": route}
    extra.update(trace_fields(request.headers.get(TRACE_HEADER), settings.project_id))
    level = logging.INFO if status < 400 else logging.WARNING if status < 500 else logging.ERROR
    request_logger.log(level, "%s %s -> %s", request.method, request.url.path, status, extra=extra)


# ---------------------------------------------------------------------------
# Estado de readiness y apagado ordenado
# ---------------------------------------------------------------------------

_draining = threading.Event()


def mark_shutdown() -> None:
    """Deja de anunciarse como listo: ``/readyz`` responde 503 a partir de ahora."""
    _draining.set()


def mark_ready() -> None:
    """Vuelve al estado normal (arranque y tests)."""
    _draining.clear()


def is_draining() -> bool:
    return _draining.is_set()


def _drain_then_forward(signum: int, drain_seconds: float, main_thread_id: int) -> None:
    """Espera el drenaje y reenvía la señal al hilo principal (corre en un hilo auxiliar)."""
    logger.info("SIGTERM recibido, drenando antes de apagar", extra={"drain_seconds": drain_seconds})
    time.sleep(drain_seconds)
    # Python ejecuta los manejadores de señal en el hilo principal, pero solo cuando
    # ese hilo vuelve a ejecutar bytecode. ``pthread_kill`` dirige la señal a ese hilo
    # y así interrumpe su espera en ``epoll``: uvicorn reacciona al instante en vez de
    # en su siguiente tick. ``raise_signal`` desde este hilo no lo garantizaría.
    signal.pthread_kill(main_thread_id, signum)


def install_sigterm_handler(drain_seconds: float) -> bool:
    """Encadena el drenaje delante del manejador de SIGTERM de uvicorn.

    Al recibir SIGTERM: (1) se marca la app como draining para que ``/readyz`` falle,
    (2) se restaura el manejador original (el de uvicorn) y (3) un hilo auxiliar
    reenvía la señal pasados ``drain_seconds``. Mientras tanto el bucle de eventos
    sigue sirviendo peticiones, incluidos los probes, cosa que un ``time.sleep``
    dentro del propio manejador impediría. El manejador no hace E/S: un ``print`` o
    un log desde dentro de una señal puede reentrar en el buffer de stdout.

    Devuelve ``False`` si no se pudo instalar (los manejadores de señal solo pueden
    registrarse desde el hilo principal; en los tests la app corre en otro hilo).
    """
    main_thread = threading.main_thread()
    if threading.current_thread() is not main_thread or main_thread.ident is None:
        logger.debug("manejador de SIGTERM no instalado: no estamos en el hilo principal")
        return False
    main_thread_id = main_thread.ident

    previous = signal.getsignal(signal.SIGTERM)
    # SIG_IGN o un manejador nativo (None) dejarían el proceso sin forma de terminar.
    fallback = previous if callable(previous) or previous == signal.SIG_DFL else signal.SIG_DFL

    def handle_sigterm(signum: int, frame: FrameType | None) -> None:
        mark_shutdown()
        signal.signal(signum, fallback)
        threading.Thread(
            target=_drain_then_forward,
            args=(signum, drain_seconds, main_thread_id),
            name="sigterm-drain",
            daemon=True,
        ).start()

    signal.signal(signal.SIGTERM, handle_sigterm)
    return True


# ---------------------------------------------------------------------------
# Metadata de GCE
# ---------------------------------------------------------------------------


def parse_zone(raw: str) -> str:
    """``projects/123/zones/us-central1-a`` -> ``us-central1-a``."""
    zone = raw.strip().rsplit("/", 1)[-1]
    if not zone:
        raise ValueError(f"respuesta de metadata sin zona: {raw!r}")
    return zone


def fetch_zone(
    client_factory: Callable[[], httpx.Client] = httpx.Client,
    url: str = ZONE_URL,
    timeout: float = METADATA_TIMEOUT_SECONDS,
) -> str:
    """Consulta la zona al metadata server; ``"unknown"`` si no estamos en GCP.

    ``client_factory`` permite inyectar un cliente con ``httpx.MockTransport`` en los
    tests sin tocar la red.
    """
    try:
        with client_factory() as client:
            response = client.get(url, headers=METADATA_HEADERS, timeout=timeout)
            response.raise_for_status()
            return parse_zone(response.text)
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("zona no disponible desde metadata: %s", exc)
        return "unknown"


# ---------------------------------------------------------------------------
# Aplicación
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    mark_ready()
    app.state.zone = fetch_zone()
    sigterm_hooked = install_sigterm_handler(settings.drain_seconds)
    logger.info(
        "platform-api lista",
        extra={"version": settings.app_version, "zone": app.state.zone, "sigterm_drain": sigterm_hooked},
    )
    try:
        yield
    finally:
        logger.info("platform-api detenida")


# Sin Swagger ni esquema OpenAPI públicos: la superficie expuesta detrás del
# balanceador debe ser la mínima, y la documentación de una API interna no tiene por
# qué servirse desde producción (se puede generar en CI con ``app.openapi()``).
app = FastAPI(title="platform-api", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
app.add_middleware(ObservabilityMiddleware)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness: el proceso responde. No depende de nada externo a propósito."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> JSONResponse:
    """Readiness: 503 durante el drenaje para que el Service retire el Pod."""
    if is_draining():
        return JSONResponse({"status": "draining"}, status_code=503)
    return JSONResponse({"status": "ok"})


@app.get("/version")
async def version() -> dict[str, str]:
    return {"version": settings.app_version, "commit": settings.git_sha, "build_date": settings.build_date}


@app.get("/api/v1/whoami")
async def whoami(request: Request) -> dict[str, str]:
    """Qué Pod, nodo y zona han atendido la petición: útil para ver el reparto del balanceador."""
    return {
        "pod": settings.pod_name,
        "node": settings.node_name,
        "namespace": settings.namespace,
        "zone": getattr(request.app.state, "zone", "unknown"),
        "version": settings.app_version,
    }


@app.get("/metrics")
async def prometheus_metrics() -> Response:
    return Response(content=generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)
