# Runbook · Tasa de errores alta (alarma `*-slo-burn-fast` / `*-slo-burn-slow`)

**Qué significa:** el servicio está consumiendo su presupuesto de error mucho más rápido de lo sostenible. `fast` = página inmediata; `slow` = degradación sostenida, atender en horario laboral.

## 1. Evaluar el impacto (2 min)

- Dashboard `<servicio>-<entorno>-overview`: ¿cae la disponibilidad? ¿sube la latencia? ¿cae el tráfico?
- ¿Errores `HTTPCode_ELB_5XX` (el ALB no encuentra destinos sanos) o `HTTPCode_Target_5XX` (la aplicación falla)?

## 2. ¿Qué cambió? (5 min)

| Pregunta | Dónde mirar |
|---|---|
| ¿Despliegue reciente? | Historial de GitHub Actions; `instance refresh` del ASG |
| ¿Cambio de infraestructura? | CloudTrail: `eventSource` de EC2, ELB, RDS en la última hora |
| ¿Dependencia caída? | Métricas de Aurora (CPU, conexiones), estado de AWS Health |
| ¿Tráfico anómalo? | Métricas de WAF (reglas que bloquean), `RequestCount` frente a la banda esperada |

## 3. Mitigar primero, diagnosticar después

| Causa probable | Mitigación |
|---|---|
| Despliegue defectuoso | Cancelar el `instance refresh` (hace rollback automático) o revertir el commit |
| Instancias saturadas | Subir temporalmente `min_size` del ASG |
| Base de datos saturada | Revisar Performance Insights; failover a un reader si el writer está degradado |
| Región degradada | Seguir [el runbook de failover](../../projects/01-multi-region-ha-dr/runbooks/failover.md) |

## 4. Cerrar

- Confirmar que ambas alarmas compuestas vuelven a `OK`.
- Abrir un postmortem con la [plantilla](../postmortem-template.md) si se consumió más del 10 % del presupuesto de error mensual.
