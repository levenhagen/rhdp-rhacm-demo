# RHACM Regional-DR Lab Guide - OpenShift 4.21

**Updated for OpenShift Container Platform 4.21 and OpenShift Data Foundation 4.21**

---

## Overview

This guide provides step-by-step instructions to configure and demonstrate Regional Disaster Recovery (Regional-DR) on Red Hat Advanced Cluster Management (RHACM) using OpenShift Data Foundation.

### Prerequisites

- RHACM Hub cluster deployed
- Two managed OpenShift clusters (cluster1 and cluster2) running on AWS
  - Each cluster: 3 control plane nodes + 3 worker nodes
  - OpenShift version: 4.21
- AWS credentials configured
- `oc` CLI tool installed and configured

---

## Architecture

Regional-DR enables business continuity during the unavailability of a geographical region, accepting some loss of data in a predictable amount. In the public cloud this would be similar to protecting from a region failure.

**Components:**
- **Hub cluster**: Red Hat Advanced Cluster Management (RHACM) hub
- **Primary managed cluster (cluster1)**: OpenShift Data Foundation running
- **Secondary managed cluster (cluster2)**: OpenShift Data Foundation running
- **Submariner**: Provides cluster networking for Regional-DR
- **OpenShift GitOps**: Automates ODF deployment and policy management
- **ODF MultiCluster Orchestrator**: Manages disaster recovery policies

---

## Manual Setup Steps (Steps 1-3)

### Step 1: Setting up and configuring AWS credentials for cluster provisioning

1. Navigate to **Credentials** in the RHACM console
2. Click **Add credential**
3. Select **Amazon Web Services** as the credential type
4. Name it **aws**
5. Use the **Base DNS domain** provided by RHDP
6. Enter your AWS credentials (Access Key ID and Secret Access Key)
7. Click **Add**

### Step 2: Creating a ClusterSet

1. Navigate to **Infrastructure** → **Clusters** → **Cluster sets**
2. Click **Create cluster set**
3. Name it **regional**
4. Click **Create**

### Step 3: Deploying Managed Clusters

Deploy two managed clusters using the RHACM console:

**Cluster 1 (Primary):**
- Name: **cluster1**
- Cloud provider: **AWS**
- Release image: **OpenShift 4.21**
- ClusterSet: **regional**
- Region: **us-east-1** (or your preferred region)
- Node pools:
  - Control plane: 3 nodes (m5.4xlarge - 16 vCPU, 64 GB RAM)
  - Worker pool: 3 nodes (m5.4xlarge - 16 vCPU, 64 GB RAM)

**Cluster 2 (Secondary):**
- Name: **cluster2**
- Cloud provider: **AWS**
- Release image: **OpenShift 4.21**
- ClusterSet: **regional**
- Region: **us-west-2** (different region from cluster1)
- Node pools:
  - Control plane: 3 nodes (m5.4xlarge - 16 vCPU, 64 GB RAM)
  - Worker pool: 3 nodes (m5.4xlarge - 16 vCPU, 64 GB RAM)

Wait approximately 50 minutes for both clusters to deploy successfully.

---

## Automated Setup (Steps 4-13)

The following steps are automated using the provided bash script. Run the automation script:

```bash
./automate-regional-dr.sh
```

### What the automation does:

**Step 4: Deploy Submariner**
- Installs multicluster networking add-ons on the regional ClusterSet
- Enables GlobalNet on both clusters
- Waits for Submariner deployment to complete

**Step 5: Install OpenShift GitOps Operator**
- Deploys the Red Hat OpenShift GitOps operator on the hub cluster

**Step 6: Integrate OpenShift GitOps and RHACM**
- Creates GitOpsCluster resource
- Creates placement resources for global and regional clustersets

**Step 7: Configure ClusterSet Bindings**
- Creates namespace/project called "policies"
- Binds regional clusterset to default, openshift-gitops, and policies namespaces

**Step 8: Adjust ArgoCD Cluster-Admin Permissions**
- Creates ClusterRole for GitOps policy admin
- Creates Group for cluster-admins
- Creates ClusterRoleBindings for ArgoCD controllers

**Step 9: Integrate Policy Generator with OpenShift GitOps**
- Deploys ArgoCD application for ODF policy generation
- Configures policy generator plugin

**Step 10: Prepare Nodes for ODF Deployment**
- Labels all 6 worker nodes (3 per cluster) with `cluster.ocs.openshift.io/openshift-storage: ""`

**Step 11: Deploy ODF Policies with GitOps**
- Creates ApplicationSet for ODF policy deployment
- Deploys policies to both managed clusters

**Step 12: Patch StorageCluster CR**
- If GlobalNet is enabled, patches StorageCluster on both clusters
- Enables multiClusterService with clusterID

**Step 13: Install ODF MultiCluster Orchestrator**
- Installs ODF Multicluster Orchestrator operator on hub cluster
- Installs OpenShift DR Hub Operator dependency

