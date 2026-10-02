# Bootstrap: estado remoto y GitHub OIDC

Se aplica **una sola vez por cuenta**, a mano, con credenciales de administrador. Deja preparado:

1. **Bucket S3 de estado** con versionado, SSE-KMS (clave con rotación), bloqueo de acceso público, política que exige TLS, ciclo de vida de versiones antiguas y `prevent_destroy`.
2. **Bloqueo nativo de S3** (`use_lockfile = true`, Terraform ≥ 1.10): ya no hace falta la tabla DynamoDB de locks.
3. **Proveedor OIDC de GitHub** y dos roles:

| Rol | Quién lo asume (claim `sub`) | Permisos |
|---|---|---|
| `github-terraform-plan` | `repo:<owner>/<repo>:pull_request` | `ReadOnlyAccess` + lectura del estado + escritura de `*.tflock` |
| `github-terraform-apply` | `repo:<owner>/<repo>:environment:production` | Despliegue (ver [ADR-0003](../docs/adr/0003-github-oidc.md)) |

El apply **solo** puede asumirse desde el environment `production`, que en GitHub se configura con revisores obligatorios. Un PR desde un fork, o una rama cualquiera, no puede desplegar.

## Pasos

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edita bucket y repo
terraform init
terraform apply

# En GitHub (Settings → Secrets and variables → Actions):
#   Variable de repo:          AWS_PLAN_ROLE_ARN  = $(terraform output -raw plan_role_arn)
#   Variable del environment:  AWS_APPLY_ROLE_ARN = $(terraform output -raw apply_role_arn)
#   Variable de repo:          TF_STATE_BUCKET    = $(terraform output -raw state_bucket)
```

Cada proyecto declara un backend parcial y recibe el bucket en `terraform init -backend-config`, de modo que ningún nombre de cuenta queda hardcodeado en el código.
