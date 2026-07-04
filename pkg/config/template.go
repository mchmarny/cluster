package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const eksTemplate = `# yaml-language-server: $schema=https://raw.githubusercontent.com/mchmarny/cluster/main/schema/eks-config.schema.json
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: my-cluster
  provider: eks                 # eks | gke
  # tenancy: "123456789012"  # REQUIRED: Your AWS account ID
  location: us-west-2
  state: tenancy              # "tenancy" = S3 in target account | "local" = tfstate in /state
  # destroy: false            # Set to true to destroy the cluster
  # tags:                      # Optional: key-value tags applied to all resources
  #   owner: your-name
  #   env: dev

cluster:
  eks:
    # name: my-cluster          # Optional: defaults to deployment.id
    version: "1.33"
    addOns:
      coreDns: ""
      # vpcCni: ""              # Enables VPC CNI custom networking (secondary CIDR, pod subnets, ENIConfig)
      kubeProxy: ""
      ebsCsi: ""
    # controlPlane:
    #   allowedCidrs:           # Optional: restrict API access (your IP auto-added)
    #     - 0.0.0.0/32
    # adminRoles:               # Optional: IAM roles for cluster admin
    #   - ClusterAdmin

# Network uses defaults: 10.0.0.0/16 VPC CIDR, subnets auto-computed
# Pod CIDR (100.65.0.0/16) and pod subnets only apply when vpcCni add-on is enabled
# network:
#   cidrs:
#     host: 10.0.0.0/16
#     pod: 100.65.0.0/16
#   subnets:
#     public:
#       - cidr: 10.0.1.0/27
#         zone: us-west-2a
#       - cidr: 10.0.2.0/27
#         zone: us-west-2b
#     system:
#       - cidr: 10.0.4.0/22
#         zone: us-west-2a
#       - cidr: 10.0.8.0/22
#         zone: us-west-2b
#     worker:
#       - cidr: 10.0.128.0/17
#         zone: us-west-2a
#     pod:
#       - cidr: 100.65.0.0/16
#         zone: us-west-2a

compute:
  eks:
    # sshPublicKey: "ssh-ed25519 AAAA..."  # Optional: SSH key for node access
    nodeGroups:
      system:
        instanceType: m6i.xlarge
        capacity:
          desired: 3
          min: 3
          max: 6
      workers:
        - name: cpu-worker-1
          instanceType: m6i.xlarge
          capacity:
            desired: 1
          labels:
            nodeGroup: cpu-worker
        # GPU worker example:
        # - name: gpu-worker-1
        #   instanceType: p4d.24xlarge
        #   gpuType: a100
        #   imageId: ami-0b68ba66e5a106899
        #   capacity:
        #     desired: 0
`

const gkeTemplate = `# yaml-language-server: $schema=https://raw.githubusercontent.com/mchmarny/cluster/main/schema/gke-config.schema.json
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: my-cluster
  provider: gke                 # eks | gke
  # tenancy: "my-project"      # REQUIRED: Your GCP project ID
  location: us-west1
  state: tenancy              # "tenancy" = GCS in target project | "local" = tfstate in /state
  # destroy: false            # Set to true to destroy the cluster
  # tags:                      # Optional: key-value tags applied to all resources
  #   owner: your-name
  #   env: dev

cluster:
  gke:
    # name: my-cluster          # Optional: defaults to deployment.id
    version: "1.33"
    releaseChannel: STABLE
    # controlPlane:
    #   authorizedNetworks:     # Optional: restrict API access
    #     - cidr: 0.0.0.0/32
    #       name: my-network
    # maintenance:
    #   window:
    #     startTime: "03:00"

# Network uses defaults: 10.0.0.0/16 VPC, auto-computed subnets and secondary ranges
# Uncomment to customize:
# network:
#   gke:
#     cidr: 10.0.0.0/16
#     subnets:
#       nodes:
#         - name: system-subnet
#           cidr: 10.0.0.0/22
#         - name: worker-subnet
#           cidr: 10.0.128.0/17

compute:
  gke:
    nodePools:
      system:
        machineType: e2-standard-4
        autoscaling:
          enabled: true
          minNodes: 1
          maxNodes: 3

      workers:
        - name: cpu-worker-1
          machineType: n2-standard-8
          diskType: pd-ssd
          diskSizeGb: 200
          autoscaling:
            enabled: true
            minNodes: 1
            maxNodes: 5
          nodeConfig:
            labels:
              nodeGroup: cpu-worker
        # GPU worker example:
        # - name: gpu-worker
        #   machineType: a3-megagpu-8g
        #   diskType: pd-ssd
        #   zones:
        #     - us-west1-a
        #   autoscaling:
        #     enabled: true
        #     minNodes: 0
        #     maxNodes: 3
        #   guestAccelerator:
        #     type: nvidia-h100-mega-80gb
        #     count: 8
        #     gpuDriverInstallation:
        #       gpuDriverVersion: DEFAULT
        #   nodeConfig:
        #     gvnic: true
        #     # capacityReservations:
        #     #   - projects/my-project/reservations/my-reservation
        #     taints:
        #       - key: dedicated
        #         value: gpu-workload
        #         effect: NO_SCHEDULE
        #     labels:
        #       nodeGroup: gpu-worker
`

