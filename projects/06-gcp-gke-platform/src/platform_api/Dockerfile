# syntax=docker/dockerfile:1.7
# Imagen de platform-api. Contexto de build: este directorio (src/platform_api).
#
#   docker build -t platform-api:dev --build-arg GIT_SHA=$(git rev-parse --short HEAD) .
#
# Imagen base: python:3.13-slim-bookworm y no gcr.io/distroless/python3-debian12.
# La imagen distroless de Python trae el intérprete 3.11 de Debian 12, incompatible con
# las ruedas compiladas para 3.13 que instala la etapa builder (pydantic-core, uvloop,
# httptools...). La alternativa limpia es slim + usuario sin privilegios + sistema de
# archivos de solo lectura en el Pod (securityContext.readOnlyRootFilesystem), que es lo
# que aplica el chart de Helm.

ARG PYTHON_IMAGE=python:3.13-slim-bookworm

# ----------------------------------------------------------------------------
# Etapa 1: dependencias en un virtualenv aislado
# ----------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# ----------------------------------------------------------------------------
# Etapa 2: imagen final, sin pip ni herramientas de build
# ----------------------------------------------------------------------------
FROM ${PYTHON_IMAGE}

# Metadatos de build que expone GET /version (los inyecta el pipeline de CI).
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="platform-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    BUILD_DATE=${BUILD_DATE}

# Usuario sin privilegios con UID fijo (el chart usa el mismo valor en runAsUser). Sin
# home ni shell: no hay nada que un atacante pueda ejecutar interactivamente.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
# El venv y el código quedan en propiedad de root: el proceso (UID 10001) puede leerlos y
# ejecutarlos, pero no modificarlos.
COPY --from=builder /opt/venv /opt/venv
COPY __init__.py main.py /app/platform_api/

USER 10001
EXPOSE 8080

# Sin HEALTHCHECK a propósito: en Kubernetes la salud la deciden los probes del Pod
# (liveness en /healthz, readiness en /readyz) y el HEALTHCHECK de Docker se ignora.
CMD ["python", "-m", "uvicorn", "platform_api.main:app", "--host", "0.0.0.0", "--port", "8080"]
