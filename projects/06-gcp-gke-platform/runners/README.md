# Runners self-hosted en GKE (Actions Runner Controller)

Los jobs de `.github/workflows/gcp-platform.yml` corren en runners efímeros dentro del clúster
(`runs-on: gke-runners`), en un node pool Spot que escala a cero. ARC se autentica contra GitHub
con una **GitHub App** (no con un PAT personal): credenciales de corta vida, permisos acotados al
repositorio y revocables sin tocar ninguna cuenta de usuario.

| Archivo | Contenido |
|---|---|
| `arc/controller-values.yaml` | Chart `gha-runner-scale-set-controller` 0.15.0 (namespace `arc-systems`). |
| `arc/runner-set-values.yaml` | Chart `gha-runner-scale-set` 0.15.0: scale set `gke-runners`, modo kubernetes, 0–6 runners (namespace `arc-runners`). |
| `arc/hook-template.yaml` | Plantilla de los pods de trabajo (jobs con `container:`): misma KSA, mismo pool, recursos. |
| `rbac.yaml` | KSA `arc-runner` (Workload Identity) y Roles para operar sus pods y desplegar en `platform`. |

## 1. Crear la GitHub App

En GitHub: *Settings → Developer settings → GitHub Apps → New GitHub App*.

- **Nombre**: `arc-aws-cloud-portfolio` (cualquiera); Homepage URL: la del repo; webhook desactivado.
- **Repository permissions**: `Actions: Read and write`, `Administration: Read and write`
  (registro de runners a nivel de repositorio), `Metadata: Read-only`.
- *Where can this App be installed?* → *Only on this account*.

Tras crearla:

1. Anota el **App ID** (cabecera de la página de la App).
2. *Generate a private key* → descarga el `.pem`.
3. *Install App* → instálala solo en `aws-cloud-portfolio`. El **Installation ID** es el número
   final de la URL `https://github.com/settings/installations/<ID>`.

## 2. Guardar los tres valores en Secret Manager

Los secretos los crea Terraform vacíos (`arc-github-app-id`, `arc-github-app-installation-id`,
`arc-github-app-private-key`); aquí solo se añade la versión con el valor. Nada de esto se
escribe en el repositorio ni en los values de Helm.

```bash
gcloud config set project "$PROJECT_ID"
printf '%s' "123456"  | gcloud secrets versions add arc-github-app-id --data-file=-
printf '%s' "7890123" | gcloud secrets versions add arc-github-app-installation-id --data-file=-
gcloud secrets versions add arc-github-app-private-key --data-file=./arc-app.private-key.pem
shred -u ./arc-app.private-key.pem
```

La GSA del deployer (`vars.GCP_DEPLOYER_SA`) necesita `roles/secretmanager.secretAccessor` sobre
estos tres secretos (lo concede Terraform).

## 3. Lanzar el bootstrap

*Actions → GCP · Plataforma GKE → Run workflow → action: `bootstrap-runners`*.

Es el único job del workflow que corre en `ubuntu-latest`: se autentica por Workload Identity
Federation (sin claves), crea los namespaces, publica el secreto `arc-github-app` leyendo Secret
Manager, aplica `rbac.yaml` con el email real de la GSA e instala los dos charts de ARC. Es
idempotente: se puede relanzar para actualizar versiones o values.

Comprobación:

```bash
kubectl -n arc-systems get pods                      # controlador + listener gke-runners
kubectl -n arc-runners get autoscalingrunnersets     # minRunners 0 / maxRunners 6
```

En GitHub, *Settings → Actions → Runners* muestra el runner scale set `gke-runners`. A partir de
aquí, cualquier push a `main` que toque `projects/06-gcp-gke-platform/**` construye, escanea y
despliega desde dentro del clúster.

## Rotación y baja

- Rotar la clave privada: generar una nueva en la App, añadir versión al secreto y relanzar
  `bootstrap-runners` (recrea el Secret de Kubernetes; los runners nuevos la usan).
- Dar de baja: `helm -n arc-runners uninstall gke-runners` **antes** que el controlador
  (`helm -n arc-systems uninstall arc`), para que ARC desregistre los runners de GitHub.
