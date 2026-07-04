# Azure AKS Cluster Builder

Deploys a production-ready AKS cluster from a single YAML config:

- Private cluster with Entra ID (Azure AD) RBAC integration
- OIDC issuer + Workload Identity for secret-free pod authentication
- Azure CNI networking with dedicated system and worker subnets
- NSGs + NAT gateway for controlled private-node egress
- Optional Key Vault KMS encryption for etcd secrets
- System node pool (CriticalAddonsOnly taint) separated from worker pools

> **Status:** newly added, pending live validation against an Azure subscription.
> Statically validated (`terraform validate`, schema, `go test`) but not yet
> exercised end-to-end. See "Notes / to validate" below.

---

## Deployment

### Prerequisites

- **az CLI** authenticated (`az login` — device-code flow supported)
- **kubelogin** for AAD-integrated `kubectl` access (bundled in the container image)
- **yq** >= 4.0 for YAML parsing

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

Authentication uses the Azure CLI login chain (`az login`); no service principal is required:

```shell
docker run --rm \
  -e CONFIG_CONTENT="$(base64 < config/aks-example.yaml)" \
  ghcr.io/mchmarny/cluster/aks:latest apply
```

### 4. Validate (optional)

```shell
provider/aks/tools/validate -c config/aks-example.yaml
```

### 5. Destroy

Set `deployment.destroy: true` in the config and re-run `apply`.

---

## Discovery

```shell
provider/aks/tools/disco -r eastus     # identity, K8s versions, VM sizes
```

## Notes / to validate

- **Private cluster vs authorized IP ranges are mutually exclusive on AKS.** A
  private API server has no public endpoint, so `controlPlane.authorizedNetworks`
  is applied only when the cluster is public. This differs from GKE (which allows
  private nodes and authorized networks together).
- **KMS etcd encryption defaults OFF** — it requires Key Vault purge protection,
  whose soft-delete retention window complicates clean teardown of demo clusters.
- **GPU pools** assume H100 (`Standard_ND96isr_H100_v5`) as the documented default;
  confirm SKU/quota availability per region.
- Node pools pin zones `["1","2","3"]`; verify zone availability for the target region.
