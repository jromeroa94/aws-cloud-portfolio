# Tests de plan con proveedor simulado: verifican las decisiones de seguridad, red,
# FinOps y observabilidad sin credenciales de Google Cloud.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number     = "123456789012"
      project_id = "demo-platform"
    }
  }
}

# Emails deterministas: el proveedor valida el formato de `member`, y así los tests
# pueden comprobar qué cuenta usa cada recurso.
override_resource {
  target = google_service_account.gke_nodes
  values = {
    email  = "gke-nodes@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:gke-nodes@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/gke-nodes@demo-platform.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.github_deployer
  values = {
    email  = "github-deployer@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:github-deployer@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/github-deployer@demo-platform.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.github_runners
  values = {
    email  = "github-runners@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:github-runners@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/github-runners@demo-platform.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.platform_api
  values = {
    email  = "platform-api@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:platform-api@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/platform-api@demo-platform.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.key_auditor
  values = {
    email  = "key-auditor@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:key-auditor@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/key-auditor@demo-platform.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.scheduler
  values = {
    email  = "scheduler@demo-platform.iam.gserviceaccount.com"
    member = "serviceAccount:scheduler@demo-platform.iam.gserviceaccount.com"
    name   = "projects/demo-platform/serviceAccounts/scheduler@demo-platform.iam.gserviceaccount.com"
  }
}

variables {
  project_id         = "demo-platform"
  billing_account_id = "012345-6789AB-CDEF01"
  alert_email        = "guardia@example.com"
  enforce_no_sa_keys = true
}

run "cluster_privado_y_endurecido" {
  command = plan

  assert {
    condition     = google_container_cluster.platform.private_cluster_config[0].enable_private_nodes == true
    error_message = "Los nodos deben ser privados (sin IP pública)."
  }

  assert {
    condition     = google_container_cluster.platform.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled == false
    error_message = "El endpoint público no debe aceptar rangos públicos de Google por defecto."
  }

  assert {
    condition     = google_container_cluster.platform.control_plane_endpoints_config[0].dns_endpoint_config[0].allow_external_traffic == true
    error_message = "El bootstrap desde GitHub usa el endpoint DNS autenticado con IAM."
  }

  assert {
    condition     = google_container_cluster.platform.workload_identity_config[0].workload_pool == "demo-platform.svc.id.goog"
    error_message = "Workload Identity debe apuntar al pool del proyecto."
  }

  assert {
    condition     = google_container_cluster.platform.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2 es necesario para NetworkPolicy sin add-ons."
  }

  assert {
    condition     = google_container_cluster.platform.database_encryption[0].state == "ENCRYPTED"
    error_message = "Los secretos de etcd deben cifrarse con la clave de KMS."
  }

  assert {
    condition     = google_container_cluster.platform.gateway_api_config[0].channel == "CHANNEL_STANDARD"
    error_message = "El chart usa Gateway API."
  }

  assert {
    condition     = google_container_cluster.platform.release_channel[0].channel == "REGULAR"
    error_message = "Canal REGULAR: parches automáticos sin ser el primero en recibirlos."
  }

  assert {
    condition     = google_container_cluster.platform.binary_authorization[0].evaluation_mode == "DISABLED"
    error_message = "Binary Authorization está desactivado por defecto (opt-in documentado)."
  }
}

run "pools_apps_y_runners" {
  command = apply # los emails de las cuentas de servicio se conocen tras el apply simulado

  assert {
    condition     = google_container_node_pool.runners.node_config[0].spot == true
    error_message = "Los runners van en Spot."
  }

  assert {
    condition     = google_container_node_pool.runners.autoscaling[0].total_min_node_count == 0
    error_message = "Sin trabajos de CI, cero nodos de runners."
  }

  assert {
    condition     = google_container_node_pool.runners.node_config[0].taint[0].key == "dedicated" && google_container_node_pool.runners.node_config[0].taint[0].effect == "NO_SCHEDULE"
    error_message = "El taint impide que las aplicaciones caigan en nodos Spot."
  }

  assert {
    condition     = google_container_node_pool.apps.node_config[0].spot != true
    error_message = "Las aplicaciones no deben correr en Spot."
  }

  assert {
    condition     = alltrue([for p in [google_container_node_pool.apps, google_container_node_pool.runners] : p.node_config[0].shielded_instance_config[0].enable_secure_boot])
    error_message = "Todos los pools con Secure Boot."
  }

  assert {
    condition     = alltrue([for p in [google_container_node_pool.apps, google_container_node_pool.runners] : p.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA"])
    error_message = "Workload Identity exige el servidor de metadatos de GKE en cada pool."
  }

  assert {
    condition     = alltrue([for p in [google_container_node_pool.apps, google_container_node_pool.runners] : p.node_config[0].service_account == google_service_account.gke_nodes.email])
    error_message = "Los nodos usan la cuenta mínima, nunca la de Compute por defecto."
  }

  assert {
    condition     = !contains(local.node_roles, "roles/editor") && !contains(local.node_roles, "roles/owner")
    error_message = "La cuenta de los nodos no puede ser Editor ni Owner."
  }
}

run "red_privada_con_salida_por_nat" {
  command = plan

  assert {
    condition     = google_compute_network.platform.auto_create_subnetworks == false
    error_message = "VPC personalizada, sin subredes automáticas."
  }

  assert {
    condition     = length(google_compute_subnetwork.gke.secondary_ip_range) == 2
    error_message = "Rangos secundarios para Pods y Services."
  }

  assert {
    condition     = google_compute_subnetwork.gke.private_ip_google_access == true
    error_message = "Acceso privado a las APIs de Google."
  }

  assert {
    condition     = google_compute_router_nat.platform.source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    error_message = "Cloud NAT para toda la subred."
  }

  assert {
    condition     = google_compute_firewall.deny_ingress.priority > google_compute_firewall.master_webhooks.priority
    error_message = "La denegación general debe tener menor prioridad que las reglas específicas."
  }
}

run "identidad_federada_sin_claves" {
  command = apply # el nombre del pool de identidades es un valor calculado

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "jromeroa94")
    error_message = "Solo tokens del owner autorizado pueden intercambiarse."
  }

  assert {
    condition     = endswith(google_service_account_iam_member.github_deployer_wif.member, "attribute.repository_ref/jromeroa94/aws-cloud-portfolio:refs/heads/main")
    error_message = "El bootstrap solo puede asumirse desde la rama main del repositorio."
  }

  assert {
    condition     = google_service_account_iam_member.github_runners_wi.member == "serviceAccount:demo-platform.svc.id.goog[arc-runners/arc-runner]"
    error_message = "La KSA arc-runner del namespace arc-runners es la única que puede actuar como la GSA de runners."
  }

  assert {
    condition     = google_service_account_iam_member.platform_api_wi.member == "serviceAccount:demo-platform.svc.id.goog[platform/platform-api]"
    error_message = "La KSA platform-api del namespace platform es la única que puede actuar como la GSA de la API."
  }

  assert {
    condition     = length(google_org_policy_policy.disable_sa_keys) == 1 && google_org_policy_policy.disable_sa_keys[0].spec[0].rules[0].enforce == "TRUE"
    error_message = "Con enforce_no_sa_keys=true se prohíbe crear claves de SA en el proyecto."
  }

  assert {
    condition     = !contains(keys(google_project_iam_member.key_auditor), "roles/iam.serviceAccountKeyAdmin")
    error_message = "En modo informe el auditor no puede desactivar claves."
  }
}

run "slos_y_burn_rates" {
  command = plan

  assert {
    condition     = google_monitoring_slo.availability.goal == 0.999 && google_monitoring_slo.availability.rolling_period_days == 30
    error_message = "SLO de disponibilidad 99.9 % en ventana móvil de 30 días."
  }

  assert {
    condition     = google_monitoring_alert_policy.availability_burn_rate["fast"].conditions[0].condition_threshold[0].threshold_value == 14.4
    error_message = "Burn rate rápido: 14.4x en 1 hora."
  }

  assert {
    condition     = google_monitoring_alert_policy.availability_burn_rate["slow"].conditions[0].condition_threshold[0].threshold_value == 6
    error_message = "Burn rate lento: 6x en 6 horas."
  }

  assert {
    condition     = google_monitoring_alert_policy.availability_burn_rate["fast"].severity == "CRITICAL" && google_monitoring_alert_policy.availability_burn_rate["slow"].severity == "WARNING"
    error_message = "Solo la ventana rápida despierta a alguien."
  }

  assert {
    condition     = local.error_budget_minutes_per_30d == 43
    error_message = "Un SLO de 99.9 % permite 43 minutos al mes."
  }

  assert {
    condition     = google_monitoring_slo.latency.request_based_sli[0].distribution_cut[0].range[0].max == 500
    error_message = "Umbral de latencia de 500 ms."
  }

  assert {
    condition     = length(google_monitoring_notification_channel.email) == 1
    error_message = "Con alert_email se crea el canal de notificación."
  }
}

run "finops_registro_y_presupuesto" {
  command = plan

  assert {
    condition     = length(google_artifact_registry_repository.platform.cleanup_policies) == 4
    error_message = "Cuatro políticas de limpieza: dos KEEP y dos DELETE."
  }

  assert {
    condition     = length([for p in google_artifact_registry_repository.platform.cleanup_policies : p if p.action == "KEEP"]) == 2
    error_message = "Las imágenes recientes y latest-main se conservan."
  }

  assert {
    condition     = length(google_billing_budget.platform) == 1
    error_message = "Con billing_account_id se crea el presupuesto."
  }

  assert {
    condition     = sort([for r in google_billing_budget.platform[0].threshold_rules : "${r.spend_basis}:${r.threshold_percent}"]) == sort(["CURRENT_SPEND:0.5", "CURRENT_SPEND:0.8", "CURRENT_SPEND:1", "FORECASTED_SPEND:1"])
    error_message = "Umbrales 50/80/100 % del gasto real y 100 % del previsto."
  }

  assert {
    condition     = google_billing_budget.platform[0].amount[0].specified_amount[0].units == "150"
    error_message = "Presupuesto de 150 USD por defecto."
  }
}

run "auditor_de_claves_en_modo_informe" {
  command = apply

  assert {
    condition     = [for e in google_cloud_run_v2_job.key_auditor.template[0].template[0].containers[0].env : e.value if e.name == "ENFORCE"][0] == "false"
    error_message = "El auditor nace en modo informe (dry-run)."
  }

  assert {
    condition     = [for e in google_cloud_run_v2_job.key_auditor.template[0].template[0].containers[0].env : e.value if e.name == "PROJECT_ID"][0] == "demo-platform"
    error_message = "El auditor recibe el proyecto por variable de entorno."
  }

  assert {
    condition     = google_cloud_scheduler_job.key_auditor.time_zone == "America/Lima" && google_cloud_scheduler_job.key_auditor.schedule == "0 7 * * *"
    error_message = "Auditoría diaria a las 07:00 hora de Lima."
  }

  assert {
    condition     = google_cloud_run_v2_job.key_auditor.template[0].template[0].service_account == google_service_account.key_auditor.email
    error_message = "El job corre con su propia cuenta, no con la de Compute por defecto."
  }
}

run "borde_con_waf_y_rate_limit" {
  command = plan

  assert {
    condition     = length([for r in google_compute_security_policy.platform_edge.rule : r if r.action == "rate_based_ban"]) == 1
    error_message = "Debe existir una regla de rate limiting por IP."
  }

  assert {
    condition     = length([for r in google_compute_security_policy.platform_edge.rule : r if startswith(r.action, "deny")]) == 3
    error_message = "Reglas preconfiguradas OWASP para SQLi, XSS y CVEs conocidas."
  }

  assert {
    condition     = google_compute_security_policy.platform_edge.adaptive_protection_config[0].layer_7_ddos_defense_config[0].enable == true
    error_message = "Protección adaptativa L7 activada."
  }
}

run "sin_presupuesto_ni_canal_si_no_se_configuran" {
  command = plan

  variables {
    billing_account_id = ""
    alert_email        = ""
    enforce_no_sa_keys = false
  }

  assert {
    condition     = length(google_billing_budget.platform) == 0
    error_message = "Sin cuenta de facturación no se crea presupuesto."
  }

  assert {
    condition     = length(google_monitoring_notification_channel.email) == 0 && length(google_monitoring_alert_policy.container_restarts.notification_channels) == 0
    error_message = "Sin correo no hay canal ni destinatarios."
  }

  assert {
    condition     = length(google_org_policy_policy.disable_sa_keys) == 0
    error_message = "La política de organización es opt-in."
  }
}
