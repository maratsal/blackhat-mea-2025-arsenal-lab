# BlackHat MEA 2025 Arsenal Lab – MCP powered AI Threat Detection Platform

This repository contains the Terraform, Helm values, and Kubernetes manifests that power our BlackHat MEA Arsenal Lab demo. The lab showcases an end-to-end detection and investigation stack for Kubernetes and AWS-based workloads: Falco continuously inspects runtime signals, Model Context Protocol (MCP) servers expose those signals to generative AI copilots for investigations and Kong OSS acts as a traffic backbone for AI tooling, logging, and statistics.

---

## Why This Repository Exists

- **BlackHat MEA 2025 Arsenal Lab** – provide an opinionated, reproducible environment that visitors can explore hands-on.
- **Hybrid Telemetry** – Falco watches Linux syscalls, Kubernetes audit events and AWS CloudTrail (via the Falco CT plugin) so both cluster and cloud activity feed the same pipeline.
- **AI-accelerated Response** – MCP servers expose curated APIs for AI assistants so human analysts can pivot faster through Kong-hosted endpoints.
- **Open-Source by Default** – everything from the infrastructure (Terraform) to the AI gateway (Kong OSS) remains transparent.

---

## High-Level Architecture

```
                     ┌────────────────────────────┐
                     │        AWS Cloud           │
                     │                            │
                     │  ┌──────────────────────┐  │
                     │  │  CloudTrail Service  │◀─┼─ Falco CloudTrail plugin pulls events
                     │  └──────────────────────┘  │
                     │                            │
                     │  ┌──────────────────────┐  │
                     │  │  CloudWatch Logs     │◀─┼─ Falco k8s-audit plugin streams audit logs
                     │  └──────────────────────┘  │
                     │                            │
                     │  ┌──────────────────────┐  │
                     │  │  EKS Cluster         │  │
                     │  │  • Falco DaemonSet   │◀─┼─ Syscalls + plugin feeds
                     │  │  • Falco MCP         │◀─┼─ Consumes Falco Sidekick UI API
                     │  │  • Kubernetes MCP    │◀─┼─ Calls Kubernetes API
                     │  │  • Kong Internal GW  │──┼─ /mcp/* (http-log → log receiver)
                     │  │  • Kong External GW  │──┼─ Any public ingress (optional)
                     │  │  • Open WebUI        │──┼─ Runs prompts inside cluster
                     │  │  • cert-manager      │──┼─ Let’s Encrypt TLS issuance
                     │  └──────────────────────┘  │
                     └────────────────────────────┘
                                      │
                                      │ Kong-managed MCP traffic (mirrored)
                                      ▼
                       ┌────────────────────────┐
                       │   HTTP Log Receiver    │ (in-cluster)
                       └────────────────────────┘

                       ┌────────────────────────┐
                       │   OpenAI GPT-5.1 API   │  ◀── Open WebUI calls for reasoning
                       └────────────────────────┘
```

- Falco agents in the EKS cluster stream security findings to dedicated MCP services (Falco MCP, Kubernetes MCP).
- Falco collects Linux syscalls, Kubernetes audit logs, and AWS CloudTrail events (via Falco’s CloudTrail plugin) before forwarding them.
- Falco MCP and Kubernetes MCP servers are deployed inside the same EKS cluster for low-latency access to runtime data.
- Kong OSS exposes the MCP endpoints through custom plugins (http-log, correlation-id) plus structured logging, while Open WebUI is hosted separately and only reaches the cluster through those Kong-managed routes.
- AWS-level detections (e.g., GuardDuty) are accessible through the same AI-assisted flows, giving analysts a unified cockpit.

---

## Repository Layout

| Path / File | Description |
|-------------|-------------|
| `main.tf`, `apps.tf`, `falco.tf`, `variables.tf` | Terraform infrastructure for AWS networking, EKS, IAM, Falco extras, Helm/Kubernetes resources, and DNS. |
| `helm-values/` | Opinionated overrides for Kong (internal/external gateways), cert-manager, Falco, Loki, Open WebUI, etc. |
| `k8s-manifests/` | Additional YAML templates (e.g., `clusterissuer.tpl.yaml`) rendered through Terraform’s `templatefile`. |
| `open-webui-config-files/` | Source-controlled Open WebUI configuration (system prompt, prompt suggestions, client settings) synced into the deployment. |

---

## Key Capabilities

- **Runtime Detection** – Falco with custom rules for Kubernetes API abuse, container escapes, and AWS misconfigurations.
- **AI-driven Triage** – MCP servers expose curated APIs to AI clients (Open WebUI today) so analysts can ask free-form questions (“show Falco hits in namespace X the last hour”).
- **Gateway Observability** – Kong OSS terminates all AI traffic, injects correlation IDs, and forwards http-log payloads to in-cluster receivers for forensic replay.
- **Multi-cloud Awareness** – Terraform modules cover AWS VPC, NAT, EKS Managed Node Groups, EFS, and Namecheap DNS so you can replicate the lab in minutes.

---

## Deployment Workflow

The lab still favors a two-phase Terraform apply to avoid racing the Kubernetes provider while EKS boots:

1. **Bootstrap EKS and dependencies**
   ```bash
   terraform init
   terraform apply -target=module.eks
   ```
   Optional: `aws eks update-kubeconfig ...` to validate `kubectl get nodes`.

