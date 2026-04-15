#!/usr/bin/env bash
# ==========================================================
# Automated setup for RHACM Observability setup Demo:
# - yq
# - kustomize
# - policytools
# - PolicyGenerator
#
# Requirements:
# - Logged in to OpenShift with `oc login`
# - ACM installed (for consoleclidownload resources)
# - sudo privileges
# ==========================================================

set -euo pipefail

echo "=========================================="
echo "Starting environment setup..."
echo "=========================================="

# ----------------------------------------------------------
# Check required commands
# ----------------------------------------------------------
for cmd in sudo curl tar oc jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Command '$cmd' not found."
    echo "Install it first and re-run."
    exit 1
  fi
done

# ----------------------------------------------------------
# Install dependencies
# ----------------------------------------------------------
echo "[1/5] Installing dependencies..."
sudo dnf install -y golang jq wget curl tar

# ----------------------------------------------------------
# Install yq
# ----------------------------------------------------------
echo "[2/5] Installing yq..."
go install github.com/mikefarah/yq/v4@latest

if ! grep -q 'GOPATH/bin' ~/.bashrc; then
  echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
fi

export PATH=$PATH:$(go env GOPATH)/bin

echo "yq installed:"
yq --version || true

# ----------------------------------------------------------
# Install kustomize
# ----------------------------------------------------------
echo "[3/5] Installing kustomize..."
curl -s https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash

sudo mv ./kustomize /usr/local/bin/
sudo chmod +x /usr/local/bin/kustomize

echo "kustomize installed:"
kustomize version || true

# ----------------------------------------------------------
# Install policytools
# ----------------------------------------------------------
echo "[4/5] Installing policytools..."

POLICYTOOLS_URL=$(oc get consoleclidownload acm-cli-downloads -o json | \
jq -r '.spec.links[] | select(.text=="Download policytools for Linux for x86_64").href')

wget -O policytools.tar.gz "$POLICYTOOLS_URL"

tar xvzf policytools.tar.gz
chmod +x ./policytools
sudo mv ./policytools /usr/local/bin/

echo "policytools installed:"
policytools version || true

# ----------------------------------------------------------
# Install PolicyGenerator
# ----------------------------------------------------------
echo "[5/5] Installing PolicyGenerator..."

PG_URL=$(oc get consoleclidownload acm-cli-downloads -o json | \
jq -r '.spec.links[] | select(.text=="Download PolicyGenerator for Linux for x86_64").href')

wget -O PolicyGenerator.tar.gz "$PG_URL"

tar xvzf PolicyGenerator.tar.gz

PLUGIN_DIR="$HOME/.config/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator"

mkdir -p "$PLUGIN_DIR"
mv ./PolicyGenerator "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/PolicyGenerator"

echo "PolicyGenerator installed at:"
echo "$PLUGIN_DIR/PolicyGenerator"

# ----------------------------------------------------------
# Finished
# ----------------------------------------------------------
echo ""
echo "=========================================="
echo "Setup completed successfully!"
echo "Reload shell or run:"
echo "source ~/.bashrc"
echo "=========================================="