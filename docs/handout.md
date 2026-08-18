# Veo KickOff Developer Platform: Architecture & Technical Design Document

## 1. Design Philosophy & Vision

The primary goal of the Veo KickOff Developer Platform is to establish a **0-friction developer experience (DevEx)** for a team of 100+ software engineers. In many organizations, onboarding applications to Kubernetes introduces a steep learning curve. Developers are forced to master complex YAML schemas, handle manual containerization pipelines, configure local ingress paths, and manage API gateway routings. This platform architecture is designed to completely abstract away Kubernetes primitives, allowing developers to focus entirely on application logic.

### Decoupled Lifecycle Architecture
Our core platform philosophy splits the lifecycle into two independent, automated phases:
1.  **Day 0 Platform Infrastructure**: The platform baseline (cluster nodes, DNS, routing gates, GitOps controllers, and testing operators) is provisioned once using **OpenTofu**.
2.  **Day 1+ Developer Workflow**: Developers write code and commit changes to Git. The platform transparently builds, deploys, and verifies the application inside the cluster network.

```text
  [ Day 0: Platform Infrastructure Setup ]
  Developer runs: curl ... | bash
       |
       v (Automatically installs binaries, maps hosts, clones IaC repo)
  OpenTofu Apply (Final Step)
       |
       v (Provisions Kind Cluster, Ingress-NGINX, Argo CD, Testkube)
  Cluster Active & Ready
  
  ======================================================================
  
  [ Day 1+: GitOps Developer Workflow ]
  Developer edits code -> Git Commit & Push
       |
       v (Transparent trigger)
  Argo CD Auto-Sync (Pulls manifests from infra repository)
       |
       v (Deploys pods inside namespace)
  Argo CD PostSync Hook (Spins up verification pod)
       |
       v (Invokes in-cluster Testkube runner)
  Testkube Hurl Tests (Verifies API endpoint response codes)
       |
       v (Success)
  Sync Complete / Live (Application served at http://app.local)
```

---

## 2. Core Architectural Assumptions
To establish a stable and reproducible execution loop, the platform assumes the following baseline:
*   **Host OS Support**: The developers' machine runs a modern Linux distribution (specifically supporting Ubuntu/Debian, Fedora/RHEL, or Arch Linux). 
*   **Decoupled Repositories**: Infrastructure definitions (OpenTofu code, Helm releases, base Kubernetes manifests) and application source code are kept in completely separate Git repositories. This prevents application developers from seeing or accidentally editing Kubernetes deployment files, maintaining clean cognitive boundaries.
*   **Stateless Testing Architecture**: Integration test suites are entirely stateless. Ephemeral databases using in-memory configurations (`emptyDir`) are spun up dynamically to run test assertions, bypassing local persistent volume storage locks and disk write permission deadlocks.
*   **Local Host Routing**: Developers' workstations resolve loopback domains `app.local`, `argocd.local`, and `testkube.local` to `127.0.0.1`. The platform bootstrapper automates this injection in `/etc/hosts`.

---

## 3. Day 0: Platform Infrastructure Automation (OpenTofu & Kind)

### Local Kubernetes Cluster: Kind vs. Minikube
We selected **Kind** (Kubernetes in Docker) as our local node executor over Minikube:
*   **Performance & Footprint**: Kind runs Kubernetes nodes as lightweight Docker containers. It boots in seconds and has a tiny memory footprint compared to Minikube, which requires spinning up full hypervisor virtual machines (VirtualBox, KVM).
*   **Local Image Loading**: Kind enables direct local image ingestion (`kind load docker-image`). This allows developers to load locally built container images directly into the cluster node cache, completely bypassing remote registry pull limits.

### Infrastructure-as-Code (IaC) vs. Custom Shell Scripts
Traditional local setups rely on custom, brittle bash scripts containing sequences of `docker run` and `kubectl apply` commands. We replace these with declarative OpenTofu configuration files.
*   **Idempotency & State Tracking**: OpenTofu tracks resources in a state file, ensuring that subsequent runs (`tofu apply`) only modify resources that have drifted, rather than recreating the entire cluster.
*   **Production Parity**: By using OpenTofu Helm and Kubernetes providers, the local cluster setup mirrors the exact tooling configurations used in staging (AWS EKS) and production environments, establishing high parity.

