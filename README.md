# Local Kubernetes GitOps Platform

A production-style local Kubernetes environment demonstrating a complete GitOps workflow. The platform uses **k3d** for a multi-node cluster, **Terraform** for infrastructure-as-code, **Argo CD** for continuous delivery, a custom **Helm chart** for application packaging, and **MySQL 8.0** with automated backup via CronJob.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Step 1 — Clone the Repository](#step-1--clone-the-repository)
5. [Step 2 — Create the k3d Cluster](#step-2--create-the-k3d-cluster)
6. [Step 3 — Configure Terraform Variables](#step-3--configure-terraform-variables)
7. [Step 4 — Deploy Everything with Terraform](#step-4--deploy-everything-with-terraform)
8. [Step 5 — Access the Argo CD UI](#step-5--access-the-argo-cd-ui)
9. [Step 6 — Verify Infrastructure (MySQL & Backups)](#step-6--verify-infrastructure-mysql--backups)
10. [Step 7 — Verify Applications (Frontend & Backend)](#step-7--verify-applications-frontend--backend)
11. [Step 8 — End-to-End Validation](#step-8--end-to-end-validation)
12. [GitOps Workflow in Action](#gitops-workflow-in-action)
13. [Helm Chart Configuration Reference](#helm-chart-configuration-reference)
14. [Terraform Configuration Reference](#terraform-configuration-reference)
15. [Private Repository Setup (Optional)](#private-repository-setup-optional)
16. [Cleanup](#cleanup)
17. [Troubleshooting](#troubleshooting)
18. [Design Decisions](#design-decisions)
19. [Technologies Used](#technologies-used)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      k3d Cluster: "gitops-cluster"                       │
│                  1 Control-Plane  +  2 Worker Nodes                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐              │
│  │ server-0       │  │  agent-0       │  │  agent-1       │              │
│  │ (control-plane)│  │  (worker)      │  │  (worker)      │              │
│  └────────────────┘  └────────────────┘  └────────────────┘              │
│                                                                          │
│ ┌────────────────────────────────────────────────────────────────┐       │
│ │  NAMESPACE: argocd                                             │       │
│ │                                                                │       │
│ │  Argo CD Server (NodePort 30443 → host :8443)                  │       │
│ │  Installed via: Terraform Helm Provider (argo-cd chart v5.55)  │       │
│ │                                                                │       │
│ │  Manages two Application CRDs:                                 │       │
│ │    ├── "infrastructure"  → watches infrastructure/ directory   │       │
│ │    └── "applications"    → watches applications/app-chart/     │       │
│ └────────────────────────────────────────────────────────────────┘       │
│                                                                          │
│  ┌─────────────────────────────┐  ┌──────────────────────────────────┐   │
│  │  NAMESPACE: applications    │  │  NAMESPACE: infrastructure       │   │
│  │                             │  │                                  │   │
│  │  Frontend (Nginx 1.25)      │  │  MySQL 8.0 Deployment            │   │
│  │    - 2 replicas             │  │    - PVC: mysql-data-pvc (5Gi)   │   │
│  │    - Serves static HTML     │  │    - Init SQL via ConfigMap      │   │
│  │    - Proxies /api/ → backend│  │    - Secret-based credentials    │   │
│  │                             │  │                                  │   │
│  │  Backend (http-echo)        │  │   Backup CronJob (*/5 min)       │   │
│  │    - 2 replicas             │  │    - mysqldump → timestamped SQL │   │
│  │    - Responds on :5678      │  │    - PVC: mysql-backup-pvc (5Gi) │   │
│  └─────────────────────────────┘  └──────────────────────────────────┘   │
│                                                                          │
│  Port Mappings (via k3d loadbalancer):                                   │
│    Host :8443  → NodePort 30443 (Argo CD UI)                             │
│    Host :8080  → NodePort 30090 (Frontend Application)                   │
└──────────────────────────────────────────────────────────────────────────┘

Data Flow:
  Browser → Frontend (Nginx) → /api/ proxy → Backend (http-echo) → response
  CronJob → mysqldump → mysql.infrastructure.svc.cluster.local → /backups/ PVC
```

### How It Works

Terraform performs all deployment in a single `terraform apply`:

1. Creates the `argocd` namespace and installs Argo CD via the official Helm chart.
2. Waits for the Argo CD server deployment to reach a ready state.
3. Creates two Argo CD `Application` CRDs using `kubectl_manifest` (defers CRD validation to apply time):
   - **infrastructure** — recursively syncs the `infrastructure/` directory (MySQL manifests + backup CronJob).
   - **applications** — syncs the `applications/app-chart/` Helm chart (frontend + backend).
4. Argo CD's automated sync policy (`prune: true`, `selfHeal: true`) keeps the cluster in sync with the Git repository at all times.

---

## Prerequisites

The following tools must be installed on your workstation before proceeding.

| Tool | Minimum Version | Purpose | Installation |
|------|------------------|---------|-------------|
| Docker | 20.10+ | Container runtime for k3d | [Docker installation guide](https://docs.docker.com/get-docker/) |
| k3d | v5.x | Runs K3s (lightweight Kubernetes) in Docker | [k3d installation guide](https://k3d.io/#installation) |
| kubectl | 1.27+ | Kubernetes CLI | [kubectl installation guide](https://kubernetes.io/docs/tasks/tools/) |
| Terraform | >= 1.5.0 | Infrastructure-as-code | [Terraform installation guide](https://developer.hashicorp.com/terraform/install) |
| Helm | 3.x | Kubernetes package manager | [Helm installation guide](https://helm.sh/docs/intro/install/) |
| Git | 2.x | Version control | [Git download and install](https://git-scm.com/downloads) |
| jq | 1.6+ | JSON processing (used by destroy script) | [jq download and install](https://jqlang.org/download/) |

> **Docker must be running** before you create the k3d cluster. Verify with `docker info`.

---

## Repository Structure

```
.
├── CLAUDE.md                                # Project context & design decisions
├── README.md                                # This file — full deployment guide
├── k3d-config.yaml                          # k3d cluster definition
├── .gitignore                               # Ignores .terraform/, state files, IDE configs
│
├── scripts/
│   └── destroy.sh                           # Clean teardown script (handles CRD finalizers)
│
├── terraform/                               # All Terraform code
│   ├── main.tf                              # Providers, argocd namespace, Helm release
│   ├── variables.tf                         # All input variable declarations
│   ├── outputs.tf                           # Argo CD URL, password command, app names
│   ├── argocd-apps.tf                       # Two Argo CD Application CRDs
│   └── terraform.tfvars.example              # Template — copy to terraform.tfvars and edit
│
├── applications/                            # Custom Helm chart (synced by Argo CD)
│   └── app-chart/
│       ├── Chart.yaml                       # Chart metadata (v0.1.0, apiVersion: v2)
│       ├── values.yaml                      # All configurable parameters
│       └── templates/
│           ├── _helpers.tpl                 # Template helpers (name, labels, selectors)
│           ├── frontend-configmap.yaml      # index.html + Nginx default.conf
│           ├── frontend-deployment.yaml     # Nginx Deployment with ConfigMap mounts
│           ├── frontend-service.yaml        # NodePort Service on port 80 (nodePort 30090)
│           ├── backend-configmap.yaml       # Database connection settings
│           ├── backend-deployment.yaml      # http-echo Deployment with configurable args
│           └── backend-service.yaml         # ClusterIP Service on port 5678
│
└── infrastructure/                          # Raw K8s manifests (synced by Argo CD)
    ├── mysql/
    │   ├── namespace.yaml                   # "infrastructure" namespace definition
    │   ├── mysql-secret.yaml                # Opaque Secret with base64 credentials
    │   ├── mysql-pvc.yaml                   # 5Gi PVC (local-path StorageClass)
    │   ├── mysql-configmap.yaml             # init.sql — creates tables + seed data
    │   ├── mysql-deployment.yaml            # MySQL 8.0, Recreate strategy, health probes
    │   └── mysql-service.yaml               # ClusterIP on port 3306
    └── backup/
        ├── backup-pvc.yaml                  # 5Gi PVC for backup files
        └── backup-cronjob.yaml              # Every-5-min mysqldump with timestamped output
```

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/xlxhxm/local-k3d-gitops-platform.git
cd local-k3d-gitops-platform
```

---

## Step 2 — Create the k3d Cluster

The `k3d-config.yaml` file defines a cluster named `gitops-cluster` with 1 control-plane node and 2 worker nodes. It maps host port `8443` to NodePort `30443` (Argo CD) and host port `8080` to NodePort `30090` (frontend application). Traefik is disabled since we don't need an ingress controller for this demo.

```bash
# Ensure Docker is running
docker info > /dev/null 2>&1 || echo "Docker is not running — please start it first"

# Create the cluster
k3d cluster create --config k3d-config.yaml
```

**Verify the cluster is operational:**

```bash
kubectl get nodes -o wide
```

You should see three nodes, all in `Ready` status:

```
NAME                           STATUS   ROLES                  AGE   VERSION
k3d-gitops-cluster-server-0    Ready    control-plane,master   45s   v1.28.x
k3d-gitops-cluster-agent-0     Ready    <none>                 40s   v1.28.x
k3d-gitops-cluster-agent-1     Ready    <none>                 40s   v1.28.x
```

**Verify your kubectl context is pointing at the new cluster:**

```bash
kubectl config current-context
# Expected output: k3d-gitops-cluster
```

> The k3d config sets `updateDefaultKubeconfig: true` and `switchCurrentContext: true`, so kubectl is automatically configured.

---

## Step 3 — Configure Terraform Variables

Before running Terraform, you must update one critical variable — the URL of your Git repository. Argo CD needs this to know where to pull manifests from.

```bash
cd terraform

# Create your local tfvars file from the example template
cp terraform.tfvars.example terraform.tfvars
```

> **Note:** `terraform.tfvars` is git-ignored so your real values (repo URL, credentials, etc.) are never committed. Only the `.example` template is tracked in version control.

Open `terraform.tfvars` in your editor and replace the placeholder values:

```hcl
# terraform/terraform.tfvars

kubeconfig_path      = "~/.kube/config"
kubeconfig_context   = "k3d-gitops-cluster"
argocd_namespace     = "argocd"
argocd_chart_version = "5.55.0"
argocd_nodeport      = "30443"

# >>>  CHANGE THIS to your actual repository URL  <<<
git_repo_url         = "https://github.com/xlxhxm/local-k3d-gitops-platform.git"
git_target_revision  = "main"

infrastructure_namespace = "infrastructure"
applications_namespace   = "applications"
```

> **Important:** All project files must be committed and pushed to the repository before Argo CD can sync them. Push your code now if you haven't already:
> ```bash
> cd ..
> git add -A && git commit -m "Initial project setup" && git push origin main
> cd terraform
> ```

---

## Step 4 — Deploy Everything with Terraform

This single command installs Argo CD and configures the two Application CRDs that drive everything else.

```bash
# Initialize providers (downloads hashicorp/helm, hashicorp/kubernetes, alekc/kubectl, hashicorp/null)
terraform init

# Preview what will be created
terraform plan

# Deploy (type "yes" when prompted)
terraform apply
```

**What Terraform does (in order):**

1. Creates the `argocd` Kubernetes namespace.
2. Deploys the Argo CD Helm chart (`argo-cd` v5.55.0 from `argoproj.github.io/argo-helm`) into that namespace with:
   - `fullnameOverride: argocd` so resources are named `argocd-server`, `argocd-repo-server`, etc.
   - Server exposed as NodePort on port `30443` (HTTPS with self-signed TLS cert)
   - Controller and repo-server set to 1 replica each (reduced footprint)
3. Runs a `null_resource` with `local-exec` that executes `kubectl rollout status deployment/argocd-server` to wait until Argo CD is fully ready (up to 300s timeout).
4. Creates two `kubectl_manifest` resources for the Argo CD Application CRDs (using the `alekc/kubectl` provider, which doesn't require CRDs to exist at plan time):
   - **`infrastructure`** — monitors `infrastructure/` with `directory.recurse: true`, automated sync with `prune` and `selfHeal`, and `CreateNamespace=true` + `ServerSideApply=true` sync options.
   - **`applications`** — monitors `applications/app-chart/` as a Helm source with `values.yaml`, automated sync with `prune` and `selfHeal`, and `CreateNamespace=true`.

**Expected terraform output:**

```
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

Outputs:

applications_app = "applications"
argocd_initial_password_command = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
argocd_namespace = "argocd"
argocd_server_url = "https://localhost:8443"
infrastructure_app = "infrastructure"
```

After Terraform completes, Argo CD will automatically begin syncing both applications from your Git repository. This typically takes 1–3 minutes for all pods to become ready.

---

## Step 5 — Access the Argo CD UI

**Retrieve the initial admin password:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

**Open the Argo CD dashboard in your browser:**

```
https://localhost:8443
```

> Your browser will show a TLS certificate warning since k3d uses a self-signed cert. Click "Advanced" → "Proceed to localhost" (or equivalent for your browser).

**Login with:**

- **Username:** `admin`
- **Password:** the output from the command above

**What you should see in the UI:**

Two application cards on the dashboard:

| Application | Source Path | Namespace | Expected Status |
|-------------|------------|-----------|-----------------|
| `infrastructure` | `infrastructure/` (directory, recursive) | `infrastructure` | Synced / Healthy |
| `applications` | `applications/app-chart/` (Helm) | `applications` | Synced / Healthy |

**Optional — verify from the CLI using the Argo CD CLI tool:**

```bash
# Install the CLI (macOS)
brew install argocd

# Login to Argo CD
argocd login localhost:8443 --insecure \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# List all applications
argocd app list

# Detailed status for each
argocd app get infrastructure
argocd app get applications
```

---

## Step 6 — Verify Infrastructure (MySQL & Backups)

### 6.1 — Check MySQL is Running

```bash
# List all pods in the infrastructure namespace
kubectl -n infrastructure get pods
```

Expected output:

```
NAME                     READY   STATUS    RESTARTS   AGE
mysql-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

```bash
# Verify both PVCs are Bound
kubectl -n infrastructure get pvc
```

Expected output:

```
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
mysql-data-pvc     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   5Gi        RWO            local-path     2m
mysql-backup-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   5Gi        RWO            local-path     2m
```

### 6.2 — Test MySQL Connectivity

```bash
# Ping test — should return "mysqld is alive"
kubectl -n infrastructure exec deploy/mysql -- \
  mysqladmin ping -h localhost -u root -prootpassword123
```

### 6.3 — Verify Database Initialization

The `mysql-configmap.yaml` contains an `init.sql` script that creates two tables (`users` and `messages`) with seed data. Verify this ran correctly:

```bash
# Check that the tables exist and contain seed data
kubectl -n infrastructure exec deploy/mysql -- \
  mysql -u root -prootpassword123 -e "USE appdb; SHOW TABLES;"
```

Expected output:

```
+------------------+
| Tables_in_appdb  |
+------------------+
| messages         |
| users            |
+------------------+
```

```bash
# Query the seed data
kubectl -n infrastructure exec deploy/mysql -- \
  mysql -u root -prootpassword123 -e "SELECT * FROM appdb.users;"
```

Expected output:

```
+----+------------+-------------------+---------------------+
| id | username   | email             | created_at          |
+----+------------+-------------------+---------------------+
|  1 | admin      | admin@example.com | 2024-xx-xx xx:xx:xx |
|  2 | demo_user  | demo@example.com  | 2024-xx-xx xx:xx:xx |
+----+------------+-------------------+---------------------+
```

```bash
kubectl -n infrastructure exec deploy/mysql -- \
  mysql -u root -prootpassword123 -e "SELECT * FROM appdb.messages;"
```

Expected output:

```
+----+---------+----------------------------------------------------+---------------------+
| id | user_id | content                                            | created_at          |
+----+---------+----------------------------------------------------+---------------------+
|  1 |       1 | Welcome to the GitOps demo application!            | 2024-xx-xx xx:xx:xx |
|  2 |       2 | This data persists in MySQL with PVC-backed storage| 2024-xx-xx xx:xx:xx |
+----+---------+----------------------------------------------------+---------------------+
```

### 6.4 — Verify the Backup CronJob

The CronJob runs every 5 minutes. It uses the `mysql:8.0` image (which includes `mysqldump`), pulls the root password from the `mysql-secret` Kubernetes Secret, and writes timestamped `.sql` files to the `mysql-backup-pvc` PersistentVolumeClaim.

```bash
# Check the CronJob exists and see the schedule
kubectl -n infrastructure get cronjobs
```

Expected output:

```
NAME           SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
mysql-backup   */5 * * * *   False     0        2m              5m
```

```bash
# List completed backup jobs
kubectl -n infrastructure get jobs
```

```bash
# Check logs from the most recent backup job pod
kubectl -n infrastructure logs job/$(kubectl -n infrastructure get jobs \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

Expected log output:

```
Starting MySQL backup at Mon Jan 15 10:05:01 UTC 2024...
Backup file: /backups/appdb_backup_20240115_100501.sql
Backup completed successfully!
File: /backups/appdb_backup_20240115_100501.sql (2584 bytes)

--- Existing backups ---
total 8.0K
-rw-r--r-- 1 root root 2.5K Jan 15 10:00 appdb_backup_20240115_100001.sql
-rw-r--r-- 1 root root 2.5K Jan 15 10:05 appdb_backup_20240115_100501.sql
```

**Exec into the backup PVC to inspect files directly:**

```bash
kubectl -n infrastructure run backup-inspector --rm -it \
  --image=mysql:8.0 \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "backup-inspector",
        "image": "mysql:8.0",
        "command": ["sh", "-c", "echo \"=== Backup files ===\" && ls -lh /backups/ && echo && echo \"=== Latest backup (first 20 lines) ===\" && head -20 /backups/$(ls -t /backups/ | head -1)"],
        "volumeMounts": [{
          "name": "backup-storage",
          "mountPath": "/backups"
        }]
      }],
      "volumes": [{
        "name": "backup-storage",
        "persistentVolumeClaim": {
          "claimName": "mysql-backup-pvc"
        }
      }]
    }
  }'
```

This will show all backup files and print the first 20 lines of the most recent one, confirming the SQL dump contains valid data.

---

## Step 7 — Verify Applications (Frontend & Backend)

### 7.1 — Check Application Pods

```bash
kubectl -n applications get pods
```

Expected output (2 frontend + 2 backend replicas):

```
NAME                                          READY   STATUS    RESTARTS   AGE
applications-app-chart-frontend-xxxxx-xxxxx   1/1     Running   0          3m
applications-app-chart-frontend-xxxxx-xxxxx   1/1     Running   0          3m
applications-app-chart-backend-xxxxx-xxxxx    1/1     Running   0          3m
applications-app-chart-backend-xxxxx-xxxxx    1/1     Running   0          3m
```

```bash
kubectl -n applications get svc
```

Expected output:

```
NAME                              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
applications-app-chart-frontend   NodePort    10.43.x.x       <none>        80:30090/TCP   3m
applications-app-chart-backend    ClusterIP   10.43.x.x       <none>        5678/TCP       3m
```

### 7.2 — Test the Frontend

The frontend is exposed as a NodePort (30090), which k3d maps to host port 8080. You can access it directly:

```bash
# Access the frontend via the k3d port mapping (no port-forward needed)
curl -s http://localhost:8080

# Or open in your browser
open http://localhost:8080
```

You should see the HTML content including `<h1>GitOps Demo - Frontend</h1>` and the JavaScript that fetches from `/api/`.

> **Alternative:** If you changed the service type to ClusterIP, use port-forward instead:
> ```bash
> kubectl -n applications port-forward svc/applications-app-chart-frontend 9090:80 &
> curl -s http://localhost:9090
> ```

### 7.3 — Test the Backend

```bash
# Port-forward the backend service (ClusterIP, not directly exposed)
kubectl -n applications port-forward svc/applications-app-chart-backend 5678:5678 &

# Hit the backend directly
curl -s http://localhost:5678
```

Expected output:

```
Hello from the Backend! Database host: mysql.infrastructure.svc.cluster.local
```

---

## Step 8 — End-to-End Validation

This confirms the full data flow: Browser → Nginx Frontend → `/api/` reverse proxy → Backend → response.

```bash
# Frontend proxies /api/ to the backend service internally
curl -s http://localhost:8080/api/
```

Expected output:

```
Hello from the Backend! Database host: mysql.infrastructure.svc.cluster.local
```

This works because the Nginx `default.conf` (generated from the Helm chart's `frontend-configmap.yaml`) proxies all requests to `/api/` to the backend service:

```nginx
location /api/ {
    proxy_pass http://applications-app-chart-backend:5678/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

**Verify MySQL data persists across pod restarts:**

```bash
# Insert a new row
kubectl -n infrastructure exec deploy/mysql -- \
  mysql -u root -prootpassword123 -e \
  "INSERT INTO appdb.users (username, email) VALUES ('test_user', 'test@example.com');"

# Delete the MySQL pod (Kubernetes will recreate it using the PVC)
kubectl -n infrastructure delete pod -l app.kubernetes.io/name=mysql

# Wait for the new pod to become ready
kubectl -n infrastructure wait --for=condition=ready pod -l app.kubernetes.io/name=mysql --timeout=120s

# Verify the data survived the restart
kubectl -n infrastructure exec deploy/mysql -- \
  mysql -u root -prootpassword123 -e "SELECT * FROM appdb.users;"
```

You should see all three users (admin, demo_user, and test_user), confirming PVC-backed persistence works correctly.

---

## GitOps Workflow in Action

Once everything is deployed, the GitOps workflow is fully operational. Any change pushed to the tracked Git branch will be automatically synced by Argo CD.

**Example — scale the frontend to 3 replicas:**

```bash
# 1. Edit the values file
sed -i 's/replicaCount: 2/replicaCount: 3/' applications/app-chart/values.yaml

# 2. Commit and push
git add applications/app-chart/values.yaml
git commit -m "Scale frontend to 3 replicas"
git push origin main

# 3. Watch Argo CD detect and sync the change (within ~3 minutes by default)
#    Or trigger a manual sync:
argocd app sync applications

# 4. Verify
kubectl -n applications get pods -l app.kubernetes.io/name=frontend
# Should now show 3 pods
```

**Example — change the backend response message:**

```bash
# 1. Edit values.yaml backend.args
# Change the -text argument to a new message

# 2. Commit, push, and Argo CD will roll out new backend pods automatically
```

---

## Helm Chart Configuration Reference

The custom Helm chart at `applications/app-chart/` manages both the frontend and backend as a single release. All parameters are configurable through `values.yaml`.

### Frontend Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `frontend.enabled` | Deploy the frontend component | `true` |
| `frontend.replicaCount` | Number of frontend pod replicas | `2` |
| `frontend.image.repository` | Container image repository | `nginx` |
| `frontend.image.tag` | Container image tag | `1.25-alpine` |
| `frontend.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `frontend.service.type` | Kubernetes Service type | `NodePort` |
| `frontend.service.port` | Service port | `80` |
| `frontend.service.targetPort` | Container port | `80` |
| `frontend.service.nodePort` | NodePort (when type is NodePort) | `30090` |
| `frontend.resources.requests.cpu` | CPU request | `50m` |
| `frontend.resources.requests.memory` | Memory request | `64Mi` |
| `frontend.resources.limits.cpu` | CPU limit | `200m` |
| `frontend.resources.limits.memory` | Memory limit | `128Mi` |
| `frontend.indexHtml` | Full HTML content for the index page | (see values.yaml) |

### Backend Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `backend.enabled` | Deploy the backend component | `true` |
| `backend.replicaCount` | Number of backend pod replicas | `2` |
| `backend.image.repository` | Container image repository | `hashicorp/http-echo` |
| `backend.image.tag` | Container image tag | `latest` |
| `backend.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `backend.service.type` | Kubernetes Service type | `ClusterIP` |
| `backend.service.port` | Service port | `5678` |
| `backend.service.targetPort` | Container port | `5678` |
| `backend.args` | Arguments passed to http-echo | `["-text=Hello from the Backend!...", "-listen=:5678"]` |
| `backend.resources.requests.cpu` | CPU request | `50m` |
| `backend.resources.requests.memory` | Memory request | `32Mi` |
| `backend.resources.limits.cpu` | CPU limit | `200m` |
| `backend.resources.limits.memory` | Memory limit | `64Mi` |
| `backend.env` | Additional environment variables (list) | `[]` |

---

## Terraform Configuration Reference

All Terraform variables are defined in `terraform/variables.tf` with sensible defaults. Copy `terraform.tfvars.example` to `terraform.tfvars` and override them there.

| Variable | Description | Default |
|----------|-------------|---------|
| `kubeconfig_path` | Path to the kubeconfig file | `~/.kube/config` |
| `kubeconfig_context` | Kubernetes context to use | `k3d-gitops-cluster` |
| `argocd_namespace` | Namespace for Argo CD installation | `argocd` |
| `argocd_chart_version` | Version of the argo-cd Helm chart | `5.55.0` |
| `argocd_nodeport` | NodePort for Argo CD HTTPS | `30443` |
| `git_repo_url` | Git repository URL for Argo CD | *(must be set)* |
| `git_target_revision` | Git branch/tag/commit to track | `main` |
| `infrastructure_namespace` | Namespace for MySQL and backups | `infrastructure` |
| `applications_namespace` | Namespace for frontend/backend | `applications` |

### Terraform Resources Created

| Resource | Type | Purpose |
|----------|------|---------|
| `kubernetes_namespace.argocd` | Namespace | Houses all Argo CD components |
| `helm_release.argocd` | Helm Release | Installs Argo CD from official chart |
| `null_resource.wait_for_argocd` | Null (local-exec) | Waits for argocd-server rollout |
| `kubectl_manifest.argocd_app_infrastructure` | Argo CD Application | Syncs `infrastructure/` directory |
| `kubectl_manifest.argocd_app_applications` | Argo CD Application | Syncs `applications/app-chart/` Helm chart |

### Terraform Outputs

| Output | Description |
|--------|-------------|
| `argocd_namespace` | Namespace where Argo CD is installed |
| `argocd_server_url` | URL to access the Argo CD UI |
| `argocd_initial_password_command` | kubectl command to retrieve the admin password |
| `infrastructure_app` | Name of the infrastructure Argo CD Application |
| `applications_app` | Name of the applications Argo CD Application |

---

## Private Repository Setup (Optional)

If your Git repository is private, Argo CD needs credentials to pull from it. There are two approaches:

### Option A — Using the Argo CD CLI

```bash
argocd repo add https://github.com/xlxhxm/local-k3d-gitops-platform.git \
  --username <your-github-username> \
  --password <personal-access-token>
```

### Option B — Using a Kubernetes Secret

```bash
kubectl -n argocd create secret generic repo-creds \
  --from-literal=url=https://github.com/xlxhxm/local-k3d-gitops-platform.git \
  --from-literal=username=<your-github-username> \
  --from-literal=password=<personal-access-token>

kubectl -n argocd label secret repo-creds \
  argocd.argoproj.io/secret-type=repository
```

### Option C — Using SSH

```bash
argocd repo add git@github.com:xlxhxm/local-k3d-gitops-platform.git \
  --ssh-private-key-path ~/.ssh/id_ed25519
```

> Remember to update `git_repo_url` in `terraform.tfvars` to the SSH URL format if using Option C.

---

## Cleanup

### Recommended: Use the destroy script

The included `scripts/destroy.sh` handles Argo CD CRD finalizers, stuck namespaces, and Terraform state cleanup automatically — no more hanging `terraform destroy`:

```bash
# Full teardown (Terraform + k3d cluster)
./scripts/destroy.sh

# Terraform only — keep the k3d cluster running
./scripts/destroy.sh --keep-cluster
```

The script performs these steps in order:

1. Gracefully deletes Argo CD Application CRDs
2. Strips finalizers from any stuck Argo CD resources
3. Removes Argo CD CRDs to unblock namespace deletion
4. Force-clears any Terminating namespaces
5. Runs `terraform destroy`
6. Deletes the k3d cluster (unless `--keep-cluster`)

### Manual cleanup (alternative)

```bash
# Step 1: Destroy Terraform-managed resources (Argo CD + Application CRDs)
cd terraform
terraform destroy
# Type "yes" when prompted

# Step 2: Delete the k3d cluster (this removes all namespaces, pods, PVCs, etc.)
k3d cluster delete gitops-cluster

# Step 3: Verify cleanup
docker ps                      # Should show no k3d-related containers
kubectl config get-contexts    # "k3d-gitops-cluster" should be gone
```

> **Note:** If `terraform destroy` hangs, it's likely due to Argo CD CRD finalizers preventing namespace deletion. Use `scripts/destroy.sh` instead, or manually remove finalizers with:
> ```bash
> kubectl -n argocd patch applications.argoproj.io --all --type=json \
>   -p='[{"op":"remove","path":"/metadata/finalizers"}]'
> ```

---

## Troubleshooting

### Argo CD Application Stuck in "Progressing" or "Unknown"

```bash
# Check the sync status and any errors
argocd app get infrastructure
argocd app get applications

# View detailed sync operation info
argocd app get infrastructure --show-operation

# Check Argo CD controller logs for sync errors
kubectl -n argocd logs deploy/argocd-application-controller --tail=50

# Check repo-server logs (issues pulling from Git)
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

### Argo CD Cannot Reach the Git Repository

```bash
# Test repository connectivity from Argo CD
argocd repo list

# Check that the URL matches what's in terraform.tfvars
argocd repo get https://github.com/xlxhxm/local-k3d-gitops-platform.git

# Verify the repo server can resolve external DNS
kubectl -n argocd exec deploy/argocd-repo-server -- \
  nslookup github.com
```

### MySQL Pod Not Starting

```bash
# Check pod status and events
kubectl -n infrastructure describe pod -l app.kubernetes.io/name=mysql

# Check MySQL container logs
kubectl -n infrastructure logs deploy/mysql

# Verify PVC is bound
kubectl -n infrastructure get pvc mysql-data-pvc

# Common issue: If the PVC is stuck in "Pending", the StorageClass may not exist
kubectl get storageclass
# k3d ships with "local-path" — verify it's listed
```

### Backup CronJob Not Creating Jobs

```bash
# Confirm the CronJob is present and not suspended
kubectl -n infrastructure get cronjob mysql-backup -o yaml | grep -A2 "schedule\|suspend"

# Check if MySQL is reachable from within the cluster
kubectl -n infrastructure run dns-test --rm -it \
  --image=busybox --restart=Never -- \
  nslookup mysql.infrastructure.svc.cluster.local

# Manually trigger a backup job to test
kubectl -n infrastructure create job --from=cronjob/mysql-backup manual-backup-test

# Watch it run
kubectl -n infrastructure logs job/manual-backup-test -f
```

### Frontend Not Reachable at localhost:8080

```bash
# Verify the frontend service is NodePort with port 30090
kubectl -n applications get svc applications-app-chart-frontend

# Verify k3d is mapping the port correctly
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep k3d

# Alternative: use port-forward instead
kubectl -n applications port-forward svc/applications-app-chart-frontend 9090:80 &
curl http://localhost:9090
```

### Port-Forward Not Working

```bash
# Kill any stale port-forwards
pkill -f "port-forward" 2>/dev/null

# Re-establish fresh port-forward for backend
kubectl -n applications port-forward svc/applications-app-chart-backend 5678:5678 &
```

### Terraform Apply Fails with "argocd-server not ready"

The `null_resource.wait_for_argocd` waits up to 300 seconds. If your machine is slow:

```bash
# Check if Argo CD pods are still pulling images
kubectl -n argocd get pods

# If pods are in ImagePullBackOff, check Docker connectivity
docker pull ghcr.io/argoproj/argocd:v2.10.0

# Retry terraform apply (it will pick up where it left off)
terraform apply
```

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Single Helm chart** for frontend + backend | Simplifies release management; both components share lifecycle and can be enabled/disabled via `values.yaml` |
| **`alekc/kubectl` provider** for Argo CD Apps | The `kubernetes_manifest` resource (from `hashicorp/kubernetes`) validates CRDs at plan time, which fails before Argo CD is installed. `kubectl_manifest` (from `alekc/kubectl`) defers validation to apply time, solving the chicken-and-egg problem |
| **Raw manifests** for MySQL (not a Helm subchart) | Argo CD syncs the `infrastructure/` directory recursively; raw manifests give full control and are simpler to inspect |
| **`mysql:8.0` image** for both database and CronJob | The backup CronJob uses the same image as the database, which already includes `mysqldump` — no separate client image needed |
| **Recreate deployment strategy** for MySQL | Required because the PVC uses `ReadWriteOnce` access mode — only one pod can mount it at a time |
| **`ServerSideApply=true`** for infrastructure app | Avoids field-ownership conflicts when Argo CD applies manifests that may overlap with other controllers |
| **`fullnameOverride: argocd`** in Helm release | Ensures predictable resource names (`argocd-server`, `argocd-repo-server`) instead of auto-generated `argocd-argo-cd-*` names |
| **Argo CD with self-signed TLS** (no insecure mode) | Serves HTTPS on NodePort 30443; avoids port-mapping issues that arise when insecure mode disables the HTTPS listener |
| **Frontend as NodePort (30090)** | Mapped via k3d to host port 8080 for direct browser access without requiring port-forward |
| **Traefik disabled** in k3d config | Not needed for this demo; services are accessed via NodePort |
| **`null_resource` with `local-exec`** for readiness | Ensures Argo CD is fully operational before Terraform creates Application CRDs, preventing race conditions |

---

## Authorship and delivery approach

The system architecture, repository structure, separation of concerns, initial Terraform resource design, YAML/GitOps logic, and core technical design decisions were authored by myself.

To accelerate execution, I used personal AI agents to assist with documentation, data population, variable filling, and parts of the setup workflow. These agents were used as productivity tooling, not as a replacement for technical ownership.

All outputs were reviewed twice: first through the agent-assisted workflow, and then through a separate personal verification pass by me. Final technical validation and sign-off were completed personally.

---

## Technologies Used

| Technology | Version | Role |
|------------|---------|------|
| **k3d** | v5.x | Local multi-node Kubernetes cluster (K3s in Docker) |
| **Terraform** | >= 1.5.0 | Infrastructure-as-code — installs Argo CD and defines Application CRDs |
| **Argo CD** | v2.x (Helm chart 5.55.0) | GitOps continuous delivery — syncs cluster state with Git |
| **Helm** | v3.x | Application packaging — custom chart for frontend + backend |
| **MySQL** | 8.0 | Relational database with PVC-backed persistent storage |
| **Nginx** | 1.25-alpine | Frontend web server serving static HTML with API reverse proxy |
| **hashicorp/http-echo** | latest | Lightweight backend HTTP server for demonstration |
| **Docker** | 20.10+ | Container runtime underpinning k3d |
