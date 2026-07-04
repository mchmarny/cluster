# Oracle OKE Cluster Builder

Deploys a production-ready OKE (Container Engine for Kubernetes) cluster from a single YAML config:

- Private cluster with restricted API endpoint access
- OCI_VCN_IP_NATIVE pod networking (native VCN pod IPs)
- VCN with internet/NAT/service gateways and layered security lists/NSGs
- System node pool separated from worker pools
- Dynamic-group IAM policies for cluster and node operations

> **Status:** newly added, pending live validation against an OCI tenancy.
> Statically validated (`terraform validate`, schema, `go test`) but not yet
> exercised end-to-end. See "Notes / to validate" below.

---

## Deployment

### Prerequisites

- **oci CLI** configured (`~/.oci/config`, DEFAULT profile — API key auth)
- An **OCI Customer Secret Key** for the Terraform state backend (see setup)
- **yq** >= 4.0 for YAML parsing

### 1. Generate Config (optional)

The `init` command detects the provider from the filename prefix (`oke-*` generates an OKE template):

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/oke:latest init /config/oke-example.yaml
```

### 2. Setup Tenancy (one-time)

Bootstrap the tenancy with an Object Storage bucket for Terraform state:

```shell
provider/oke/tools/setup -c config/oke-example.yaml
```

This creates:
- Object Storage bucket `cluster-state` (versioning enabled)
- `backend.hcl` for the Terraform `s3` backend pointed at OCI's S3-compatibility
  endpoint (`https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`)

State is stored in **OCI Object Storage** — the `s3` backend block is used only for
protocol compatibility; no AWS services are involved.

### 3. Apply

The `oci` provider authenticates via `~/.oci/config`. The state backend uses an OCI
Customer Secret Key passed as an AWS-style key pair:

```shell
docker run --rm \
  -e CONFIG_CONTENT="$(base64 < config/oke-example.yaml)" \
  -e KEY_CONTENT="$(printf '%s:%s' "$OCI_ACCESS_KEY" "$OCI_SECRET_KEY" | base64)" \
  -e OCI_S3_ENDPOINT="https://<namespace>.compat.objectstorage.<region>.oraclecloud.com" \
  ghcr.io/mchmarny/cluster/oke:latest apply
```

### 4. Validate (optional)

```shell
provider/oke/tools/validate -c config/oke-example.yaml
```

### 5. Destroy

Set `deployment.destroy: true` in the config and re-run `apply`.

---

## Discovery

```shell
provider/oke/tools/disco -r us-ashburn-1     # identity, K8s versions, shapes
```

## Notes / to validate

- **State backend** is OCI Object Storage via the `s3` backend + S3-compatibility
  endpoint (per project decision to stay provider-native without crossing to AWS).
  Requires an OCI Customer Secret Key and the `skip_*`/`use_path_style` backend flags
  written by `tools/setup`.
- **Node pool autoscaling** is delivered by the in-cluster cluster-autoscaler add-on,
  not a Terraform field — pools set a fixed `size`; autoscaling is layered on post-deploy.
- **GPU pools** assume H100 (`BM.GPU.H100.8`) as the documented default; confirm
  shape/quota availability and GPU OKE image selection per region.
- Caller-identity precondition and OKE image selection use data sources that should be
  re-checked against live OCI APIs.