### Dynamic Provider Authentication
In a clean, empty state, provider configurations that rely on local configuration files (`config_path = "~/.kube/config"`) will fail to plan because the cluster does not exist yet. We resolve this by feeding the resource outputs of the `kind_cluster` resource directly into the providers:
```hcl
provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  client_certificate     = kind_cluster.default.client_certificate
  client_key             = kind_cluster.default.client_key
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
}
```
This forces OpenTofu to establish a dependency line, deferring the initialization of the Kubernetes and Helm provider configurations until after the Kind cluster container has been successfully stood up.

### Zero-Touch Pipe-to-Bash Bootstrapper
To allow platform administrators and developers to bootstrap the cluster on a completely fresh computer, we developed the unified `run-testkube-samples.sh` script, located in the infrastructure repository. It can be executed remotely via:
```bash
curl -fsSL https://raw.githubusercontent.com/finn-e/testkube-samples-infrastructure/trunk/run-testkube-samples.sh | bash
```
The script operates with self-healing execution pathways:
1.  **Remote Execution Override**: If piped directly to bash (where no local folders exist), the script automatically installs `git`, clones the `testkube-samples-infrastructure` repository, and executes OpenTofu inside the cloned directory.
2.  **Local Execution Override**: If run inside an already cloned infrastructure folder, it detects the local `./opentofu` folder and runs in-place, avoiding repository duplication.
3.  **Host Ingress Setup**: Automatically injects loopback mappings to `/etc/hosts` and waits until the application serves a valid HTTP response code before automatically launching the developer's default browser to `http://app.local`.

---

## 4. Day 1+: Developer Inner Loop (GitOps & Zero-Friction)

### GitOps vs. Skaffold
Many local development tools, such as Skaffold, watch local files, build container images on every save, and push them to the cluster. While powerful, Skaffold introduces friction:
*   **Tooling Overhead**: Developers must install local container build engines, run background daemons on their host, and configure complex Skaffold manifests.
*   **Cognitive Load**: Developers must actively manage the sync daemon and understand container boundaries.

By selecting a **GitOps** model driven by **Argo CD**, we achieve true zero-friction:
*   **Transparent Delivery**: The developer's workflow is completely native: they code, commit, and push to Git. The Git push automatically triggers the Argo CD reconciliation loop.
*   **Decoupled Complexity**: Kubernetes configurations are abstracted away in the infrastructure repository, managed exclusively by platform engineers.

---

## 5. Application Sizing & Routing (Analysis of App Requirements)
The case study application is a three-tier app composed of a React frontend (`web`), a Node.js backend (`api`), and a PostgreSQL database (`db`).

### Stateful vs. Stateless Sizing (Deployments vs. StatefulSets)
*   **React Frontend & Node.js API**: Stateless components that are deployed as standard `Deployments`. They can be scaled horizontally and updated via rolling updates without risk of data loss.
*   **PostgreSQL Database**: Maintains critical persistent state. In production, deploying a database as a stateless `Deployment` is a risk. We specify that the database should run as a `StatefulSet` backed by PersistentVolumeClaims (PVCs) to guarantee stable network identifiers and prevent write-concurrency corruption.

### Pod Sizing: Vertical (VPA) vs. Horizontal (HPA) Autoscaling
*   **HPA (Alternative)**: Scales the number of pod replicas horizontally. While excellent for high-concurrency production web traffic, HPA is highly wasteful in a local developer MVP designed for a single developer. Furthermore, HPA cannot prevent a single memory-bound transaction (such as a local video processing thread) from crashing.
*   **VPA (Selected)**: Dynamically adjusts the CPU and RAM limits/requests of a single pod on-demand. VPA is selected for KickOff to adapt to the program resource needs of a single user, preventing OOM (Out-Of-Memory) container crashes during local runs.
*   **Tradeoffs**: VPA requires recreating/restarting the pod to apply new CPU/RAM configurations, introducing brief downtime. However, for a single developer, this downtime is acceptable compared to the resource waste of HPA.
*   **Why not both (HPA + VPA)**: Combining HPA and VPA (or using MPA) introduces coordinator conflicts (e.g., VPA scaling down resources while HPA scales up replicas). Resolving these requires complex policy engines. For a local MVP, this complexity is omitted.

