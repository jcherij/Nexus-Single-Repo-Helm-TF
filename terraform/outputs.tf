output "gke_cluster_name" {
  description = "GKE Autopilot cluster name"
  value       = google_container_cluster.nexus.name
}

output "cloudsql_instance_connection_name" {
  description = "Cloud SQL instance connection name — used in Cloud SQL Auth Proxy arguments"
  value       = google_sql_database_instance.nexus.connection_name
}

output "memorystore_host" {
  description = "Memorystore Redis private IP — used in Helm values for session cache connection"
  value       = google_redis_instance.nexus_cache.host
}

output "nav_updates_topic" {
  description = "Pub/Sub topic name for NAV update events"
  value       = google_pubsub_topic.nav_updates.name
}

output "workload_sa_email" {
  description = "GCP service account email federated to the nexus-workload Kubernetes ServiceAccount"
  value       = google_service_account.nexus_workload.email
}

output "cloudsql_proxy_sa_email" {
  description = "GCP service account email federated to the nexus-cloudsql-proxy Kubernetes ServiceAccount"
  value       = google_service_account.nexus_cloudsql_proxy.email
}
