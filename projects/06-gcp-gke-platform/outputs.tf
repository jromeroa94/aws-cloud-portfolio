output "cluster_name" {
  description = "Nombre del clúster GKE."
  value       = google_container_cluster.platform.name
}

output "cluster_location" {
  description = "Región del clúster."
  value       = google_container_cluster.platform.location
}

output "cluster_dns_endpoint" {
  description = "Endpoint DNS del plano de control (autenticado con IAM; no requiere redes autorizadas)."
  value       = google_container_cluster.platform.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "workload_identity_provider" {
  description = "Nombre completo del proveedor OIDC para google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_deployer_service_account" {
  description = "Cuenta que asume el job de bootstrap desde GitHub Actions."
  value       = google_service_account.github_deployer.email
}

output "github_runners_service_account" {
  description = "Cuenta (Workload Identity) de los runners self-hosted."
  value       = google_service_account.github_runners.email
}

output "platform_api_service_account" {
  description = "Cuenta (Workload Identity) de los Pods de platform-api."
  value       = google_service_account.platform_api.email
}

output "artifact_registry" {
  description = "Prefijo de las imágenes de la plataforma."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.platform.repository_id}"
}

output "cloud_armor_policy" {
  description = "Nombre de la política de Cloud Armor que referencia el chart (GCPBackendPolicy)."
  value       = google_compute_security_policy.platform_edge.name
}

output "gateway_address_name" {
  description = "Nombre de la IP global reservada para el Gateway (values gateway.addressName)."
  value       = google_compute_global_address.gateway.name
}

output "gateway_ip" {
  description = "IP pública del Gateway: apunta aquí el DNS."
  value       = google_compute_global_address.gateway.address
}

output "key_auditor_job" {
  description = "Job de Cloud Run del auditor de claves."
  value       = google_cloud_run_v2_job.key_auditor.name
}

output "error_budget_minutes_per_30d" {
  description = "Minutos de indisponibilidad que permite el SLO cada 30 días."
  value       = local.error_budget_minutes_per_30d
}

output "github_repository_variables" {
  description = "Variables de repositorio que necesita .github/workflows/gcp-platform.yml."
  value = {
    GCP_PROJECT_ID     = var.project_id
    GCP_REGION         = var.region
    GCP_WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
    GCP_DEPLOYER_SA    = google_service_account.github_deployer.email
    GCP_RUNNERS_SA     = google_service_account.github_runners.email
    GCP_API_SA         = google_service_account.platform_api.email
    GKE_CLUSTER        = google_container_cluster.platform.name
    CLOUD_ARMOR_POLICY = google_compute_security_policy.platform_edge.name
  }
}

output "github_cli_commands" {
  description = "Comandos gh para configurar las variables del repositorio en un paso."
  value = join("\n", [
    for name, value in {
      GCP_PROJECT_ID     = var.project_id
      GCP_REGION         = var.region
      GCP_WIF_PROVIDER   = google_iam_workload_identity_pool_provider.github.name
      GCP_DEPLOYER_SA    = google_service_account.github_deployer.email
      GCP_RUNNERS_SA     = google_service_account.github_runners.email
      GCP_API_SA         = google_service_account.platform_api.email
      GKE_CLUSTER        = google_container_cluster.platform.name
      CLOUD_ARMOR_POLICY = google_compute_security_policy.platform_edge.name
    } : "gh variable set ${name} --repo ${local.github_repo} --body '${value}'"
  ])
}