2. **Roll out the stack**
   ```bash
   terraform apply
   ```
   This step installs Helm releases (cert-manager, Kong internal/external, Falco, Open WebUI) plus Kubernetes manifests (storage class, ClusterIssuer, Kong plugins, MCP services, etc.).

3. **Outputs**
   ```bash
   terraform output
   terraform output -raw <sensitive-output>
   ```
   Use these to grab endpoints (e.g., Open WebUI) and initial secrets (`argocd_admin_password` if Argo CD is enabled later).

---

## Falco + MCP Investigation Flow

1. Falco agents continuously watch Linux syscalls, ingest Kubernetes audit events from CloudWatch Logs (via the `k8saudit-eks` plugin), and pull AWS CloudTrail anomalies (via the Falco CloudTrail plugin).
2. Falco MCP receives normalized Falco events by querying the Falco Sidekick API; Kubernetes MCP discovers resources directly through the Kubernetes API.
3. Both MCP services run inside the same EKS cluster alongside Falco, Open WebUI, Kong gateways, and cert-manager.
4. Open WebUI communicates with the MCP services via the Kong internal ingress (`/mcp/*`). Kong enforces:
   - `correlation-id` for traceability
   - `http-log` to forward MCP traffic to the in-cluster HTTP log receiver
5. HTTP log receiver archives every request/response, while responses flow back through Kong to Open WebUI where AI copilots (backed by OpenAI GPT-5.1) summarize findings, highlight blast radius, and recommend next actions.

Result: security engineers can pivot between Falco, cluster state, and AWS context without leaving the AI console.

---

## SOC Analyst Workflow

1. **Prompting from Open WebUI** – A SOC specialist issues a natural-language request (“Investigate the latest Falco hits for namespace `payments`”) from the Open WebUI instance running in the cluster.
2. **MCP Access** – The request travels through Kong’s internal ingress, which injects a correlation ID and mirrors HTTP logs to the receiver.
3. **Context Assembly** – Falco MCP queries Falco (including CloudTrail + CloudWatch-derived events) while Kubernetes MCP pulls live cluster state; both respond via Kong.
4. **AI Guidance** – Open WebUI forwards the combined evidence to OpenAI GPT-5.1, receives a structured summary (timeline, impacted resources, remediation tips), and presents it to the analyst.

This workflow keeps all telemetry in-cluster while providing fully traced AI-assisted investigations.

### Open WebUI System Prompt

```
You are a cybersecurity AI assistant specialized in analyzing security events.

Before starting any investigation, please check all available tools first and use those for your investigation.

Your task is to:
1. Analyze Falco security events by using falco_* tools from the provided time frame.
2. After gathering initial information from Falco events, analyze potentially affected Kubernetes resources by reviewing them with kubernetes_* tools.
3. Determine if all findings above represent a real security threat.
4. Identify any patterns or correlations between events.
5. Provide a concise summary of the threat (if real). If it doesn't look dangerous, provide an honest opinion.
6. Recommend specific actions to contain and mitigate the threat.

Focus on actionable insights and be precise in your recommendations.
```

---

## Kong OSS as the AI Backbone

- **Ingress Classes**: `kong-internal` (ClusterIP) for east-west traffic, `kong-external` (LoadBalancer) for user-facing portals such as Open WebUI.
- **Plugins Enabled**: `http-log`, `correlation-id`, custom ones for OpenAI-style routing (request-transformer for API keys, etc.).
- **Logging & Stats**: The internal gateway ships logs to an in-cluster receiver (`http-log-receiver`) so we can replay AI conversations during demos or investigations.

---

## Getting Started Quickly

```bash
# 1. Configure AWS credentials + required TF_VAR_* secrets
aws sts get-caller-identity
export TF_VAR_letsencrypt_email="you@example.com"

# 2. Initialize + deploy
terraform init
terraform apply

# 3. Inspect Kong + Falco
kubectl get pods -n kong-internal
kubectl get pods -n falco
```

Use `helm-values/` as starting points if you need to tweak Kong, Falco, or cert-manager behavior for your environment.

---

## DNS & Namecheap Support

This lab assumes DNS is managed through Namecheap:

- `namecheap_domain_records` in `apps.tf` creates the wildcard CNAME (e.g., `*.blackhat`) that points your domain to the external Kong load balancer.
- Provider credentials (`namecheap_user_name`, `namecheap_api_key`, `namecheap_client_ip`) are passed via Terraform variables, making it easy to swap in your own Namecheap account.
- If you host DNS elsewhere, remove the Namecheap provider and replace the CNAME provisioning with your preferred DNS automation, but keep the wildcard pointing at the Kong external proxy so TLS (via cert-manager/Let’s Encrypt) still works.

Make sure your Namecheap account allows API access from the IP you specify, and note that records may take a few minutes to propagate.

---

## Contributing / Extending

- Add new MCP services (e.g., GuardDuty, Config) under `apps.tf` with matching Kong routes.
- Drop additional Helm values in `helm-values/` and wire them through Terraform `helm_release` resources.
- For new demos (BlackHat, DEF CON, internal workshops), fork + adjust DNS, TLS, or Open WebUI prompts.

Please open issues or PRs if you improve the detection content, AI workflows, or documentation.

---

**Contact**: Bring questions or demo requests to the BlackHat MEA Arsenal Lab booth or file an issue in this repo.
