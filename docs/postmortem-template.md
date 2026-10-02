# Postmortem · <título descriptivo>

> Formato sin culpables: se analizan sistemas y decisiones, no personas. El objetivo es que el mismo fallo no vuelva a ocurrir y que el siguiente se detecte antes.

| Campo | Valor |
|---|---|
| Fecha del incidente | AAAA-MM-DD |
| Duración | hh:mm (desde el inicio del impacto hasta la recuperación) |
| Severidad | SEV1 / SEV2 / SEV3 |
| Servicios afectados | |
| Presupuesto de error consumido | % del mensual |
| RPO / RTO medidos (si hubo failover) | |
| Responsable del documento | |

## Resumen

Dos o tres frases: qué pasó, a quién afectó y cómo se resolvió.

## Impacto

Usuarios o pedidos afectados, errores servidos, datos perdidos (si los hubo), coste.

## Cronología (hora de Chile)

| Hora | Evento |
|---|---|
| hh:mm | Primer síntoma |
| hh:mm | Alarma `...` en ALARM |
| hh:mm | Mitigación aplicada |
| hh:mm | Servicio recuperado |

## Causa raíz

Cadena de causas ("5 porqués"). ¿Por qué ocurrió? ¿Por qué no lo evitó ningún control? ¿Por qué no se detectó antes?

## Qué funcionó bien

## Qué no funcionó

## Acciones

Cada acción es **preventiva** (evita que ocurra), **de detección** (lo detecta antes) o **de mitigación** (reduce el impacto). Todas tienen responsable y fecha.

| Acción | Tipo | Responsable | Fecha | Ticket |
|---|---|---|---|---|
| | | | | |

## Lecciones para el resto de equipos
