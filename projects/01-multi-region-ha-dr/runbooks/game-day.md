# Game day · Prueba controlada del DR

Un plan de DR que no se prueba no existe. Este ejercicio mide el RPO y el RTO reales.

## Preparación

- [ ] Ventana acordada con producto y soporte.
- [ ] Carga sintética escribiendo una fila por segundo con marca de tiempo (`INSERT INTO heartbeat(ts) VALUES (now())`).
- [ ] Panel de CloudWatch del proyecto 05 abierto; cronómetro listo.

## Escenarios

| # | Escenario | Cómo se provoca | Resultado esperado |
|---|---|---|---|
| 1 | Pérdida de una AZ | Desregistrar las instancias de una AZ del target group | El ASG repone capacidad en las otras AZ; sin errores 5xx sostenidos |
| 2 | Caída del writer de Aurora | `aws rds failover-db-cluster` en la región primaria | El reader se promueve en ~30–60 s; la app reconecta |
| 3 | Pérdida de la región primaria | Hacer fallar el health check primario (NACL que bloquee el ALB) y ejecutar el runbook | Route 53 conmuta y DR acepta escrituras en < 15 min |
| 4 | Failback | Switchover de vuelta a la región primaria | Sin pérdida de datos |

## Métricas a registrar

| Métrica | Cómo se mide | Objetivo |
|---|---|---|
| **RPO** | Último `heartbeat.ts` presente en DR tras promover vs. hora del corte | < 60 s |
| **RTO** | Desde el corte hasta la primera escritura correcta en DR | < 15 min |
| Tiempo de detección | Desde el corte hasta la alarma | < 2 min |
| Pasos manuales | Contados en el runbook | Tendencia a la baja |

Los resultados y las acciones de mejora se registran con la plantilla de postmortem.
