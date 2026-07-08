# Azure AKS Cluster Builder

Deploys a production-ready AKS cluster from a single YAML config:

- Private cluster with Entra ID (Azure AD) RBAC integration
- OIDC issuer + Workload Identity for secret-free pod authentication
- Azure CNI networking with dedicated system and worker subnets
- NSGs + NAT gateway for controlled private-node egress
- Optional Key Vault KMS encryption for etcd secrets
- System node pool (CriticalAddonsOnly taint) separated from worker pools

> **Status:** live-validated 2026-07-07 (westus, K8s 1.35): full lifecycle
> (setup → plan → apply → validate → in-place update → destroy) including a
> 2-node `Standard_ND96isr_H100_v5` GPU pool with `nvidia-smi` verified in-pod.
> See "Operational notes" below for findings from that validation.

---

## Deployment

### Prerequisites

- **az CLI** authenticated (`az login` — device-code flow supported)
- **kubelogin** on the host for AAD-integrated `kubectl` access when running
  `validate` or `kubectl` locally (the container image bundles its own copy)
- **yq** >= 4.0 for YAML parsing

**Required Azure permissions:** most resources need only **Contributor** on the
subscription. The two role assignments in `iam.tf` (Network Contributor on the
VNet for the cluster identity, AcrPull for the kubelet) additionally require
`Microsoft.Authorization/roleAssignments/write` (**Owner** or **User Access
Administrator**). With Contributor only, those two resources fail with 403 and
stay tainted in state; the cluster is otherwise functional, but load balancer
provisioning in the BYO VNet and ACR image pulls will not work until an admin
grants the roles (or applies with sufficient rights).

**Cluster access is Entra-only:** local accounts are disabled
(`local_account_disabled = true`), so `az aks get-credentials --admin` does not
work. Set `cluster.aks.adminGroups` to at least one Entra group object ID you
belong to — with an empty list, nobody can reach the Kubernetes API without a
role-assignment write, which Contributor-only deployers cannot perform.

### 1. Generate Config (optional)

The `init` command detects the provider from the filename prefix (`aks-*` generates an AKS template):

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/aks:latest init /config/aks-example.yaml
```

### 2. Setup Tenancy (one-time)

Bootstrap the subscription with a state resource group, Storage Account, and Blob container:

```shell
provider/aks/tools/setup -c config/aks-example.yaml
```

This creates:
- Resource group `cluster-state-rg`
- Storage Account `clst<subscription-hex>` (blob versioning enabled) + `tfstate` container
- `backend.hcl` for the azurerm Terraform backend

### 3. Apply

Authentication uses the Azure CLI login chain (`az login`); no service principal
is required. The image bundles the az CLI but has no credentials of its own —
mount your host's `az login` token cache into the container (it runs as user
`builder`, so the target is `/home/builder/.azure`):

```shell
docker run --rm \
  -v ~/.azure:/home/builder/.azure \
  -e CONFIG_CONTENT="$(base64 < config/aks-example.yaml)" \
  ghcr.io/mchmarny/cluster/aks:latest apply
```

Without the mount, the run fails at `terraform init` with
`Please run 'az login' to setup account`.

On success, `apply` prints the deployment status JSON to stdout. This matters
for `CONFIG_CONTENT` runs: the `<config>-status.json` file is written next to
the decoded config *inside* the container and discarded on exit, so stdout is
the durable copy (pipe it to a file if you want to keep it).

### 4. GPU pools: driver and device plugin

By default the module provisions GPU pools with the Azure-managed NVIDIA
driver install **disabled** (`gpu_driver = "None"`), on the assumption that
GPU software is managed in-cluster — typically the
[NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/),
which installs the driver, device plugin, and toolchain together. To have
Azure install the driver on the node image instead, opt in per pool:

```yaml
compute:
  aks:
    nodePools:
      workers:
        - name: gpuworker1
          gpuType: h100
          gpuDriverInstall: true   # Azure-managed driver (default: false)
```

> Changing `gpuDriverInstall` on an existing pool **replaces the pool** —
> Azure cannot toggle the driver install mode in place.

With `gpuDriverInstall: true`, AKS installs the **driver** but not the
**device plugin** — without it GPU nodes advertise zero `nvidia.com/gpu`
resources and no GPU workload can schedule. After the first apply that includes
a `gpuType` pool, deploy the plugin once (the upstream manifest tolerates the
`nvidia.com/gpu=present:NoSchedule` taint this module sets):

```shell
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
```

For a private cluster without VNet access, run it via the Azure tunnel:

```shell
az aks command invoke -g <deployment-id>-rg -n <deployment-id> \
  --command "kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml"
```

Verify with `kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'`.

### 5. Validate (optional)

```shell
provider/aks/tools/validate -c config/aks-example.yaml
```

The two node-level checks use `kubectl` and fail from outside the VNet on a
private cluster; use `az aks command invoke` for node spot-checks instead.

### 6. Destroy

Set `deployment.destroy: true` in the config and re-run `apply`.

---

## Running Terraform locally (without the container)

The container image's entrypoint is the `cluster` Go binary; `tools/actuate` is
a shell-based equivalent for driving the same Terraform from a local checkout.
It defaults `TERRAFORM_DIR=/builder/terraform` (the path inside the image), so
override it and pass an **absolute** config path (`terraform -chdir` breaks
relative `file()` resolution):

```shell
TERRAFORM_DIR=provider/aks/terraform tools/actuate -c "$PWD/config/aks-example.yaml" plan
TERRAFORM_DIR=provider/aks/terraform tools/actuate -c "$PWD/config/aks-example.yaml" apply
```

The Terraform state key is region-scoped
(`deployments/<location>/<id>/terraform.tfstate`), so switching a config's
`deployment.location` requires re-initializing the cached backend first:

```shell
rm -rf provider/aks/terraform/.terraform   # or: terraform init -reconfigure
```

---

## Discovery

```shell
provider/aks/tools/disco -r eastus     # identity, K8s versions, VM sizes
```

## Operational notes

- **Private cluster vs authorized IP ranges are mutually exclusive on AKS.** A
  private API server has no public endpoint, so `controlPlane.authorizedNetworks`
  is applied only when the cluster is public. This differs from GKE (which allows
  private nodes and authorized networks together).
- **KMS etcd encryption defaults OFF** — it requires Key Vault purge protection,
  whose soft-delete retention window complicates clean teardown of demo clusters.
- **GPU pools** default to H100 (`Standard_ND96isr_H100_v5`, 96 vCPU / 8×H100 per
  node). Quota is granted per VM family (`standardNDSH100v5Family`) and per
  region — check `az vm list-usage --location <region>` before deploying; GPU
  family increases usually require an Azure support ticket.
- **Availability zones**: node pools and the NAT public IP default to zones
  `["1","2","3"]`. Regions without AZ support (e.g. `westus`) need
  `cluster.aks.zones: []` in the config.
- **In-place Kubernetes upgrades cannot skip minor versions** (e.g. 1.33 → 1.35
  is rejected; upgrade via 1.34). Fresh clusters can target any supported
  version directly.
- **vCPU quota is per VM family.** When a single family's cap is too small,
  split pools across families (e.g. DSv5 system pool + DSv4 CPU workers).
- **ARM read-after-write lag** can make `azurerm` fail with "Root object was
  present, but now absent" right after creating a resource. The resource
  exists; recover with `terraform import <addr> <id>` and re-apply.
