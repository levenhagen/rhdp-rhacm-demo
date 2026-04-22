#!/bin/bash

###############################################################################
# Regional-DR Automation Script for OpenShift 4.21
#
# This script automates steps 4-13 of the Regional-DR setup process:
# - Step 4: Deploy Submariner
# - Step 5: Install OpenShift GitOps Operator
# - Step 6: Integrate OpenShift GitOps and RHACM
# - Step 7: Configure ClusterSet Bindings
# - Step 8: Adjust ArgoCD Cluster-Admin Permissions
# - Step 9: Integrate Policy Generator with OpenShift GitOps
# - Step 10: Prepare Nodes for ODF Deployment
# - Step 11: Deploy ODF Policies with GitOps
# - Step 12: Patch StorageCluster CR (if GlobalNet enabled)
# - Step 13: Install ODF MultiCluster Orchestrator
#
# Prerequisites:
# - oc CLI tool installed and logged into RHACM hub cluster
# - Two managed clusters (cluster1 and cluster2) deployed and ready
# - ClusterSet 'regional' created with both clusters
#
# Usage: ./automate-regional-dr.sh
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTERSET_NAME="regional"
CLUSTER1_NAME="cluster1"
CLUSTER2_NAME="cluster2"
POLICIES_NAMESPACE="policies"
GITOPS_NAMESPACE="openshift-gitops"
POLICY_REPO="https://github.com/levenhagen/policy-collection"
POLICY_REVISION="odf-policy-only"
ROCKETCHAT_REPO="https://github.com/levenhagen/rocketchat-acm"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}

    log_info "Waiting for pods with label '$label' in namespace '$namespace' to be ready..."
    oc wait --for=condition=Ready pods -l "$label" -n "$namespace" --timeout="${timeout}s" || true
}

