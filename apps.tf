# get EKS cluster authentication token
data "aws_eks_cluster_auth" "default" {
  name       = module.eks.cluster_name
}

# setup kubernetes provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.default.token
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.default.token
  load_config_file       = false
}

# setup helm provider
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.default.token
  }
}

provider "namecheap" {
  user_name  = var.namecheap_user_name
  api_user   = var.namecheap_user_name
  api_key    = var.namecheap_api_key
  client_ip  = var.namecheap_client_ip
  use_sandbox = var.namecheap_use_sandbox
}

# deploy cert-manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  values = [file("${path.module}/helm-values/values-cert-manager.yaml")]
  depends_on = [module.eks,]
}

resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = templatefile("${path.module}/k8s-manifests/clusterissuer.tpl.yaml", {
    letsencrypt_email = var.letsencrypt_email
  })
  depends_on = [module.eks, helm_release.cert_manager]
}

# deploy Kong Ingress Controllers (internal & external)
resource "helm_release" "kong_internal" {
  name             = "kong-internal"
  namespace        = "kong-internal"
  create_namespace = true
  repository       = "https://charts.konghq.com"
  chart            = "ingress"
  values           = [file("${path.module}/helm-values/values-kong-internal.yaml")]
  depends_on       = [module.eks]
}

resource "helm_release" "kong_external" {
  name             = "kong-external"
  namespace        = "kong-external"
  create_namespace = true
  repository       = "https://charts.konghq.com"
  chart            = "ingress"
  values           = [file("${path.module}/helm-values/values-kong-external.yaml")]
  depends_on       = [module.eks]
}

resource "kubernetes_namespace" "kong_internal" {
  metadata {
    name = "kong-internal"
    labels = {
      "app.kubernetes.io/name" = "kong-internal"
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_namespace" "kong_external" {
  metadata {
    name = "kong-external"
    labels = {
      "app.kubernetes.io/name" = "kong-external"
    }
  }
  depends_on = [module.eks]
}

resource "time_sleep" "wait_kong_lb" {
  depends_on      = [helm_release.kong_external]
  create_duration = "60s"
}

data "kubernetes_service" "kong_proxy" {
  metadata {
    name      = "kong-external-gateway-proxy"
    namespace = "kong-external"
  }
  depends_on = [time_sleep.wait_kong_lb]
}

resource "namecheap_domain_records" "dns" {
  domain = var.domain_name
  mode   = "MERGE"

  record {
    hostname = var.wildcard_hostname
    type     = "CNAME"
    address  = data.kubernetes_service.kong_proxy.status[0].load_balancer[0].ingress[0].hostname
    ttl      = var.dns_record_ttl
  }
}

resource "kubectl_manifest" "kong_plugin_mcp_correlation_id" {
  yaml_body = <<YAML
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: mcp-correlation-id
  namespace: kong-internal
plugin: correlation-id
config:
  header_name: x-request-id
  generator: uuid
  echo_downstream: true
YAML
  depends_on = [
    helm_release.kong_internal,
    kubernetes_namespace.kong_internal
  ]
}

resource "kubectl_manifest" "kong_plugin_http_log" {
  yaml_body = <<YAML
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: http-log
  namespace: kong-internal
plugin: http-log
config:
  http_endpoint: "http://http-log-receiver.kong-internal.svc.cluster.local"
  method: "POST"
  timeout: 2000
  keepalive: 60000
YAML
  depends_on = [
    kubernetes_namespace.kong_internal
  ]
}

resource "kubectl_manifest" "http_log_receiver_deployment" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-log-receiver
  namespace: kong-internal
spec:
  replicas: 1
  selector:
    matchLabels:
      app: http-log-receiver
  template:
    metadata:
      labels:
        app: http-log-receiver
    spec:
      containers:
      - name: http-echo
        image: mendhak/http-https-echo:latest
        env:
        - name: LOG_WITH_TIMESTAMPS
          value: "true"
YAML
}

resource "kubectl_manifest" "http_log_receiver_service" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  name: http-log-receiver
  namespace: kong-internal
spec:
  selector:
    app: http-log-receiver
  ports:
  - name: http
    port: 80
    targetPort: 8080
YAML

  depends_on = [
    kubectl_manifest.http_log_receiver_deployment
  ]
}

resource "kubectl_manifest" "kubernetes_mcp_bridge_service" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-mcp-server
  namespace: kong-internal
  annotations:
    konghq.com/path: "/mcp"
    konghq.com/protocol: "http"
spec:
  type: ExternalName
  externalName: kubernetes-mcp-server.kubernetes-mcp.svc.cluster.local
  ports:
    - name: http
      port: ${var.kubernetes_mcp_server_port}
YAML

  depends_on = [
    kubernetes_service.kubernetes_mcp,
    kubernetes_namespace.kong_internal
  ]
}

resource "kubectl_manifest" "falco_mcp_bridge_service" {
  yaml_body = <<YAML
apiVersion: v1
kind: Service
metadata:
  name: falco-mcp
  namespace: kong-internal
  annotations:
    konghq.com/path: "/mcp"
    konghq.com/protocol: "http"
spec:
  type: ExternalName
  externalName: falco-mcp.${var.falco_mcp_server_namespace}.svc.cluster.local
  ports:
    - name: http
      port: 8080
YAML

  depends_on = [
    kubernetes_service.falco_mcp,
    kubernetes_namespace.kong_internal
  ]
}


resource "kubectl_manifest" "kong_ingress_kubernetes_mcp" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-mcp
  namespace: kong-internal
  annotations:
    konghq.com/strip-path: "true"
    konghq.com/plugins: mcp-correlation-id,http-log