---

## Manual Post-Automation Steps

### Step 14: Configure SSL Access Across Clusters

SSL connection must be configured manually between all three clusters (hub, cluster1, cluster2).

**Prerequisites:**
- If all clusters use signed and valid certificates, this step can be skipped

**Procedure:**

1. **Extract certificates from cluster1:**
   ```bash
   oc get cm default-ingress-cert -n openshift-config-managed \
     -o jsonpath="{['data']['ca-bundle\.crt']}" > cluster1.crt
   ```

2. **Extract certificates from cluster2:**
   ```bash
   oc get cm default-ingress-cert -n openshift-config-managed \
     -o jsonpath="{['data']['ca-bundle\.crt']}" > cluster2.crt
   ```

3. **Create ConfigMap with certificate bundle:**

   Create file `cm-clusters-crt.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: user-ca-bundle
     namespace: openshift-config
   data:
     ca-bundle.crt: |
       -----BEGIN CERTIFICATE-----
       <copy contents of cert1 from cluster1.crt here>
       -----END CERTIFICATE-----
       
       -----BEGIN CERTIFICATE-----
       <copy contents of cert2 from cluster1.crt here>
       -----END CERTIFICATE-----
       
       -----BEGIN CERTIFICATE-----
       <copy contents of cert3 from cluster1.crt here>
       -----END CERTIFICATE-----
       
       -----BEGIN CERTIFICATE-----
       <copy contents of cert1 from cluster2.crt here>
       -----END CERTIFICATE-----
       
       -----BEGIN CERTIFICATE-----
       <copy contents of cert2 from cluster2.crt here>
       -----END CERTIFICATE-----
       
       -----BEGIN CERTIFICATE-----
       <copy contents of cert3 from cluster2.crt here>
       -----END CERTIFICATE-----
   ```

4. **Apply ConfigMap to all three clusters:**
   ```bash
   # Apply to cluster1
   oc --context=cluster1 create -f cm-clusters-crt.yaml
   
   # Apply to cluster2
   oc --context=cluster2 create -f cm-clusters-crt.yaml
   
   # Apply to hub
   oc --context=hub create -f cm-clusters-crt.yaml
   ```

5. **Patch proxy on all three clusters:**
   ```bash
   # Patch cluster1
   oc --context=cluster1 patch proxy cluster --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
   
   # Patch cluster2
   oc --context=cluster2 patch proxy cluster --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
   
   # Patch hub
   oc --context=hub patch proxy cluster --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
   ```

6. **Verify certificates:**

   Search in RHACM for `kind:ConfigMap name:user-ca-bundle` (should see 3 results)
   
   Search in RHACM for `kind:proxy` (should see 3 results with trusted CA bundle added)

7. **Verify ServiceExport:**

   After SSL configuration, verify that 12 ServiceExport resources exist (6 MONs and 6 OSDs):
   ```bash
   oc --context=hub get serviceexport -n openshift-storage
   ```

   Wait a few minutes for all resources to show up.

---

### Step 15: Create Disaster Recovery Policy

1. Navigate to **All Clusters** → **Data Services** → **Disaster recovery** in RHACM console
2. Click **Create DRPolicy**
3. Configure the policy:
   - **Policy name**: `ocp4bos1-ocp4bos2-5m` (or your desired name)
   - **Managed clusters**: Select **cluster1** and **cluster2**
   - **Replication policy**: Automatically set to **Asynchronous**
   - **Sync schedule**: Set to **5m** (5 minutes) for demo purposes
   - **Advanced settings**: 
     - ☑ Check **Enable disaster recovery support for restored and cloned PersistentVolumeClaims**
4. Click **Create**
5. Verify the DRPolicy is created:
   ```bash
   oc get drpolicy <drpolicy_name> -o jsonpath='{.status.conditions[].reason}{"\n"}'
   ```
   Output should be: `Succeeded`

6. Verify DRClusters on hub:
   ```bash
   oc get drclusters
   ```

7. Check S3 access from hub to both managed clusters:
   ```bash
   oc get drcluster <drcluster_name> -o jsonpath='{.status.conditions[2].reason}{"\n"}'
   ```
   Output should be: `Succeeded`

8. Verify StorageClusterPeer is Peered:
   ```bash
   oc --context=cluster1 get storageclusterpeer <managedcluser_name>-peer \
     -n openshift-storage -oyaml | yq '.status.state'
   ```
   Output should be: `Peered`

9. Verify ODF mirroring daemon health:
   ```bash
   oc --context=cluster1 get cephblockpoolradosnamespaces \
     ocs-storagecluster-cephblockpool-builtin-implicit -n openshift-storage \
     -o jsonpath='{.status.mirroringStatus.summary}{"\n"}'
   ```
   Expected output:
   ```json
   {"daemon_health":"OK","group_health":"OK","group_states":{},"health":"OK","image_health":"OK","image_states":{},"states":{}}
   ```

   ⚠️ **CAUTION**: It could take up to 10 minutes for daemon_health and health to go from Warning to OK. Monitor the RHACM console to verify Submariner connection is healthy before proceeding.

