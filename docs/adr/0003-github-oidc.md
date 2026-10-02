# ADR-0003 · GitHub Actions con OIDC en lugar de access keys

- **Estado:** aceptada

## Contexto

Las access keys de un usuario IAM guardadas como *secrets* de GitHub son credenciales de larga duración: no caducan, se copian entre repositorios y son el origen de muchas fugas.

## Decisión

- GitHub Actions obtiene **credenciales temporales** con `sts:AssumeRoleWithWebIdentity` a través del proveedor OIDC `token.actions.githubusercontent.com`.
- **Dos roles con trust policies distintas**, basadas en el claim `sub`:

| Rol | Condición `sub` | Permisos |
|---|---|---|
| `github-terraform-plan` | `repo:<owner>/<repo>:pull_request` | `ReadOnlyAccess` + estado + lockfile |
| `github-terraform-apply` | `repo:<owner>/<repo>:environment:production` | Despliegue |

- El environment `production` de GitHub exige **revisores** y solo permite despliegues desde `main`.
- `aud` fijado a `sts.amazonaws.com`.

## Compromiso aceptado

El rol de apply usa `AdministratorAccess` porque Terraform crea roles IAM, claves KMS y recursos de casi todos los servicios. El riesgo se contiene con:

1. La trust policy: solo el environment protegido, con aprobación humana, puede asumirlo.
2. En una organización real, **SCPs** (proyecto 03) que impiden desactivar CloudTrail, GuardDuty o Config, y salir de las regiones aprobadas.
3. Sesiones de 1 hora y trazabilidad completa en CloudTrail (`role-session-name` incluye el `run_id`).

**Siguiente paso de madurez:** un rol de apply por proyecto con una política generada a partir de la actividad real (IAM Access Analyzer *policy generation*), más un permissions boundary.

## Consecuencias

- ➕ Cero secretos de AWS en GitHub. Nada que rotar.
- ➕ Un PR desde un fork no puede asumir ningún rol.
- ➖ Requiere el bootstrap manual inicial (una vez por cuenta).
