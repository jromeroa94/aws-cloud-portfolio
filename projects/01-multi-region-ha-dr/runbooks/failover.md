# Runbook · Failover y failback multi-región

| Campo | Valor |
|---|---|
| Servicio | `portfolio-prod` (proyecto 01) |
| Objetivos | **RPO < 1 min · RTO < 15 min** |
| Disparadores | Alarma `*-primary-region-unhealthy` · alarma `*-aurora-global-replication-lag` · evento de AWS Health en la región primaria |
| Decisor | Ingeniero de guardia + responsable del servicio |

> Los nombres exactos salen de `terraform output failover_commands` y `terraform output asg_names`.

## 0. Diagnóstico (≤ 3 min)

1. ¿La caída es de **región** o de **aplicación**? Revisar *AWS Health Dashboard* y las métricas del ALB primario (`HTTPCode_ELB_5XX_Count`, `HealthyHostCount`).
   - Si es un fallo de la aplicación (mal despliegue), **no** se hace failover: se revierte el despliegue (el `instance_refresh` tiene `auto_rollback`).
2. Comprobar a dónde apunta Route 53: `dig +short app.ejemplo.cl`. Con el health check primario en rojo, el tráfico ya va a DR **en modo lectura** (la base de datos de DR aún no acepta escrituras).
3. Anotar el lag de replicación actual (`AuroraGlobalDBReplicationLag`): es la pérdida de datos máxima que se acepta al promover.

## 1. Failover no planificado (región primaria caída)

```bash
export DR_REGION=us-east-1
export GLOBAL_ID=portfolio-prod-global
export DR_CLUSTER_ARN=$(terraform output -raw dr_cluster_arn)
export DR_ASG=$(terraform output -json asg_names | jq -r .dr)

# 1.1 Escalar el cómputo de DR primero (tarda más que la promoción de la base de datos)
aws autoscaling update-auto-scaling-group --region $DR_REGION \
  --auto-scaling-group-name "$DR_ASG" --min-size 2 --desired-capacity 2

# 1.2 Promover Aurora en DR. --allow-data-loss acepta perder lo que no se replicó (≈ lag del paso 0.3)
aws rds failover-global-cluster --region $DR_REGION \
  --global-cluster-identifier $GLOBAL_ID \
  --target-db-cluster-identifier $DR_CLUSTER_ARN \
  --allow-data-loss

# 1.3 Esperar a que el cluster de DR sea el writer
aws rds describe-global-clusters --global-cluster-identifier $GLOBAL_ID \
  --query 'GlobalClusters[0].GlobalClusterMembers[].{arn:DBClusterArn,writer:IsWriter}'
```

4. Verificar extremo a extremo: `curl -s https://app.ejemplo.cl/` muestra la región `us-east-1`; probar una escritura funcional.
5. Si el failover va a durar más de unas horas, cambiar `nat_gateway_mode` de la VPC de DR a `"per_az"` y aplicar.
6. Comunicar: inicio, pérdida de datos estimada, hora de recuperación.

## 2. Switchover planificado (game day, mantenimiento regional)

Sin pérdida de datos: Aurora espera a que el secundario esté sincronizado antes de cambiar de rol.

```bash
aws rds switchover-global-cluster --region $DR_REGION \
  --global-cluster-identifier $GLOBAL_ID \
  --target-db-cluster-identifier $DR_CLUSTER_ARN
```

## 3. Failback

1. Cuando la región primaria se recupera, Aurora reincorpora el cluster antiguo como **secundario** del global cluster. Confirmar que el lag es estable y bajo.
2. Programar una ventana y ejecutar un **switchover** (sección 2) con destino el cluster de `sa-east-1`.
3. Devolver el ASG de DR a capacidad de espera:

```bash
aws autoscaling update-auto-scaling-group --region $DR_REGION \
  --auto-scaling-group-name "$DR_ASG" --min-size 1 --desired-capacity 1
```

4. `terraform plan` debe salir sin cambios. Si muestra diferencias, documentarlas antes de aplicar.

## 4. Después del incidente

- Postmortem sin culpables en la plantilla de [docs/postmortem-template.md](../../../docs/postmortem-template.md): RPO y RTO **medidos**, no estimados.
- Cada hallazgo se convierte en una tarea con responsable: alarma nueva, ajuste de umbral o automatización de un paso manual de este runbook.
