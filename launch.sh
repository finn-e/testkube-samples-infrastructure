#!/usr/bin/env bash

set -euo pipefail

echo "===================================================="
echo "      Veo Dev Platform Bootstrapper (OpenTofu)     "
echo "===================================================="

# Helper function to check command existence
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 1. Detect Package Manager and Install Dependencies
detect_and_install() {
  if command_exists pacman; then
    echo "[INFO] Arch Linux (pacman) detected."
    
    # Packages list
    local PKGS=()
    command_exists tofu || PKGS+=("opentofu")
    command_exists docker || PKGS+=("docker")
    command_exists kubectl || PKGS+=("kubernetes-cli")
    command_exists helm || PKGS+=("helm")
    
    if [ ${#PKGS[@]} -gt 0 ]; then
      echo "[INFO] Installing missing packages: ${PKGS[*]}"
      sudo pacman -Syu --noconfirm "${PKGS[@]}"
    else
      echo "[INFO] All core binaries (tofu, docker, kubectl, helm) are already installed."
    fi

    # Kind installation check (kind might be installed via aur or user bin)
    if ! command_exists kind; then
      echo "[INFO] Installing kind..."
      if command_exists yay; then
        yay -S --noconfirm kind-bin
      else
        echo "[INFO] Downloading kind binary..."
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
      fi
    fi

    # Hurl installation check
    if ! command_exists hurl; then
      echo "[INFO] Installing hurl..."
      if sudo pacman -S --noconfirm hurl; then
        echo "[INFO] hurl installed successfully via pacman."
      else
        echo "[INFO] Downloading hurl binary..."
        curl -Lo hurl.tar.gz https://github.com/Orange-Opensource/hurl/releases/download/4.3.0/hurl-4.3.0-x86_64-linux.tar.gz
        tar -xzf hurl.tar.gz
        sudo mv hurl-4.3.0/hurl /usr/local/bin/
        rm -rf hurl.tar.gz hurl-4.3.0
      fi
    fi

  elif command_exists apt-get; then
    echo "[INFO] Debian/Ubuntu (apt) detected."
    # Fallback/standard Debian installer path (for portability)
    sudo apt-get update
    sudo apt-get install -y docker.io kubectl helm curl tar
    # OpenTofu setup
    if ! command_exists tofu; then
      curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install.sh | sh -s -- --yes
    fi
  else
    echo "[WARNING] Unsupported package manager. Please ensure tofu, kind, docker, kubectl, helm, and hurl are installed."
  fi
}

detect_and_install

# 2. Verify Docker is running
echo "[INFO] Verifying Docker daemon status..."
if ! docker info >/dev/null 2>&1; then
  echo "[INFO] Docker is not running. Starting Docker service..."
  if command_exists systemctl; then
    sudo systemctl start docker
  else
    sudo service docker start
  fi
  sleep 2
fi

# 3. Navigate to OpenTofu folder and deploy
echo "[INFO] Initializing OpenTofu..."
cd "$(dirname "$0")/opentofu"

tofu init
tofu apply -auto-approve

echo "[INFO] Adding Kubeshop Helm repository..."
helm repo add kubeshop https://kubeshop.github.io/helm-charts --kubeconfig="$HOME/.kube/config" || true
helm repo update --kubeconfig="$HOME/.kube/config"

echo "[INFO] Pre-applying Testkube CRDs..."
helm template testkube-op kubeshop/testkube-operator --namespace testkube --create-namespace --set installCRD=true --kubeconfig="$HOME/.kube/config" | kubectl apply -f - --kubeconfig="$HOME/.kube/config"

echo "[INFO] Installing Testkube via Helm CLI..."
helm upgrade --install testkube kubeshop/testkube \
  --version 2.12.1 \
  --namespace testkube \
  --create-namespace \
  --set testkube-operator.installCRD=false \
  --set mongodb.enabled=false \
  --kubeconfig="$HOME/.kube/config"

echo "[INFO] Waiting for Helm releases to create namespaces..."
until kubectl get ns argocd testkube ingress-nginx --kubeconfig="$HOME/.kube/config" >/dev/null 2>&1; do
  sleep 2
done

echo "[INFO] Waiting for Ingress NGINX controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s --kubeconfig="$HOME/.kube/config"

echo "[INFO] Applying post-bootstrap manifests..."
kubectl apply -f bootstrap.yaml --kubeconfig="$HOME/.kube/config"

echo "[INFO] Deployment complete! Cluster config is saved to ~/.kube/config."
echo "[INFO] Ingress mappings configured:"
echo "   - Application: http://app.local"
echo "   - Argo CD:     http://argocd.local"
echo "   - Testkube:    http://testkube.local"
echo ""
echo "[IMPORTANT] Make sure to add these to your /etc/hosts file if you want to resolve them:"
echo "127.0.0.1 app.local argocd.local testkube.local"
