terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ──────────────────────────────────────────────
# KMS
# ──────────────────────────────────────────────

resource "google_kms_key_ring" "nexus" {
  name     = "nexus-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "nexus" {
  name            = "nexus-key"
  key_ring        = google_kms_key_ring.nexus.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

# ──────────────────────────────────────────────
# Service accounts — Workload Identity pattern
# No static credentials in the GKE cluster
# ──────────────────────────────────────────────

resource "google_service_account" "nexus_workload" {
  account_id   = "nexus-workload"
  display_name = "Nexus Workload Identity SA"
  description  = "Federated from the nexus-workload Kubernetes ServiceAccount via Workload Identity. Accesses Cloud SQL, Pub/Sub, and Memorystore."
}

resource "google_service_account" "nexus_cloudsql_proxy" {
  account_id   = "nexus-cloudsql-proxy"
  display_name = "Nexus Cloud SQL Proxy SA"
  description  = "Used by the Cloud SQL Auth Proxy sidecar in GKE. Has roles/cloudsql.client only."
}

# Workload Identity binding — links GKE KSA to GCP SA
resource "google_service_account_iam_binding" "nexus_workload_identity" {
  service_account_id = google_service_account.nexus_workload.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/nexus-workload]"
  ]
}

resource "google_service_account_iam_binding" "nexus_cloudsql_proxy_identity" {
  service_account_id = google_service_account.nexus_cloudsql_proxy.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/nexus-cloudsql-proxy]"
  ]
}

# ──────────────────────────────────────────────
# GKE cluster — Autopilot for managed node lifecycle
# ──────────────────────────────────────────────

resource "google_container_cluster" "nexus" {
  name             = "nexus-cluster"
  location         = var.region
  enable_autopilot = true

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.nexus.id
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  ip_allocation_policy {}

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }
}

# ──────────────────────────────────────────────
# Cloud SQL — PostgreSQL for portfolio holdings
# ──────────────────────────────────────────────

resource "google_sql_database_instance" "nexus" {
  name             = "nexus-postgres"
  database_version = "POSTGRES_15"
  region           = var.region

  deletion_protection = true

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "REGIONAL" # multi-AZ for Tier 2 HA

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.vpc_self_link
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = 30
      }
    }

    disk_encryption_key {
      kms_key_name = google_kms_crypto_key.nexus.id
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }
  }
}

resource "google_sql_database" "portfolio" {
  name     = "portfolio"
  instance = google_sql_database_instance.nexus.name
}

resource "google_sql_user" "nexus_app" {
  name     = "nexus_app"
  instance = google_sql_database_instance.nexus.name
  password = var.db_password
}

# ──────────────────────────────────────────────
# Pub/Sub — NAV update events
# ──────────────────────────────────────────────

resource "google_pubsub_topic" "nav_updates" {
  name = "nexus-nav-updates"

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  kms_key_name = google_kms_crypto_key.nexus.id
}

resource "google_pubsub_subscription" "nexus_nav_consumer" {
  name  = "nexus-nav-consumer"
  topic = google_pubsub_topic.nav_updates.name

  ack_deadline_seconds       = 30
  message_retention_duration = "43200s" # 12 hours

  retry_policy {
    minimum_backoff = "5s"
    maximum_backoff = "60s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.nav_updates_dlq.id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_topic" "nav_updates_dlq" {
  name         = "nexus-nav-updates-dlq"
  kms_key_name = google_kms_crypto_key.nexus.id
}

# ──────────────────────────────────────────────
# Memorystore — Redis session cache
# ──────────────────────────────────────────────

resource "google_redis_instance" "nexus_cache" {
  name               = "nexus-session-cache"
  tier               = "STANDARD_HA"
  memory_size_gb     = 2
  region             = var.region
  authorized_network = var.vpc_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  auth_enabled       = true

  redis_configs = {
    maxmemory-policy = "allkeys-lru"
  }
}

# ──────────────────────────────────────────────
# IAM — workload service account bindings
# Tier 2: scoped narrowly per the IAM Governance Policy
# ──────────────────────────────────────────────

resource "google_project_iam_member" "nexus_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.nexus_workload.email}"
}

resource "google_project_iam_member" "nexus_pubsub_viewer" {
  project = var.project_id
  role    = "roles/pubsub.viewer"
  member  = "serviceAccount:${google_service_account.nexus_workload.email}"
}

resource "google_project_iam_member" "nexus_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  # Cloud SQL Auth Proxy sidecar shares the pod SA (nexus-workload).
  member  = "serviceAccount:${google_service_account.nexus_workload.email}"
}
