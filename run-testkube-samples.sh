#!/usr/bin/env bash

set -euo pipefail

echo "===================================================="
echo "    Veo KickOff Platform Bootstrapper (GitOps)      "
echo "===================================================="

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 1. Detect OS and install Git, Docker + CLI utilities via native package managers
detect_and_install_prereqs() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_LIKE=${ID_LIKE:-""}
  else
    OS_ID=$(uname -s | tr '[:upper:]' '[:lower:]')
    OS_LIKE=""
  fi

  echo "[INFO] Detected OS: $OS_ID (LIKE: $OS_LIKE)"

  if [[ "$OS_ID" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
    echo "[INFO] Managing dependencies via pacman..."
    sudo pacman -Syu --noconfirm --needed curl tar git
    if ! command_exists docker; then
      sudo pacman -S --noconfirm docker
    fi
  elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
    echo "[INFO] Managing dependencies via apt-get..."
    sudo apt-get update
    sudo apt-get install -y curl tar ca-certificates gnupg git
    if ! command_exists docker; then
      sudo apt-get install -y docker.io
    fi
  elif [[ "$OS_ID" == "fedora" || "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* ]]; then
    echo "[INFO] Managing dependencies via dnf..."
    sudo dnf install -y curl tar git
    if ! command_exists docker; then
      sudo dnf install -y moby-engine || sudo dnf install -y docker
    fi
  else
    echo "[WARNING] Unknown OS: $OS_ID. Attempting to install packages with fallback methods..."
  fi

  # Ensure Docker is started
  echo "[INFO] Verifying Docker daemon status..."
  if ! docker info >/dev/null 2>&1; then
    echo "[INFO] Starting Docker daemon..."
    if command_exists systemctl; then
      sudo systemctl start docker
      sudo systemctl enable docker
    else
      sudo service docker start
    fi
    sleep 3
  fi

  # Install OpenTofu via official script (multi-distro)
  if ! command_exists tofu; then
    echo "[INFO] Installing OpenTofu..."
    curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install.sh | sh -s -- --yes
  fi

  # Install Kind binary (multi-distro)
  if ! command_exists kind; then
    echo "[INFO] Installing Kind..."
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
  fi

  # Install Kubectl binary (multi-distro)
  if ! command_exists kubectl; then
    echo "[INFO] Installing Kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x ./kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
  fi

  # Install Helm via official script (multi-distro)
  if ! command_exists helm; then
    echo "[INFO] Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
  fi
}

detect_and_install_prereqs

# 2. Check for infrastructure repository or local folders
if [ -d "opentofu" ]; then
  echo "[INFO] Running in-place inside the repository directory."
  INFRA_DIR="."
else
  INFRA_DIR="testkube-samples-infrastructure"
  if [ ! -d "$INFRA_DIR" ]; then
    echo "[INFO] Infrastructure folder not found. Cloning testkube-samples-infrastructure..."
    git clone https://github.com/finn-e/testkube-samples-infrastructure.git "$INFRA_DIR"
  fi
fi

# 3. Add local host mappings if missing
echo "[INFO] Verifying local DNS hosts resolution mappings..."
if ! grep -q "app.local" /etc/hosts; then
  echo "[INFO] Adding app.local, argocd.local, and testkube.local mappings to /etc/hosts..."
  echo "127.0.0.1 app.local argocd.local testkube.local" | sudo tee -a /etc/hosts
fi

# 4. OpenTofu Initialization and Infrastructure Provisioning
echo "[INFO] Provisioning local Kind cluster and core controllers via OpenTofu..."
tofu -chdir="$INFRA_DIR/opentofu" init
tofu -chdir="$INFRA_DIR/opentofu" apply -auto-approve

# 5. Bootstrap Testkube Configurations & Custom AVX-free Database
echo "[INFO] Registering Kubeshop Helm repositories..."
helm repo add kubeshop https://kubeshop.github.io/helm-charts --kubeconfig="$HOME/.kube/config" || true
helm repo update --kubeconfig="$HOME/.kube/config"

echo "[INFO] Pre-applying Testkube CRD schemas..."
kubectl create namespace testkube --dry-run=client -o yaml | kubectl apply -f - --kubeconfig="$HOME/.kube/config"
helm template testkube-op kubeshop/testkube-operator --namespace testkube --create-namespace --set installCRD=true --kubeconfig="$HOME/.kube/config" | kubectl apply -f - --kubeconfig="$HOME/.kube/config"

echo "[INFO] Deploying Testkube control plane components..."
helm upgrade --install testkube kubeshop/testkube \
  --version 2.12.1 \
  --namespace testkube \
  --create-namespace \
  --set testkube-operator.installCRD=false \
  --set mongodb.enabled=false \
  --kubeconfig="$HOME/.kube/config"

echo "[INFO] Waiting for core namespaces to initialize..."
until kubectl get ns argocd testkube ingress-nginx --kubeconfig="$HOME/.kube/config" >/dev/null 2>&1; do
  sleep 2
done

echo "[INFO] Waiting for Ingress controller readiness..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s --kubeconfig="$HOME/.kube/config"

echo "[INFO] Deploying custom AVX-free MongoDB database and application routing..."
kubectl apply -f "$INFRA_DIR/opentofu/bootstrap.yaml" --kubeconfig="$HOME/.kube/config"

# 6. Wait for application availability and open browser
echo "[INFO] Waiting for the web application to serve endpoints (http://app.local)..."
until curl -s -o /dev/null -w "%{http_code}" http://app.local | grep -E "200|301|302|404" >/dev/null; do
  sleep 2
done

echo "[INFO] Infrastructure bootstrap and deployment complete!"
echo "[INFO] Launching default web browser pointing at: http://app.local"
xdg-open "http://app.local" || echo "[WARNING] Could not open browser automatically. Please visit http://app.local manually."