### Path-Based Ingress Gateways
To route user traffic under a single domain (`app.local`), we configure Ingress-NGINX routing paths:
*   `/` paths route to the React `web` service (port 4173).
*   `/hello` and `/hello-pg` paths route to the Node.js `api` service (port 8080).
*   **Frontend Origin Binding**: By programming the React frontend to fetch resources dynamically from the request origin (`window.location.origin`), the client-side browser automatically targets `/hello` or `/hello-pg` on the current domain, bypassing hardcoded ports or API IPs.

### Secrets Management
Injecting raw database passwords into manifest files violates basic security practices. The platform isolates credentials using Kubernetes `Secrets`. In production, this integrates with the **External Secrets Operator (ESO)** to securely fetch passwords from cloud vaults (like AWS Secrets Manager) without developer involvement.

---

## 6. In-Cluster Verification & Testing (Testkube & Argo CD Hooks)
Traditional verification relies on running test scripts locally and port-forwarding cluster services to `localhost:8080`. This creates brittle testing setups.
*   **Native Execution**: Testkube executes tests natively inside the cluster's pod network. The Hurl container resolves the internal service endpoint (`http://ingress-nginx-controller`) directly, validating actual cluster DNS and network policies.
*   **Argo CD PostSync Hook**: We configure Testkube CLI commands to run automatically inside an Argo CD `PostSync` hook. The deployment is blocked/failed if integration tests fail, preventing bad code from being successfully synchronized.
*   **API Test Automation**: We utilize **Hurl** for API integration testing. Hurl runs fast, declarative HTTP request assertions with low container resource overhead, making it ideal for rapid post-deployment verification.

---

## 7. Case Analysis & Platform Debugging
During cluster bootstrapping and verification, we resolved critical infrastructure deadlocks that are commonly encountered in local virtualization and sandboxed environments:
*   **AVX CPU Bypass**: Modern MongoDB (5.0+) has a hard requirement for the AVX CPU instruction set and will crash on older processors or VM sandboxes. We resolved this by deploying an AVX-free MongoDB 4.4 container.
*   **Volume Write Permissions**: Standard Bitnami database charts enforce strict UID permissions (`1001`) which fail on local host-path volume mounts. We bypassed this by mounting ephemeral `emptyDir` storage for the database container.
*   **Stateless Context**: Testkube CLI commands inside the PostSync hook failed due to missing local Kubeconfigs. We bypassed this by configuring the CLI to connect directly via HTTP (`--client direct --api-uri`), routing requests statelessly over the cluster's internal service IP.

---

## 8. KickOff Production Roadmap
```text
  [Short-Term]  --> Standardize scaffolding & configure VPAs
       |
       v
  [Medium-Term] --> Deploy Loki & Grafana observability monitoring
       |
       v
  [Long-Term]   --> Provision ML GPU nodes & workload schedulers
       |
       v
  [Security]    --> Deploy External Secrets Operator (ESO) integration
```

1.  **Short-Term (Service Onboarding & VPAs)**: Standardize project scaffolding templates across teams. Define sizing tiers mapping simple descriptor keys (`small`, `medium`, `large`) to actual Kubernetes ResourceQuotas and VPAs.
2.  **Medium-Term (LGTM Observability)**: Deploy unified Loki, Grafana, Tempo, and Mimir stack for comprehensive distributed tracing and metrics monitoring.
3.  **Long-Term (ML & On-Prem K8s)**: Setup specialized GPU node pools and scheduling systems for machine learning video workloads and training.
4.  **Security (Secrets Integration)**: Deploy External Secrets Operator (ESO) to integrate securely with cloud secret vaults and manage platform credentials.

---

## 9. Image Sources
*   **Infrastructure Graphic**: Source: arwall.co (https://arwall.co/cdn/shop/articles/1223_11550787-f226-436f-bf2b-09651eb40f64_800x400.webp)
*   **All Other Images**: Source: Gemini AI (Generated by Gemini from a prompt by Fin o'Flaherty)