---

### Step 16: Deploy Sample Application and Enroll in DRPolicy

Deploy a sample application (RocketChat) to test the DR solution:

**On both cluster1 and cluster2:**

1. **Create RocketChat namespace:**
   ```bash
   oc --context=cluster1 new-project rocketchat
   oc --context=cluster2 new-project rocketchat
   ```

2. **Add anyuid SCC (demo purposes only - NOT for production):**
   ```bash
   oc --context=cluster1 adm policy add-scc-to-user anyuid -z default -n rocketchat
   oc --context=cluster2 adm policy add-scc-to-user anyuid -z default -n rocketchat
   ```

3. **Deploy RocketChat application in RHACM:**
   - Navigate to **Applications** → **Create application** → **Application set**
   - **General:**
     - Name: `rocket-chat`
     - Argo server: `openshift-gitops`
   - **Template:**
     - **Repository:**
       - RepoURL: `https://github.com/levenhagen/rocketchat-acm`
       - Revision: `dev`
       - Path: `rocketchat`
       - Remote namespace: `rocketchat`
   - **Sync policy:** Leave defaults
   - **Placement:**
     - ClusterSet: `regional`
     - Limit clusters: `1`
   - Click **Next** and **Submit**

4. **Enroll application in DRPolicy:**
   - Go to **Applications** → **rocket-chat** → **Topology**
   - Click **Manage disaster recovery** (top right Actions menu)
   - Select **Policy** and **PVC labels**
   - Click **Next**

5. **Access RocketChat and add data:**
   - Get the route and access RocketChat
   - Configure admin account and create some messages
   - This data will be used to verify failover

---

## Testing Disaster Recovery

### Application Failover

1. **Initiate failover:**
   - Navigate to **Applications** → **Advanced applications**
   - Find `rocket-chat`
   - Click **Actions** → **Failover application**
   - Select target cluster (cluster2 if currently on cluster1)
   - Confirm failover

2. **Monitor failover:**
   - Wait for error/warning messages to disappear
   - Status should show **Preparing** → **Syncing** → **Restoring** → **Clean up**

3. **Verify application:**
   - Once complete, the application should be running on the target cluster
   - Access RocketChat route on the new cluster
   - Verify your data persisted (messages should still be there)

### Application Relocate

1. **Initiate relocate:**
   - Navigate to **Applications** → **Advanced applications**
   - Find `rocket-chat`
   - Click **Actions** → **Relocate application**
   - Select original cluster
   - Confirm relocate

2. **Verify:**
   - Application should move back to the original cluster
   - Data should remain intact

---

## Verification Commands

### Check DR Status

```bash
# Get DRPolicy status
oc get drpolicy

# Get DRCluster status
oc get drclusters

# Check ODF mirroring
oc --context=cluster1 get cephblockpoolradosnamespaces \
  ocs-storagecluster-cephblockpool-builtin-implicit -n openshift-storage \
  -o jsonpath='{.status.mirroringStatus.summary}'

# Check StorageClusterPeer
oc --context=cluster1 get storageclusterpeer -n openshift-storage

# Verify Submariner
oc --context=hub get submariner -A
```

### Check Application Status

```bash
# List DR-protected applications
oc get drplacementcontrol -A

# Check application placement
oc get placement -n rocketchat

# View application sync status
oc get applications -n openshift-gitops
```

---

## Troubleshooting

### Common Issues

**Issue**: Submariner pods not ready
- **Solution**: Check GlobalNet is enabled, verify network CIDR ranges don't overlap

**Issue**: ODF mirroring shows Warning
- **Solution**: Wait up to 10 minutes, verify Submariner is healthy

**Issue**: DRPolicy validation fails
- **Solution**: Verify SSL certificates are configured on all clusters

**Issue**: Application failover stuck
- **Solution**: Check VolSync operator logs, verify PVC replication is working

---

## Important Notes

⚠️ **Security Warning**: The `anyuid` SCC assignment in Step 16 is for demo/lab purposes ONLY. Do NOT use this in production environments.

⚠️ **Version Compatibility**: This guide is tested on OpenShift 4.21 and OpenShift Data Foundation 4.21.

⚠️ **Regional-DR Limitations**: 
- Regional-DR accepts some data loss (asynchronous replication)
- For zero data loss, use Metro-DR instead
- Currently supported on VMware, bare metal, and hybrid cloud environments

---

## Additional Resources

- [OpenShift Data Foundation 4.21 Documentation](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation/4.21)
- [RHACM Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)
- [Submariner Documentation](https://submariner.io/)
- [OpenShift GitOps Documentation](https://docs.openshift.com/gitops/)

---

**Document Version**: 2.0  
**Last Updated**: 2026-04-21  
**OpenShift Version**: 4.21  
**ODF Version**: 4.21
