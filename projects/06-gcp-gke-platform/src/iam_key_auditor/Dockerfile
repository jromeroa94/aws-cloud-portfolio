# syntax=docker/dockerfile:1.7
# Imagen del auditor de claves (Cloud Run Job). Contexto de build: este directorio
# (src/iam_key_auditor).
#
#   docker build -t iam-key-auditor:dev .
#
# Imagen base: python:3.13-slim-bookworm y no gcr.io/distroless/python3-debian12.
# La imagen distroless de Python trae el intérprete 3.11 de Debian 12, incompatible con
# las ruedas compiladas para 3.13 que instala la etapa builder (grpcio, protobuf...). La
# alternativa limpia es slim + usuario sin privilegios + sistema de archivos de solo
# lectura (Cloud Run ya ejecuta el contenedor con el filesystem de la imagen en solo
# lectura; solo /tmp es escribible).

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

LABEL org.opencontainers.image.title="iam-key-auditor"

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Usuario sin privilegios con UID fijo, sin home ni shell.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
# El venv y el código quedan en propiedad de root: el proceso (UID 10001) puede leerlos y
# ejecutarlos, pero no modificarlos.
COPY --from=builder /opt/venv /opt/venv
COPY __init__.py auditor.py /app/iam_key_auditor/

USER 10001

# Es un job de ejecución única: no expone puertos ni necesita HEALTHCHECK; Cloud Run Jobs
# juzga la ejecución por el código de salida (0 = auditoría completada, 2 = fallo de API).
# Las credenciales llegan por la service account del job (ADC), nunca por fichero.
CMD ["python", "-m", "iam_key_auditor.auditor"]
