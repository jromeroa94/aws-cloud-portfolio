# Runbook · Incidente tras un despliegue en GKE

**Alertas que enlazan aquí:** `platform-api · burn rate fast`, `GKE · contenedores reiniciándose en el namespace platform`.

**Objetivo:** recuperar el servicio en menos de 10 minutos. Primero se restaura, después se investiga.

## 0. Antes de tocar nada (1 min)

```bash
gcloud container clusters get-credentials platform-dev --region southamerica-east1 --dns-endpoint
kubectl -n platform get deploy,pods,hpa -o wide
helm -n platform history platform-api | tail -5
```

Preguntas: ¿coincide el inicio de la alerta con la última revisión de Helm? ¿Los Pods están `Running` y `Ready` o en `CrashLoopBackOff` / `ImagePullBackOff`?

## 1. Si el despliegue es la causa probable: rollback (2 min)

```bash
helm -n platform rollback platform-api            # vuelve a la revisión anterior
kubectl -n platform rollout status deploy/platform-api --timeout=120s
```

El workflow despliega con `--atomic`, así que un rollout que no llegó a estar sano ya se revirtió solo; este paso es para el caso en que el rollout terminó bien y el problema apareció después (p. ej. una dependencia externa que la readiness no comprueba).

Comunicar en el canal de incidentes: "rollback ejecutado a la revisión N, vigilando la tasa de error".

## 2. Confirmar la recuperación (3 min)

- Cloud Monitoring → SLOs → `platform-api`: el burn rate debe caer por debajo de 1 en los siguientes 5 minutos.
- `kubectl -n platform get pods`: cero reinicios nuevos.
- Prueba de humo desde dentro del clúster:

```bash
kubectl -n platform run smoke-$RANDOM --rm -i --restart=Never --labels=platform-api-client=true \
  --image=curlimages/curl:8.10.1 -- -fsS http://platform-api/healthz
```

Si no se recupera, el despliegue no era la causa: ir al paso 4.

## 3. Diagnóstico de la versión retirada (después, sin prisa)

| Síntoma | Dónde mirar | Causas habituales |
|---|---|---|
| `CrashLoopBackOff` | `kubectl -n platform logs deploy/platform-api --previous` | Variable de entorno nueva sin valor, dependencia de Python incompatible, puerto distinto de 8080 |
| `ImagePullBackOff` | `kubectl -n platform describe pod <pod>` | Etiqueta inexistente (el build falló pero el deploy se lanzó a mano), permisos de Artifact Registry de la cuenta de nodos |
| Pods `Running` pero `0/1 Ready` | `kubectl -n platform describe pod` → eventos de la readiness | `/readyz` devuelve 503: la app no completó el arranque (metadata server inaccesible por NetworkPolicy, timeouts) |
| 5xx sin reinicios | Logs Explorer: `resource.type="k8s_container" resource.labels.namespace_name="platform" severity>=ERROR` | Error de lógica en la versión nueva; buscar por `logging.googleapis.com/trace` el request fallido |
| Latencia alta sin errores | Cloud Monitoring → métricas del balanceador `https/backend_latencies` | Límites de CPU demasiado bajos (throttling), HPA en el máximo |

Guardar los hallazgos para el postmortem ([plantilla](../../../docs/postmortem-template.md)).

## 4. Si el despliegue no es la causa

1. **Balanceador / Cloud Armor**: Logs Explorer con `resource.type="http_load_balancer"`: ¿respuestas 403/429 de la política `platform-edge`? Una regla WAF con falsos positivos se pasa a `preview = true` en Terraform mientras se ajusta.
2. **Nodos**: `kubectl get nodes` y `kubectl describe node`: presión de memoria/disco, nodos `NotReady`. Si una zona entera está caída, el clúster regional sigue sirviendo con las otras dos; el HPA necesitará margen de nodos (`apps_max_nodes`).
3. **Dependencias de Google**: [status.cloud.google.com](https://status.cloud.google.com) para la región.
4. **Escalado manual de emergencia**: `kubectl -n platform scale deploy/platform-api --replicas=6` (el HPA lo corregirá después; subir `autoscaling.minReplicas` si debe quedarse).

## 5. Cierre

- Alerta reconocida y cerrada en Cloud Monitoring cuando el burn rate lleve 15 minutos por debajo de 1.
- Postmortem en 48 h si el incidente consumió más del 10 % del presupuesto de error del mes (unos 4 minutos de caída total con SLO 99,9 %).
- Si la causa fue una comprobación que la readiness no cubría, la acción correctiva es añadirla a `/readyz`, no un paso manual más en este runbook.
