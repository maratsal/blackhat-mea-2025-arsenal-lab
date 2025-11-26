variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}


variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_private_subnets" {
  description = "VPC private subnets list"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "vpc_public_subnets" {
  description = "VPC public subnets list"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "eks_cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.34"
}

# please check following link for the list of all available eks_managed_node_groups options - https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/modules/eks-managed-node-group/variables.tf#L284
variable "eks_managed_node_groups" {
  description = "EKS managed node group settings"
  default = {
    one = {
      name                       = "node-group-1"
      instance_types             = ["t3a.large"]
#      ami_type                   = "BOTTLEROCKET_x86_64"
      ami_type                   = "AL2023_x86_64_STANDARD"
      min_size                   = 1
      max_size                   = 1
      desired_size               = 1
      disk_size                  = 100
      use_custom_launch_template = false
      # capacity_type              = "SPOT"
    }
#    graviton = {
#      ami_type                   = "AL2023_ARM_64_STANDARD"
#      name                       = "node-group-graviton"
#      instance_types             = ["t4g.xlarge"]
#      min_size                   = 1
#      max_size                   = 3
#      desired_size               = 1
#      disk_size                  = 100
#      use_custom_launch_template = false
#    }
  }
}

# Namecheap provider sensitive/configuration variables
variable "namecheap_user_name" {
  description = "Namecheap account user name"
  type        = string
}

variable "namecheap_api_key" {
  description = "Namecheap API key"
  type        = string
  sensitive   = true
}

variable "namecheap_client_ip" {
  description = "Client IP authorized for Namecheap API access"
  type        = string
}

variable "namecheap_use_sandbox" {
  description = "Use Namecheap sandbox API"
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Primary domain name for DNS records"
  type        = string
  default     = "salakhutdinov.com"
}

variable "wildcard_hostname" {
  description = "Wildcard hostname (without domain) for subdomain"
  type        = string
  default     = "*.blackhat"
}

variable "dns_record_ttl" {
  description = "TTL for created DNS records"
  type        = number
  default     = 300
}

# variable "sysdig_access_key" {
#   description = "Sysdig Shield access key"
#   type        = string
#   sensitive   = true
# }

# variable "sysdig_region" {
#   description = "Sysdig backend region"
#   type        = string
#   default     = "us2"
# }

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks"
}

variable "letsencrypt_email" {
  description = "Email address for ACME (Let's Encrypt) registration"
  type        = string
  default     = "marat@salakhutdinov.com"
}

variable "open_webui_ingress_class" {
  description = "Ingress class used by Open WebUI"
  type        = string
  default     = "kong"
}

variable "open_webui_ingress_host" {
  description = "FQDN for the Open WebUI ingress"
  type        = string
  default     = "openwebui.blackhat.salakhutdinov.com"
}

variable "kubernetes_mcp_server_namespace" {
  description = "Namespace to deploy the Kubernetes MCP server"
  type        = string
  default     = "kubernetes-mcp"
}

variable "kubernetes_mcp_server_image" {
  description = "Container image for the Kubernetes MCP server"
  type        = string
  default     = "quay.io/manusa/kubernetes_mcp_server:v0.0.54"
}

variable "kubernetes_mcp_server_port" {
  description = "Service port exposed by the Kubernetes MCP server"
  type        = number
  default     = 8080
}

variable "falco_mcp_server_namespace" {
  description = "Namespace to deploy the Falco MCP server"
  type        = string
  default     = "falco-mcp"
}

variable "falco_mcp_server_image" {
  description = "Container image for the Falco MCP server"
  type        = string
  default     = "quay.io/maratsal/falco-mcp:latest"
}

variable "falco_mcp_base_url" {
  description = "Falco Sidekick UI base URL the MCP server should call"
  type        = string
  default     = "http://falco-falcosidekick-ui.falco.svc.cluster.local:2802"
}

variable "falco_registry_user" {
  description = "Username used by Falco to pull custom artifacts from the OCI registry"
  type        = string
  default     = ""
}

variable "falco_registry_host" {
  description = "Registry hostname that stores custom Falco artifacts"
  type        = string
  default     = "quay.io"
}

variable "falco_registry_password" {
  description = "Password or token used by Falco to pull custom artifacts from the OCI registry"
  type        = string
  sensitive   = true
  default     = ""
}

