variable "project_id" {
  description = "GCP project ID for Nexus deployment"
  type        = string
}

variable "region" {
  description = "GCP region for Nexus resources"
  type        = string
  default     = "us-east1"
}

variable "vpc_self_link" {
  description = "Self-link of the VPC network used for Cloud SQL private IP and Memorystore"
  type        = string
}

variable "master_ipv4_cidr" {
  description = "CIDR block for the GKE cluster master endpoint (/28)"
  type        = string
  default     = "172.16.0.0/28"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace where Nexus workloads run — used for Workload Identity bindings"
  type        = string
  default     = "nexus"
}

variable "db_password" {
  description = "Password for the nexus_app Cloud SQL user"
  type        = string
  sensitive   = true
}
