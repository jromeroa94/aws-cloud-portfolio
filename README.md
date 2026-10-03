# Cloud Engineering Portfolio · AWS y Google Cloud

**Johan Romero Aguirre** · Ingeniero DevOps / Cloud senior · ~10 años en banca, seguros y energía

Infraestructura en AWS y Google Cloud escrita como la escribiría para producción: Terraform modular con tests, Python con pytest, Kubernetes (GKE) con runners self-hosted de GitHub Actions, seguridad desde el diseño, FinOps y observabilidad basada en SLOs. Cada proyecto explica **por qué** se tomó cada decisión, no solo cómo desplegarlo.

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.10-7B42BC?logo=terraform)
![AWS provider](https://img.shields.io/badge/AWS_provider-6.x-FF9900?logo=amazonaws)
![Google provider](https://img.shields.io/badge/Google_provider-8.x-4285F4?logo=googlecloud&logoColor=white)
![Kubernetes](https://img.shields.io/badge/GKE-Helm_%C2%B7_ARC-326CE5?logo=kubernetes&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.13-3776AB?logo=python&logoColor=white)

---

## Proyectos

| # | Proyecto | Qué demuestra | Servicios |
|---|---|---|---|
| 01 | [Multi-región HA/DR (warm standby)](projects/01-multi-region-ha-dr) | RPO < 1 min y RTO < 15 min entre dos regiones, runbook de failover y game day | EC2, ALB, ASG, Aurora Global Database, Route 53, WAF, Secrets Manager, KMS |
| 02 | [Pipeline serverless de pedidos](projects/02-serverless-order-pipeline) | Lambda en Python idempotente, fan-out SNS → SQS, fallos parciales de lote, 22 tests | Lambda, S3, EventBridge, SQS, SNS, DynamoDB, X-Ray |
| 03 | [Baseline de seguridad y gobierno](projects/03-security-baseline) | Auditoría inmutable, detección, cumplimiento continuo, alertas CIS, permissions boundary, SCPs | CloudTrail, Config, GuardDuty, Security Hub, Access Analyzer, KMS |
| 04 | [FinOps automatizado](projects/04-finops-automation) | Presupuestos, anomalías de coste y un escáner semanal de recursos ociosos con ahorro estimado | Budgets, Cost Anomaly Detection, Lambda, EventBridge Scheduler |
| 05 | [Observabilidad basada en SLOs](projects/05-observability) | Alertas por tasa de consumo del presupuesto de error, dashboard, Logs Insights y ELK gestionado | CloudWatch, OpenSearch, Data Firehose |
| 06 | [Plataforma GKE con runners self-hosted](projects/06-gcp-gke-platform) **(Google Cloud)** | GKE privado regional, Workload Identity Federation sin claves, ARC + kaniko + Trivy, Helm endurecido, Cloud Armor, SLOs, auditor de claves IAM en Python | GKE, VPC/Cloud NAT, IAM/WIF, Artifact Registry, KMS, Secret Manager, Cloud Armor, Gateway API, Cloud Monitoring, Cloud Run Jobs |

Base compartida: [módulo `vpc`](modules/vpc) (3 capas, NAT por AZ), [módulo `app-stack`](modules/app-stack) (ALB + ASG + WAF) y [`bootstrap`](bootstrap) (estado remoto en S3 con bloqueo nativo y roles OIDC para GitHub Actions).

## Arquitectura de referencia

```mermaid
flowchart TB
  subgraph gh["GitHub"]
    pr[Pull request] -->|fmt · validate · tflint · terraform test<br/>checkov · ruff · pytest| ci[CI]
    pr -->|OIDC · rol de solo lectura| plan[terraform plan<br/>comentado en el PR]
    main[main] -->|OIDC · environment protegido<br/>aprobación manual| apply[terraform apply]
  end

  subgraph aws["Cuenta AWS"]
    direction TB
    base["03 · Baseline de seguridad<br/>CloudTrail · Config · GuardDuty · Security Hub"]
    subgraph app["01 · Aplicación multi-región"]
      p[sa-east-1 activa] <-->|Aurora Global DB| d[us-east-1 warm standby]
    end
    sl["02 · Pipeline serverless"]
    obs["05 · SLOs y dashboards"]
    fin["04 · FinOps"]
  end

  subgraph gcp["Proyecto Google Cloud"]
    direction TB
    gke["06 · GKE privado regional<br/>Workload Identity · Dataplane V2 · Cloud Armor"]
    arc["runners self-hosted (ARC, Spot)<br/>kaniko · Trivy · Helm"]
    aud["auditor de claves IAM<br/>Cloud Run Job · Python"]
  end

  apply --> aws
  main -->|Workload Identity Federation<br/>bootstrap de ARC| gke
  arc ==>|runs-on: gke-runners| gke
  obs -.observa.-> app
  obs -.observa.-> sl
  fin -.analiza costes.-> aws
  base -.audita.-> aws
  aud -.audita.-> gcp
```

## Cómo cubre los requisitos de un puesto de ingeniería cloud

| Requisito | Dónde verlo |
|---|---|
| Evolución de arquitectura, alta disponibilidad y resiliencia | [01](projects/01-multi-region-ha-dr) · [ADR-0002](docs/adr/0002-warm-standby-dr.md) · [game day](projects/01-multi-region-ha-dr/runbooks/game-day.md) |
| IaC estandarizada, trazable y auditable | Módulos reutilizables, backend parcial, `terraform test`, plan en cada PR, apply con aprobación · [ADR-0001](docs/adr/0001-terraform-y-convivencia-con-cloudformation.md) |
| Gobierno y seguridad continua (IAM, KMS) | [03](projects/03-security-baseline) · mínimo privilegio en cada rol · [ADR-0003](docs/adr/0003-github-oidc.md) |
| Madurez FinOps y eficiencia operativa | [04](projects/04-finops-automation) · etiquetas `CostCenter` en todo · NAT única en entornos no productivos |
| Gestión proactiva de incidentes | [05](projects/05-observability) · [ADR-0004](docs/adr/0004-alertas-por-slo.md) · [runbooks](docs/runbooks) · [runbook GKE](projects/06-gcp-gke-platform/runbooks/gke-incidente-despliegue.md) · [plantilla de postmortem](docs/postmortem-template.md) |
| GCP en producción: IAM, redes, GKE | [06](projects/06-gcp-gke-platform) · [ADR-0005](docs/adr/0005-runners-self-hosted-en-gke.md) |
| Kubernetes: Helm, seguridad de contenedores, GitOps-ready | [chart `platform-api`](projects/06-gcp-gke-platform/charts/api) · kaniko + Trivy en [`gcp-platform.yml`](.github/workflows/gcp-platform.yml) |
| GitHub Actions: runners self-hosted, secretos y environments | [ARC en GKE](projects/06-gcp-gke-platform/runners) · environments `dev` → `production` |
| Networking (VPC, subredes) | [módulo vpc](modules/vpc) |
| Lambda en Python | [02](projects/02-serverless-order-pipeline) · [04](projects/04-finops-automation) |
| Monitoreo y logs (CloudWatch, ELK) | [05](projects/05-observability) · OpenSearch vía Data Firehose |
| CI/CD | [`.github/workflows`](.github/workflows) |

## Calidad: lo que valida la CI en cada PR

| Control | Herramienta | Resultado actual |
|---|---|---|
| Formato y sintaxis | `terraform fmt`, `terraform validate` | 9 raíces/módulos válidos |
| Lógica de la infraestructura | `terraform test` con proveedores simulados | 21 bloques de test (sin credenciales de AWS ni de GCP) |
| Buenas prácticas | TFLint + rulesets AWS y Google | — |
| Seguridad de la IaC | Checkov (Terraform, Actions, secretos) | 0 fallos; cada excepción justificada en código o en [`.checkov.yaml`](.checkov.yaml) |
| Código Python | Ruff + pytest (`moto` en AWS, clientes simulados en GCP) | 83 tests |
| Chart de Helm | `helm lint --strict`, render y `kubeconform` | 1 chart, 11 manifiestos |

## Estructura

```
.
├── bootstrap/            # Estado remoto + OIDC para GitHub Actions (una vez por cuenta)
├── modules/
│   ├── vpc/              # VPC de 3 capas, con tests
│   └── app-stack/        # ALB + ASG + WAF + IMDSv2
├── projects/
│   ├── 01-multi-region-ha-dr/
│   ├── 02-serverless-order-pipeline/
│   ├── 03-security-baseline/
│   ├── 04-finops-automation/
│   ├── 05-observability/
│   └── 06-gcp-gke-platform/   # Google Cloud: GKE, ARC, Helm, Python, SLOs
├── docs/
│   ├── adr/              # Registro de decisiones de arquitectura
│   ├── runbooks/
│   └── postmortem-template.md
├── site/                 # Web del portfolio (GitHub Pages)
└── .github/workflows/    # CI, plan/apply con OIDC, Pages
```

## Ejecutar en local

```bash
make test        # terraform test + pytest (no necesita cuenta de AWS)
make lint        # fmt, validate, tflint, ruff
make security    # checkov
```

Para desplegar en AWS: sigue [`bootstrap/README.md`](bootstrap/README.md) y después el README de cada proyecto. El proyecto 06 tiene su propio arranque en Google Cloud (bucket de estado y Workload Identity Federation) descrito en [su README](projects/06-gcp-gke-platform/README.md). Todos los proyectos generan coste real; están pensados para desplegarse, probarse y destruirse.

## Sobre mí

Ingeniero DevOps/Cloud con unos diez años en banca, seguros y energía (NTT Data, Indra · Centro de Excelencia DevSecOps, Smartjob, Slashmobility, Zoluxiones; hoy en el equipo de plataforma de Scotiabank Perú). Trabajo habitual con Azure, AWS y GCP, Kubernetes (AKS, GKE/Anthos, EKS, OpenShift), Terraform, Terragrunt, Ansible, GitHub Actions, Jenkins y Python. Certificaciones: Azure Solutions Architect Expert (AZ-305), AZ-104, AZ-700, AZ-140, AZ-900, AWS Cloud Practitioner y LPIC-1.

Web del portfolio: <https://portfolio.nimbodev.com> · Consultora: [nimbodev.com](https://nimbodev.com)

---

<sub>Licencia MIT. Los proyectos son implementaciones de referencia construidas para este portfolio, no copias de infraestructura de clientes.</sub>
