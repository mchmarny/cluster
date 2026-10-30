# Oracle OKE Cluster Builder

Deploys a production-ready OKE (Container Engine for Kubernetes) cluster from a single YAML config:

- Enhanced cluster, private API endpoint by default (optional public endpoint gated by CIDR allowlist)
- Flannel overlay pod networking by default, or OCI_VCN_IP_NATIVE with `cluster.oke.cni: vcn-native` (pods get VCN IPs from a dedicated pod subnet; see [Notes](#notes) for why it is not the default)
- VCN with internet/NAT/service gateways and NSGs per role (control plane, nodes, pods)
- System node pool separated from worker pools; GPU pools via `gpuType`
- Kubernetes secrets encrypted in etcd with a customer-managed KMS key

> **Validated live** (2026-10-27, `ap-kulai-2`, K8s v1.36.4): enhanced cluster
> with KMS etcd encryption, VCN-native pod networking, 3x E5.Flex system +
> 1x E5.Flex CPU worker, and a 1-host BM.GPU.GB300.4 fabric pool in an NVL72 GPU
> memory fabric (Oracle Ubuntu 24.04 aarch64 driver-595 image). All nodes Ready,
> OKE's NvidiaGpuPlugin advertising 4 GPUs; destroyed and re-applied from clean
> state to confirm reproducibility. Validated again (2026-10-29) with Flannel,
> a 4-host GB300 fabric pool joining with a Nodewright taint, and
> `NvidiaGpuPlugin` configured with `deviceListStrategy: volume-mounts`.

---

## Deployment

### Prerequisites

- **oci CLI** configured (`~/.oci/config`)
- **yq** >= 4.0 for YAML parsing
- Permissions in the target compartment to manage VCNs, OKE clusters, instances,
  KMS vaults/keys, Object Storage buckets, and policies. The module's policies
  (etcd key, fabric-pool cluster join) live in `cluster.oke.compartmentId`, so
  tenancy admin is needed only when that is unset and they land in the root
  compartment

### Authentication

The terraform `oci` provider, the `oci` state backend, and the tools in this
directory all read `~/.oci/config`. Two env vars select how:

| Variable | Default | Example |
|---|---|---|
| `OCI_AUTH` | `ApiKey` | `SecurityToken` (after `oci session authenticate`) |
| `OCI_CONFIG_FILE_PROFILE` | `DEFAULT` | `dev` |

Session tokens expire after an hour; run `oci session refresh --profile <profile>`
before long applies (bare-metal GPU pools take 30m+).

### 1. Generate Config (optional)

The `init` command detects the provider from the filename prefix (`oke-*` generates an OKE template):

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/oke:latest init /config/oke-example.yaml
```

### 2. Setup Tenancy (one-time)

Bootstrap an Object Storage bucket for Terraform state:

```shell
provider/oke/tools/setup -c config/oke-example.yaml
```

This creates bucket `cluster-state` (versioned, private) in the configured
compartment and writes `backend.hcl` for Terraform's native `oci` backend. Bucket
names are unique per tenancy namespace; setup refuses to reuse a `cluster-state`
bucket that lives in another compartment.

Setup prints the tenancy's Object Storage namespace. Export it; the `cluster` CLI
needs it to configure the state backend:

```shell
export OCI_NAMESPACE=<namespace>
```

### 3. Apply

```shell
docker run --rm \
  -e CONFIG_CONTENT="$(base64 < config/oke-example.yaml)" \
  -e OCI_NAMESPACE -e OCI_AUTH -e OCI_CONFIG_FILE_PROFILE \
  -v $HOME/.oci:/home/builder/.oci:ro \
  ghcr.io/mchmarny/cluster/oke:latest apply
```

`~/.oci/config` must reference key and token files with `~/.oci/...` paths for
the mount to resolve inside the container. To run from a checkout instead:

```shell
TERRAFORM_DIR=provider/oke/terraform tools/actuate -c "$PWD/config/oke-example.yaml" apply
```

(`actuate` resolves the namespace with the `oci` CLI when `OCI_NAMESPACE` is unset;
the config path must be absolute.)

### 4. Validate (optional)

```shell
provider/oke/tools/validate -c config/oke-example.yaml
```

Checks cluster, node-pool, and GPU memory cluster state, that every configured
node is Ready, CoreDNS, and pod IPs for the configured CNI. GPU allocatable is reported but
not checked: the GPU runtime belongs to the workload layer (e.g. AICR). The API
must be reachable: set `cluster.oke.controlPlane.isPublicIpEnabled: true` or run
from inside the VCN.

### 5. Destroy

Set `deployment.destroy: true` in the config and re-run `apply`.

---

## Discovery

```shell
provider/oke/tools/disco -r <region> -p <compartment-ocid> [-v v1.36.4] [-i <image-compartment-ocid>]
```

Lists K8s versions, GPU shapes visible per AD, the newest OKE platform image per
architecture for the version, and (with `-i`) custom aarch64 images to use as
`imageId`.

## GPU Pools

`gpuType` selects the shape unless `shape` is set:

| gpuType | Shape | Arch |
|---|---|---|
| `a10` | `VM.GPU.A10.1` | x86_64 |
| `l40s` | `BM.GPU.L40S.4` | x86_64 |
| `h100` | `BM.GPU.H100.8` | x86_64 |
| `gb200` | `BM.GPU.GB200.4` | aarch64 |
| `gb300` | `BM.GPU.GB300.4` | aarch64 |

- **Images:** x86 pools get the newest OKE GPU platform image for the cluster
  version. aarch64 GPU shapes have no OKE platform image — set `imageId` (plan
  fails otherwise). Selection is stable for a given catalog but moves when OCI
  publishes a newer build; pin `imageId` to freeze it.
- **Placement:** GPU capacity is AD-specific. Pin `availabilityDomains: [n]`
  (1-based) to the AD that carries the shape and limit (`disco` shows both sides).
- **Fabric pools (GB200/GB300 NVL72):** rack-scale hosts live in a GPU memory
  fabric and are reachable only through a GPU memory cluster, not OKE managed node
  pools. Set `gpuMemoryFabricId` (from `disco`) on the worker to make it
  self-managed: the module creates a compute cluster, an instance configuration
  carrying the OKE join metadata, and a GPU memory cluster of `size` hosts, plus a
  compartment-scoped `CLUSTER_JOIN` policy limited to this cluster. `imageId` is
  required and the pool must resolve to one AD.
- **RDMA cluster networks** for x86 multi-node (H100/L40S) are not configured.

## GPU Driver

The module keeps cluster bring-up minimal: it provisions GPU nodes with a
driver source and deploys no GPU runtime components (GPU Operator, Node Feature
Discovery, DCGM). Those belong to the workload layer (e.g. AICR).
`cluster.oke.gpuDriver` selects where the driver comes from:

| Mode | Driver | Device plugin | Images |
|---|---|---|---|
| `image` (default) | node image | OKE's default `NvidiaGpuPlugin` add-on | OKE GPU platform images (x86, automatic); Oracle GPU images via `imageId` |
| `operator` | GPU Operator (external) | GPU Operator; OKE plugin disabled on GPU pools | driverless Ubuntu `imageId` (required) |

- Under `operator`, GPU pools are labeled
  `oci.oraclecloud.com/disable-gpu-device-plugin=true` so OKE's plugin does not
  double-advertise GPUs. AICR's `gpuStack=operator-managed` additionally expects
  the `NvidiaGpuPlugin` add-on removed:
  `oci ce cluster disable-addon --cluster-id <id> --addon-name NvidiaGpuPlugin --is-remove-existing-add-on true`.
- OKE's own `NvidiaGpuOperator` add-on (if enabled outside this module) removes
  `NvidiaGpuPlugin` when configured with `disableNvidiaGpuPlugin`, and removing
  the operator does not restore it. Reinstall with
  `oci ce cluster install-addon --cluster-id <id> --addon-name NvidiaGpuPlugin`.
- GB200/GB300: Oracle publishes driver-bearing Ubuntu 24.04 aarch64 images
  ([worker node images](https://github.com/oracle-quickstart/oci-hpc-oke/blob/main/docs/worker-node-images.md));
  import one (`oci compute image import from-object-uri`) and use its OCID as
  `imageId` with `gpuDriver: image`. Custom-image nodes bootstrap with
  `templates/custom-image-init.sh`, which follows Oracle's Ubuntu flow (installs
  the OKE node package from Oracle's repo when the image lacks it).

## Notes

- **Upgrading a deployment created before Flannel became the default**
  (images `v0.1.0-oke` and `v0.1.1-oke`, VCN-native with a `10.244.0.0/16` pods
  CIDR): before the next `cluster apply`, add `cluster.oke.cni: vcn-native`, and
  `network.oke.podsCidr: 10.244.0.0/16` if the config does not set it. Both are
  create-time settings, and `cluster apply` applies its plan without a prompt,
  so without them the cluster and its fabric hosts are destroyed and recreated.
- **Pool changes do not roll existing nodes:** image catalog updates, `imageId`,
  labels, `taints`, or `gpuDriver` changes apply to nodes launched afterwards. Managed
  pools need node cycling (`oci ce node-pool update`, or scale down/up); fabric
  pools need their GPU memory cluster recreated, which `actuate` can plan by
  passing `-replace` to the plan step:

  ```shell
  TF_CLI_ARGS_plan="-replace='oci_core_compute_gpu_memory_cluster.fabric[\"<pool>\"]'" \
    TERRAFORM_DIR=provider/oke/terraform tools/actuate -c "$PWD/config/<file>.yaml" plan
  TERRAFORM_DIR=provider/oke/terraform tools/actuate -c "$PWD/config/<file>.yaml" apply
  ```

  Replacing the cluster itself recreates fabric hosts automatically.
- **Autoscaling:** OKE has no node-pool autoscaling field; pools use a fixed
  `size`. Autoscaling is the in-cluster cluster-autoscaler add-on, layered on
  post-deploy. EKS/GKE/AKS autoscale from config.
- **Taints:** OKE managed node pools have no taint field, so pools are untainted
  by default (unlike EKS/GKE/AKS). A pool's `taints` (`key=value:effect`) are
  passed to kubelet as `--register-with-taints` through the `kubelet-extra-args`
  instance metadata, so the node registers already tainted. Tainted pools boot
  through `templates/custom-image-init.sh`, including platform-image pools,
  because OKE's default bootstrap takes no kubelet arguments.
- **Pod networking:** `cluster.oke.cni` defaults to `flannel`. VCN-native pod
  networking sets `disable_ipv6=1` in pod namespaces, so an RDMA VF that
  `host-device` moves into a pod never gets its IPv6 address, GID index 3 stays
  empty, and RoCEv2 (NCCL over the GB200/GB300 RDMA VFs) fails. Flannel leaves
  IPv6 at the kernel default. The CNI is create-time only.
- **Add-ons:** `cluster.oke.addons` maps an OKE add-on name to its configuration
  keys (`oci ce addon-option list`). The module installs the add-on, or adopts it
  when OKE pre-installed it (enhanced clusters install `NvidiaGpuPlugin`), for
  example `NvidiaGpuPlugin: {deviceListStrategy: volume-mounts}`. Configuring
  `NvidiaGpuPlugin` is rejected with `gpuDriver: operator`.
- **Node pool eviction:** `compute.oke.nodePoolEviction` (optional) sets how long
  OKE drains a managed node before deleting it (`gracePeriod`, `PT0M` to `PT30M`)
  and whether to delete it anyway once that time is up (`forceDelete`). Absent,
  OKE's defaults apply (60 minutes, no force delete). Test clusters set
  `forceDelete: true` so a PodDisruptionBudget cannot hang a destroy; with
  `gracePeriod` omitted the node is then deleted without waiting (`PT0M`), since
  OKE's 60-minute default outlasts the 45-minute node pool delete timeout.
- **etcd encryption** (`security.secretsEncryption.enabled`, default true) creates
  a KMS vault, key, and a compartment policy letting OKE (service and cluster
  principal) use the key. It is create-time only: toggling it replaces the
  cluster. Destroying only schedules vault/key deletion (7-30 days).
- **Tenancy identity** (`cluster.oke.identity.manage`, default false) creates a
  tenancy-level dynamic group and policy for node instance principals; it needs
  tenancy admin and is not required by managed node pools.
