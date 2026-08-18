variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig file"
  default     = "~/.kube/config"
}

variable "cluster_name" {
  type        = string
  description = "Name of the Kind cluster"
  default     = "veo-kickoff-cluster"
}

variable "github_repo_url" {
  type        = string
  description = "GitHub repository URL for the application"
  default     = "https://github.com/finn-e/testkube-samples.git"
}
