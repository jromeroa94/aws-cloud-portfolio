# ADR-0005 · Runners self-hosted de GitHub Actions dentro de GKE, sin claves

- **Estado:** aceptada
- **Proyecto:** [06 · Plataforma GKE](../../projects/06-gcp-gke-platform)

## Contexto

Los runners alojados por GitHub (`ubuntu-latest`) tienen tres problemas para desplegar en un clúster privado de GKE:

1. No tienen ruta de red al plano de control privado; la alternativa habitual es abrir redes autorizadas a `0.0.0.0/0` o exponer el endpoint público.
2. Necesitan credenciales del clúster y del registro de imágenes en GitHub (secretos de larga duración o, como mínimo, un token por ejecución).
3. Cada minuto de CI se paga a GitHub, mientras que en el clúster ya hay capacidad disponible, y Spot es mucho más barato.

Además, construir imágenes en CI suele implicar Docker-in-Docker con contenedores privilegiados.

## Decisión

- **Actions Runner Controller (ARC)** con *runner scale sets* en el propio clúster (`runs-on: gke-runners`), en un node pool **Spot** con taint dedicado y `minRunners: 0`.
- Los runners **despliegan con su propia identidad de Kubernetes**: la KSA `arc-runner` tiene un Role limitado al namespace `platform`. No existen credenciales de clúster fuera de GCP.
- Los runners **publican imágenes con Workload Identity**: la KSA está vinculada a una GSA con `artifactregistry.writer` sobre un único repositorio. Las imágenes se construyen con **kaniko** en modo kubernetes de ARC (sin Docker ni privilegios).
- **Un solo job corre fuera del clúster**: el bootstrap que instala ARC. Se autentica con **Workload Identity Federation** (token OIDC de GitHub → credenciales de 1 hora) restringida a `repo:refs/heads/main`, y entra al plano de control por el **endpoint DNS autenticado con IAM**, sin redes autorizadas.
- ARC se autentica contra GitHub con una **GitHub App** cuyos valores viven en Secret Manager y se materializan como Secret de Kubernetes en el bootstrap.
- Los **environments** de GitHub (`dev` sin aprobación, `production` con revisores) controlan la promoción, y los secretos de entorno se inyectan solo en el job de ese environment.

## Alternativas descartadas

| Alternativa | Por qué no |
|---|---|
| Runners de GitHub + endpoint público con redes autorizadas | Las IPs de los runners de GitHub cambian; habría que abrir rangos enormes o `0.0.0.0/0` |
| Runners de GitHub + Connect Gateway | Resuelve la red, pero sigue necesitando una identidad de GCP por job y paga cada minuto a GitHub |
| Runners en VMs (Compute Engine) con `actions-runner` | Más barato que GitHub, pero sin escalado a cero por job, parcheo manual y Docker en el host |
| Docker-in-Docker en los runners | Contenedores privilegiados en un clúster compartido; kaniko construye sin daemon |
| Claves JSON de cuenta de servicio como `secrets` de GitHub | Credenciales permanentes que hay que rotar y que acaban filtrándose; es justo lo que detecta el auditor del proyecto |

## Compromisos aceptados

- La cuenta de bootstrap tiene `roles/container.admin` porque instala CRDs y ClusterRoles de ARC. Se mitiga restringiendo quién puede asumirla (solo `main` del repositorio) y usándola solo en ese job.
- Un runner Spot puede ser expropiado a mitad de un job; GitHub lo marca como fallido y se relanza. Para pipelines largos de producción se puede añadir un segundo scale set en un pool on-demand.
- Los runners necesitan salida a internet (GitHub, ghcr.io, PyPI, base de datos de Trivy): Cloud NAT con asignación dinámica de puertos.

## Consecuencias

- ➕ Cero secretos de GCP ni de Kubernetes en GitHub.
- ➕ Coste de CI proporcional al uso real (Spot, escala a cero) y construcción de imágenes sin privilegios.
- ➕ El mismo patrón sirve para cualquier clúster privado: solo cambia el bootstrap.
- ➖ Dependencia de ARC (operador y versiones de chart que hay que mantener) y de una GitHub App que hay que rotar.
- ➖ Mientras no se haya ejecutado el bootstrap, los jobs `runs-on: gke-runners` esperan en cola; el workflow se omite por completo hasta que `vars.GCP_WIF_PROVIDER` existe.
