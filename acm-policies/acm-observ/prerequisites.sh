#!/usr/bin/env bash
# ==========================================================
# Automated setup for RHACM Observability setup Demo:
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
# Install kustomize
# ----------------------------------------------------------
echo "[1/3] Installing kustomize..."
curl -s https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash

sudo mv ./kustomize /usr/local/bin/
sudo chmod +x /usr/local/bin/kustomize

echo "kustomize installed:"
kustomize version || true

# ----------------------------------------------------------
# Install policytools
# ----------------------------------------------------------
echo "[2/3] Installing policytools..."

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
echo "[3/3] Installing PolicyGenerator..."

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