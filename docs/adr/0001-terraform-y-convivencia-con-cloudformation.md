# ADR-0001 · Terraform como herramienta de IaC y convivencia con CloudFormation

- **Estado:** aceptada
- **Contexto de negocio:** la plataforma ya tiene infraestructura en CloudFormation y quiere llevar su IaC "al siguiente nivel de madurez": cambios trazables, predecibles y auditados.

## Contexto

CloudFormation funciona y es nativo de AWS, pero en una plataforma que crece aparecen límites prácticos:

- Reutilizar componentes entre equipos exige *nested stacks* o macros, con versionado incómodo.
- Los *change sets* se revisan en la consola, lejos del pull request.
- Probar la lógica de una plantilla (condiciones, mappings) sin desplegar es difícil.

## Decisión

1. **Terraform para la infraestructura nueva**, organizado en módulos versionados (`modules/`) y raíces pequeñas por dominio (`projects/`), cada una con su propio estado.
2. **No migrar por migrar.** Los stacks de CloudFormation estables se mantienen. Un stack se migra cuando hay que cambiarlo de forma significativa.
3. **Migración sin recrear recursos**: bloques `import` declarativos (Terraform ≥ 1.5) con `terraform plan -generate-config-out`, revisados en PR. Después se retira el stack con `DeletionPolicy: Retain` en todos sus recursos, para que borrarlo no destruya nada.
4. **Mismos controles para ambas herramientas**: Checkov analiza Terraform y CloudFormation; CloudTrail y AWS Config auditan los cambios vengan de donde vengan.

## Consecuencias

- ➕ El plan se revisa en el PR; `terraform test` valida la lógica sin credenciales; los módulos se reutilizan entre regiones (proyecto 01).
- ➕ Estado remoto cifrado con bloqueo nativo en S3 (sin tabla DynamoDB).
- ➖ Dos herramientas durante la transición: hay que documentar qué recurso gestiona cada una (etiqueta `ManagedBy`).
- ➖ El estado de Terraform es un activo sensible: bucket con KMS, versionado, `prevent_destroy` y acceso por OIDC (ADR-0003).
