# ADR-0002 · Estrategia de recuperación ante desastres: warm standby

- **Estado:** aceptada
- **Requisitos:** RPO < 1 minuto, RTO < 15 minutos ante la pérdida completa de la región primaria.

## Opciones evaluadas

| Opción | RPO | RTO | Coste mensual relativo | Complejidad |
|---|---|---|---|---|
| Backup & restore (snapshots + AMIs copiados) | Horas | Horas | Muy bajo | Baja |
| Pilot light (solo datos replicados, cómputo apagado) | Segundos | 20–60 min (arranque y calentamiento del cómputo, cambios de DNS) | Bajo | Media |
| **Warm standby** (datos replicados + cómputo mínimo encendido) | **Segundos** | **5–15 min** | Medio | Media |
| Activo-activo multi-región | ~0 | ~0 | Alto | Alta (escrituras multi-región, conflictos) |

## Decisión

**Warm standby** entre `sa-east-1` (primaria, menor latencia hacia Sudamérica) y `us-east-1` (DR):

- **Aurora Global Database**: replicación a nivel de almacenamiento con lag habitualmente por debajo de un segundo. Es lo que hace alcanzable el RPO.
- **Cómputo mínimo encendido en DR** (1 instancia, 1 NAT): la región ya está probada y caliente; el failover solo escala.
- **Route 53 failover** con health checks: el tráfico cambia de región sin intervención.
- La promoción de la base de datos es **manual y deliberada** (runbook): una promoción automática ante una falsa alarma provocaría *split-brain* o pérdida de datos innecesaria.

## Por qué no las otras

- **Pilot light**: el arranque del cómputo, más el calentamiento y la propagación DNS, deja poco margen frente a 15 minutos.
- **Activo-activo**: cumple con holgura, pero obliga a resolver escrituras concurrentes en dos regiones (o a usar *write forwarding*) y duplica el coste. No lo justifica un RTO de 15 minutos.

## Consecuencias

- ➕ Requisitos cumplidos con margen y medibles (alarma de lag de replicación; game day documentado).
- ➖ Coste permanente de la región de DR. Se acota con capacidad mínima y una sola NAT.
- ➖ Las clases de instancia de Aurora Global Database no pueden ser burstable (`db.t*`).
- 🔁 Revisar si cambian los requisitos: con un RTO de horas, pilot light sería más barato.