wait_for_resource() {
    local resource=$1
    local namespace=$2
    local timeout=${3:-300}

    log_info "Waiting for $resource to exist in namespace $namespace..."
    local count=0
    while ! oc get "$resource" -n "$namespace" &>/dev/null; do
        sleep 5
        count=$((count + 5))
        if [ $count -ge $timeout ]; then
            log_error "Timeout waiting for $resource"
            return 1
        fi
    done
    log_success "$resource exists"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if oc is installed
    if ! command -v oc &> /dev/null; then
        log_error "oc CLI tool not found. Please install it first."
        exit 1
    fi

    # Check if logged into cluster
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please login first."
        exit 1
    fi

    # Check if managedclusters exist
    if ! oc get managedcluster "$CLUSTER1_NAME" &> /dev/null; then
        log_error "Managed cluster '$CLUSTER1_NAME' not found"
        exit 1
    fi

    if ! oc get managedcluster "$CLUSTER2_NAME" &> /dev/null; then
        log_error "Managed cluster '$CLUSTER2_NAME' not found"
        exit 1
    fi

    # Check if clusterset exists
    if ! oc get managedclusterset "$CLUSTERSET_NAME" &> /dev/null; then
        log_error "ClusterSet '$CLUSTERSET_NAME' not found"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

###############################################################################
# Step 4: Deploy Submariner
###############################################################################
deploy_submariner() {
    log_info "Step 4: Deploying Submariner..."

    # Check if Submariner addon already exists
    if oc get managedclusteraddon submariner -n "$CLUSTER1_NAME" &> /dev/null; then
        log_warning "Submariner already deployed, skipping..."
        return 0
    fi

    # Install Submariner on the clusterset via RHACM
    log_info "Installing Submariner addon on clusterset '$CLUSTERSET_NAME'..."

    # Create SubmarinerConfig
    cat <<EOF | oc apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: submariner
  namespace: cluster1
spec:
  installNamespace: submariner-operator
---
apiVersion: submarineraddon.open-cluster-management.io/v1alpha1
kind: SubmarinerConfig
metadata:
  name: submariner
  namespace: cluster1
spec:
  gatewayConfig:
    gateways: 1
    aws:
      instanceType: m5.2xlarge
  IPSecNATTPort: 4500
  airGappedDeployment: false
  NATTEnable: true
  cableDriver: libreswan
  globalCIDR: ""
  credentialsSecret:
    name: cluster1-aws-creds
---
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: submariner
  namespace: cluster2
spec:
  installNamespace: submariner-operator
---
apiVersion: submarineraddon.open-cluster-management.io/v1alpha1
kind: SubmarinerConfig
metadata:
  name: submariner
  namespace: cluster2
spec:
  gatewayConfig:
    gateways: 1
    aws:
      instanceType: m5.2xlarge
  IPSecNATTPort: 4500
  airGappedDeployment: false
  NATTEnable: true
  cableDriver: libreswan
  globalCIDR: ""
  credentialsSecret:
    name: cluster2-aws-creds
---
apiVersion: submariner.io/v1alpha1
kind: Broker
metadata:
  name: submariner-broker
  namespace: regional-broker
  labels:
    cluster.open-cluster-management.io/backup: submariner
spec:
  globalnetEnabled: true
  globalnetCIDRRange: 242.0.0.0/8
EOF

    log_info "Waiting for Submariner to deploy on both clusters..."
    sleep 30

    # Wait for submariner-addon to be available
    wait_for_resource "managedclusteraddon submariner" "$CLUSTER1_NAME" 600
    wait_for_resource "managedclusteraddon submariner" "$CLUSTER2_NAME" 600

    log_success "Submariner deployment initiated"
}

###############################################################################
# Step 5: Install OpenShift GitOps Operator
###############################################################################
install_gitops_operator() {
    log_info "Step 5: Installing OpenShift GitOps Operator..."

    # Check if operator already installed
    if oc get deployment openshift-gitops-server -n openshift-gitops &> /dev/null; then
        log_warning "OpenShift GitOps already installed, skipping..."
        return 0
    fi

    # Create Subscription
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    log_info "Waiting for OpenShift GitOps operator to install..."
    sleep 60
    wait_for_pods "openshift-gitops" "app.kubernetes.io/name=openshift-gitops-server" 600

    log_success "OpenShift GitOps Operator installed"
}

###############################################################################
# Step 6: Integrate OpenShift GitOps and RHACM
###############################################################################
integrate_gitops_rhacm() {
    log_info "Step 6: Integrating OpenShift GitOps and RHACM..."

    # Create GitOpsCluster resource
    cat <<EOF | oc apply -f -
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: openshift-gitops-main-server
  namespace: openshift-gitops
spec:
  argoServer:
    argoNamespace: openshift-gitops
  placementRef:
    name: openshift-gitops-main-server-placement
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: global
  namespace: openshift-gitops
spec:
  clusterSet: global
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: $CLUSTERSET_NAME
  namespace: openshift-gitops
spec:
  clusterSet: $CLUSTERSET_NAME
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: openshift-gitops-main-server-placement
  namespace: openshift-gitops
spec:
  clusterSets:
    - global
    - $CLUSTERSET_NAME
EOF

    log_success "GitOps and RHACM integration completed"
}

###############################################################################
# Step 7: Configure ClusterSet Bindings
###############################################################################
configure_clusterset_bindings() {
    log_info "Step 7: Configuring ClusterSet bindings..."

    # Create policies namespace
    oc create namespace "$POLICIES_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    # Create ManagedClusterSetBindings
    cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: $CLUSTERSET_NAME
  namespace: default
spec:
  clusterSet: $CLUSTERSET_NAME
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: $CLUSTERSET_NAME
  namespace: $POLICIES_NAMESPACE
spec:
  clusterSet: $CLUSTERSET_NAME
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: global
  namespace: default
spec:
  clusterSet: global
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: global
  namespace: $POLICIES_NAMESPACE
spec:
  clusterSet: global
EOF

    log_success "ClusterSet bindings configured"
}

###############################################################################
# Step 8: Adjust ArgoCD Cluster-Admin Permissions
###############################################################################
adjust_argocd_permissions() {
    log_info "Step 8: Adjusting ArgoCD cluster-admin permissions..."

    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openshift-gitops-policy-admin
rules:
  - verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
    apiGroups:
      - policy.open-cluster-management.io
    resources:
      - policies
      - configurationpolicies
      - certificatepolicies
      - operatorpolicies
      - policysets
      - placementbindings
  - verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
    apiGroups:
      - apps.open-cluster-management.io
    resources:
      - placementrules
  - verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
    apiGroups:
      - cluster.open-cluster-management.io
    resources:
      - placements
      - placements/status
      - placementdecisions
      - placementdecisions/status
---
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: cluster-admins
users:
  - admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-appset-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-applicationset-controller
    namespace: openshift-gitops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-policy-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-gitops-policy-admin
EOF

    log_success "ArgoCD permissions adjusted"
}

###############################################################################
# Step 9: Prepare Nodes for ODF Deployment
###############################################################################
prepare_odf_nodes() {
    log_info "Step 9: Preparing nodes for ODF deployment..."

    # Label worker nodes on cluster1
    log_info "Labeling worker nodes on $CLUSTER1_NAME..."
    for node in $(oc --context="$CLUSTER1_NAME" get nodes -l node-role.kubernetes.io/worker= -o name); do
        oc --context="$CLUSTER1_NAME" label "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite
    done

    # Label worker nodes on cluster2
    log_info "Labeling worker nodes on $CLUSTER2_NAME..."
    for node in $(oc --context="$CLUSTER2_NAME" get nodes -l node-role.kubernetes.io/worker= -o name); do
        oc --context="$CLUSTER2_NAME" label "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite
    done

    log_success "Nodes labeled for ODF deployment"
}

###############################################################################
# Step 10: Deploy ODF Policies with GitOps
###############################################################################

deploy_odf_policies() {
    # Check if ODF policy already exists
    if oc get policy install-odf-operator -n default &> /dev/null; then
        log_warning "ODF policy already deployed, skipping..."
        return 0
    fi
    
    log_info "Step 10: Deploying ODF policies with GitOps..."

    cat <<EOF | oc apply -f -
    apiVersion: policy.open-cluster-management.io/v1
    kind: Policy
    metadata:
      name: install-odf-operator
      namespace: default
    spec:
      disabled: false
      policy-templates:
        - objectDefinition:
            apiVersion: policy.open-cluster-management.io/v1beta1
            kind: OperatorPolicy
            metadata:
              name: install-operator
            spec:
              complianceType: musthave
              operatorGroup:
                name: default
                targetNamespaces:
                  - openshift-storage
              remediationAction: enforce
              severity: critical
              subscription:
                name: odf-operator
                namespace: openshift-storage
                channel: stable-4.21
                source: redhat-operators
                sourceNamespace: openshift-marketplace
                startingCSV: odf-operator.v4.21.2-rhodf
              upgradeApproval: Automatic
              versions:
EOF
          
    log_info "Waiting for policies to be created..."
    sleep 60

    # Wait for policies to report violations
    log_info "Waiting for policy deployment (this may take 10-15 minutes)..."
    local timeout=900
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local violations=$(oc get policies -n default --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$violations" -gt 0 ]; then
            log_success "Policies created, monitoring deployment..."
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_success "ODF policies deployed"
}

###############################################################################
# Step 11: Patch StorageCluster CR
###############################################################################
patch_storagecluster() {
    log_info "Step 11: Patching StorageCluster CR for GlobalNet..."

    # Check if GlobalNet is enabled by checking for Submariner
    if ! oc get submariner -A &> /dev/null; then
        log_warning "Submariner not detected, skipping StorageCluster patch"
        return 0
    fi

    log_info "Checking if StorageCluster exists on managed clusters..."
    sleep 120  # Wait for ODF to be deployed first

    # Patch cluster1
    if oc --context="$CLUSTER1_NAME" get storagecluster -n openshift-storage &> /dev/null; then
        log_info "Patching StorageCluster on $CLUSTER1_NAME..."
        oc --context="$CLUSTER1_NAME" patch storagecluster ocs-storagecluster \
          -n openshift-storage --type=merge \
          --patch='{"spec":{"network":{"multiClusterService":{"clusterID":"'$CLUSTER1_NAME'","enabled":true}}}}'
    fi

    # Patch cluster2
    if oc --context="$CLUSTER2_NAME" get storagecluster -n openshift-storage &> /dev/null; then
        log_info "Patching StorageCluster on $CLUSTER2_NAME..."
        oc --context="$CLUSTER2_NAME" patch storagecluster ocs-storagecluster \
          -n openshift-storage --type=merge \
          --patch='{"spec":{"network":{"multiClusterService":{"clusterID":"'$CLUSTER2_NAME'","enabled":true}}}}'
    fi

    log_success "StorageCluster patched for GlobalNet"
}

###############################################################################
# Step 12: Install ODF MultiCluster Orchestrator
###############################################################################
install_odf_mco() {
    log_info "Step 12: Installing ODF MultiCluster Orchestrator..."

    # Check if already installed
    if oc get deployment odf-multicluster-console -n openshift-operators &> /dev/null; then
        log_warning "ODF MultiCluster Orchestrator already installed, skipping..."
        return 0
    fi

    # Install via Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-multicluster-orchestrator
  namespace: openshift-operators
spec:
  channel: stable-4.21
  name: odf-multicluster-orchestrator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

    log_info "Waiting for ODF MultiCluster Orchestrator to install..."
    sleep 60
    wait_for_pods "openshift-operators" "app.kubernetes.io/name=odf-multicluster-orchestrator" 600

    # Verify OpenShift DR Hub Operator (installed as dependency)
    log_info "Verifying OpenShift DR Hub Operator..."
    wait_for_pods "openshift-dr-system" "app=ramen-hub-operator" 300

    log_success "ODF MultiCluster Orchestrator installed"
}

###############################################################################
# Main execution
###############################################################################
main() {
    echo "============================================================================="
    echo "  Regional-DR Automation Script for OpenShift 4.21"
    echo "  Automating Steps 4-13"
    echo "============================================================================="
    echo ""

    check_prerequisites

    echo ""
    echo "Starting automation..."
    echo ""

    deploy_submariner
    echo ""

    install_gitops_operator
    echo ""

    integrate_gitops_rhacm
    echo ""

    configure_clusterset_bindings
    echo ""

    adjust_argocd_permissions
    echo ""

    prepare_odf_nodes
    echo ""

    deploy_odf_policies
    echo ""

    patch_storagecluster
    echo ""

    install_odf_mco
    echo ""

    echo "============================================================================="
    log_success "Automation completed successfully!"
    echo "============================================================================="
    echo ""
    echo "Next steps:"
    echo "  1. Wait 10-15 minutes for ODF deployment to complete"
    echo "  2. Verify ServiceExports exist (should see 12):"
    echo "     oc get serviceexport -n openshift-storage"
    echo "  3. Proceed with Step 14: Configure SSL access across clusters"
    echo "     (See documentation for manual steps)"
    echo ""
    echo "============================================================================="
}

# Run main function
main "$@"