const aksTemplate = `# yaml-language-server: $schema=https://raw.githubusercontent.com/mchmarny/cluster/main/schema/aks-config.schema.json
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: my-cluster
  provider: aks                 # eks | gke | aks | oke
  # tenancy: "00000000-0000-0000-0000-000000000000"  # REQUIRED: Your Azure subscription ID
  location: eastus
  state: tenancy              # "tenancy" = Azure Blob in target subscription | "local" = tfstate in /state
  # destroy: false            # Set to true to destroy the cluster
  # tags:                      # Optional: key-value tags applied to all resources
  #   owner: your-name
  #   env: dev

cluster:
  aks:
    # name: my-cluster          # Optional: defaults to deployment.id
    version: "1.33"
    # resourceGroup: my-cluster-rg  # Optional: defaults to <id>-rg
    # controlPlane:
    #   authorizedNetworks:     # Optional: restrict API access (your IP auto-added)
    #     - cidr: 0.0.0.0/32
    #       name: my-network
    # adminGroups:              # Optional: AAD group object IDs for cluster admin
    #   - 00000000-0000-0000-0000-000000000000

# Network uses defaults: 10.0.0.0/16 VNet, auto-computed subnets
# network:
#   aks:
#     cidr: 10.0.0.0/16
#     serviceCidr: 172.20.0.0/16
#     dnsServiceIp: 172.20.0.10
#     subnets:
#       system:
#         cidr: 10.0.0.0/22
#       worker:
#         cidr: 10.0.128.0/17

compute:
  aks:
    nodePools:
      system:
        vmSize: Standard_D4s_v5
        autoscaling:
          enabled: true
          minNodes: 1
          maxNodes: 3
      workers:
        - name: cpu-worker-1
          vmSize: Standard_D8s_v5
          osDiskType: Managed
          osDiskSizeGb: 200
          autoscaling:
            enabled: true
            minNodes: 1
            maxNodes: 5
          labels:
            nodeGroup: cpu-worker
        # GPU worker example:
        # - name: gpu-worker-1
        #   vmSize: Standard_NC24ads_A100_v4
        #   gpuType: a100
        #   autoscaling:
        #     enabled: true
        #     minNodes: 0
        #     maxNodes: 3
        #   taints:
        #     - key: dedicated
        #       value: gpu-workload
        #       effect: NoSchedule
        #   labels:
        #     nodeGroup: gpu-worker
`

const okeTemplate = `# yaml-language-server: $schema=https://raw.githubusercontent.com/mchmarny/cluster/main/schema/oke-config.schema.json
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: my-cluster
  provider: oke                 # eks | gke | aks | oke
  # tenancy: "ocid1.tenancy.oc1..aaaa"  # REQUIRED: Your OCI tenancy OCID
  location: us-ashburn-1
  state: tenancy              # "tenancy" = OCI Object Storage in target tenancy | "local" = tfstate in /state
  # destroy: false            # Set to true to destroy the cluster
  # tags:                      # Optional: key-value freeform tags applied to all resources
  #   owner: your-name
  #   env: dev

cluster:
  oke:
    # name: my-cluster          # Optional: defaults to deployment.id
    version: "v1.33.1"
    # compartmentId: ocid1.compartment.oc1..aaaa  # Optional: defaults to tenancy (root)
    # controlPlane:
    #   isPublicIpEnabled: false
    #   allowedCidrs:           # Optional: restrict API access (your IP auto-added)
    #     - 0.0.0.0/32

# Network uses defaults: 10.0.0.0/16 VCN, auto-computed subnets
# network:
#   oke:
#     cidr: 10.0.0.0/16
#     podsCidr: 10.244.0.0/16
#     servicesCidr: 10.96.0.0/16
#     subnets:
#       system:
#         cidr: 10.0.0.0/22
#       worker:
#         cidr: 10.0.128.0/17

compute:
  oke:
    nodePools:
      system:
        shape: VM.Standard.E4.Flex
        ocpus: 4
        memoryGb: 32
        size: 3
      workers:
        - name: cpu-worker-1
          shape: VM.Standard.E4.Flex
          ocpus: 8
          memoryGb: 64
          bootVolumeSizeGb: 200
          size: 1
          labels:
            nodeGroup: cpu-worker
        # GPU worker example:
        # - name: gpu-worker-1
        #   shape: VM.GPU.A10.1
        #   gpuType: a10
        #   size: 0
        #   labels:
        #     nodeGroup: gpu-worker
`

// GenerateTemplate writes a starter config file to the given path.
// Fails if the file already exists. Detects provider from filename prefix
// (gke-* → GKE, aks-* → AKS, oke-* → OKE, otherwise EKS).
func GenerateTemplate(path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("file already exists: %s (delete it first or choose a different path)", path)
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	tmpl := eksTemplate
	switch base := filepath.Base(path); {
	case strings.HasPrefix(base, "gke"):
		tmpl = gkeTemplate
	case strings.HasPrefix(base, "aks"):
		tmpl = aksTemplate
	case strings.HasPrefix(base, "oke"):
		tmpl = okeTemplate
	}

	if err := os.WriteFile(path, []byte(tmpl), 0600); err != nil {
		return fmt.Errorf("writing template: %w", err)
	}

	return nil
}
