# ADR-0004 · Alertas basadas en SLOs y tasa de consumo del presupuesto de error

- **Estado:** aceptada

## Contexto

Las alarmas clásicas de umbral fijo ("más de 10 errores 5xx en 5 minutos") tienen dos problemas:

- **Ruido**: con mucho tráfico, 10 errores son irrelevantes; el equipo aprende a ignorar la alarma.
- **Ceguera**: con poco tráfico, un 50 % de errores puede no llegar nunca a 10.

## Decisión

1. Definir un **SLO de disponibilidad** (por defecto 99,9 % de peticiones sin 5xx en 30 días, unos 43 minutos de presupuesto de error).
2. Alertar por **tasa de consumo** (*burn rate*) del presupuesto, siguiendo el método multiventana del *SRE Workbook* de Google:

| Severidad | Burn rate | Ventana larga | Ventana corta | Significa | Acción |
|---|---|---|---|---|---|
| Página | 14,4× | 1 h | 5 min | 2 % del presupuesto mensual en una hora | Guardia, ahora |
| Ticket | 6× | 6 h | 30 min | 5 % del presupuesto en seis horas | Horario laboral |

3. Cada severidad es una **alarma compuesta** `larga AND corta`: la larga confirma que el impacto es significativo y la corta hace que la alarma se apague sola en cuanto el problema se resuelve.
4. Alarmas complementarias de **síntomas**: latencia p99, hosts sanos por debajo de la redundancia mínima, caída anómala de tráfico (detección de anomalías) y mensajes en DLQ.
5. Toda alarma que pagina enlaza a un **runbook**.

## Consecuencias

- ➕ Menos falsos positivos y detección proporcional al impacto real en los usuarios.
- ➕ Conversación con producto en términos de negocio: "hemos consumido el 60 % del presupuesto de error de este mes".
- ➖ Requiere acordar el SLO con negocio y revisarlo trimestralmente.
- ➖ Las alarmas compuestas no admiten *metric math* directamente: se crean alarmas hijas sin acciones.