spec:
  ingressClassName: kong-internal
  rules:
  - host: kong-internal-gateway-proxy.kong-internal.svc.cluster.local
    http:
      paths:
      - path: /mcp/kubernetes
        pathType: Prefix
        backend:
          service:
            name: kubernetes-mcp-server
            port:
              number: ${var.kubernetes_mcp_server_port}
YAML

  depends_on = [
    kubectl_manifest.kong_plugin_mcp_correlation_id,
    kubectl_manifest.kubernetes_mcp_bridge_service
  ]
}

resource "kubectl_manifest" "kong_ingress_falco_mcp" {
  yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: falco-mcp
  namespace: kong-internal
  annotations:
    konghq.com/strip-path: "true"
    konghq.com/plugins: mcp-correlation-id,http-log
spec:
  ingressClassName: kong-internal
  rules:
  - host: kong-internal-gateway-proxy.kong-internal.svc.cluster.local
    http:
      paths:
      - path: /mcp/falco
        pathType: Prefix
        backend:
          service:
            name: falco-mcp
            port:
              number: 8080
YAML

  depends_on = [
    kubectl_manifest.kong_plugin_mcp_correlation_id,
    kubectl_manifest.falco_mcp_bridge_service
  ]
}

resource "kubernetes_namespace" "falco_mcp" {
  metadata {
    name = var.falco_mcp_server_namespace
    labels = {
      "app.kubernetes.io/name" = "falco-mcp"
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_deployment" "falco_mcp" {
  metadata {
    name      = "falco-mcp"
    namespace = kubernetes_namespace.falco_mcp.metadata[0].name
    labels = {
      app = "falco-mcp"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "falco-mcp"
      }
    }

    template {
      metadata {
        labels = {
          app = "falco-mcp"
        }
      }

      spec {
        container {
          name              = "falco-mcp"
          image             = var.falco_mcp_server_image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "FALCO_BASE_URL"
            value = var.falco_mcp_base_url
          }

          env {
            name  = "FALCO_USERNAME"
            value = "admin"
          }

          env {
            name  = "FALCO_PASSWORD"
            value = "admin"
          }

          env {
            name  = "PORT"
            value = "8080"
          }

          env {
            name  = "MCP_HTTP_PATH"
            value = "/mcp"
          }

          port {
            name           = "http"
            container_port = 8080
          }

        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.falco_mcp
  ]
}

resource "kubernetes_service" "falco_mcp" {
  metadata {
    name      = "falco-mcp"
    namespace = kubernetes_namespace.falco_mcp.metadata[0].name
    labels = {
      app = "falco-mcp"
    }
  }

  spec {
    selector = {
      app = "falco-mcp"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# add storage class
resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.eks.id
    directoryPerms   = "770"
    gid              = "1000"
    uid              = "1000"
    basePath         = "/"
  }
  reclaim_policy = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"
  depends_on = [
    module.eks,
    aws_eks_addon.efs-csi,
    aws_efs_file_system.eks
  ]
}

resource "helm_release" "open_webui" {
  name             = "open-webui"
  namespace        = "open-webui"
  create_namespace = true
  repository       = "https://helm.openwebui.com"
  chart            = "open-webui"
  values = [templatefile("${path.module}/helm-values/values-open-webui.yaml", {
    ingress_class = "kong-external"
    ingress_host  = var.open_webui_ingress_host
  })]
  depends_on = [
    module.eks,
    helm_release.kong_external,
    helm_release.cert_manager
  ]
}

resource "kubernetes_namespace" "kubernetes_mcp" {
  metadata {
    name = var.kubernetes_mcp_server_namespace
    labels = {
      "app.kubernetes.io/name" = "kubernetes-mcp-server"
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "kubernetes_mcp" {
  metadata {
    name      = "mcp-viewer"
    namespace = kubernetes_namespace.kubernetes_mcp.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "kubernetes-mcp-server"
    }
  }
  automount_service_account_token = true
}

resource "kubernetes_cluster_role_binding" "kubernetes_mcp_view" {
  metadata {
    name = "mcp-viewer-cluster-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.kubernetes_mcp.metadata[0].name
    namespace = kubernetes_namespace.kubernetes_mcp.metadata[0].name
  }
}

resource "kubernetes_deployment" "kubernetes_mcp" {
  metadata {
    name      = "kubernetes-mcp-server"
    namespace = kubernetes_namespace.kubernetes_mcp.metadata[0].name
    labels = {
      app = "kubernetes-mcp-server"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "kubernetes-mcp-server"
      }
    }

    template {
      metadata {
        labels = {
          app = "kubernetes-mcp-server"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.kubernetes_mcp.metadata[0].name

        container {
          name  = "server"
          image = var.kubernetes_mcp_server_image
          args = [
            "--port", tostring(var.kubernetes_mcp_server_port),
            "--read-only",
            "--log-level", "4"
          ]

          port {
            container_port = var.kubernetes_mcp_server_port
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_service_account.kubernetes_mcp,
    kubernetes_cluster_role_binding.kubernetes_mcp_view
  ]
}

resource "kubernetes_service" "kubernetes_mcp" {
  metadata {
    name      = "kubernetes-mcp-server"
    namespace = kubernetes_namespace.kubernetes_mcp.metadata[0].name
    labels = {
      app = "kubernetes-mcp-server"
    }
  }

  spec {
    selector = {
      app = "kubernetes-mcp-server"
    }

    port {
      port        = var.kubernetes_mcp_server_port
      target_port = var.kubernetes_mcp_server_port
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}
