terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0"
    }
  
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.4"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3.2"
    }

    time = {
      source  = "hashicorp/time"
    }

    namecheap = {
      source = "namecheap/namecheap"
      version = ">= 2.0.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
  required_version = "~> 1.3"
}
