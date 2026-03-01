package config

import (
	"fmt"
	"os"
	"path/filepath"
)

const configTemplate = `# yaml-language-server: $schema=https://raw.githubusercontent.com/mchmarny/cluster/main/schema/cluster-config.schema.json
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

// GenerateTemplate writes a starter config file to the given path.
// Fails if the file already exists.
func GenerateTemplate(path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("file already exists: %s (delete it first or choose a different path)", path)
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	if err := os.WriteFile(path, []byte(configTemplate), 0600); err != nil {
		return fmt.Errorf("writing template: %w", err)
	}

	return nil
}
