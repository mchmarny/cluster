# EKS Demo

Walkthrough using `config/eks-min-cpu.yaml` -- a minimal CPU cluster without VPC CNI custom networking.

## 1. Discover versions (optional)

Find supported K8s versions, add-on versions, and your IAM role name for `cluster.adminRoles`:

```shell
provider/eks/tools/disco -r us-east-1
```

## 2. Generate config (optional)

Generate a starter config if you don't already have one:

```shell
docker run --rm -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/eks:latest init /config/eks-min-cpu.yaml
```

Or copy and edit an existing example from `config/`.

## 3. Setup tenancy (one-time)

Bootstrap the AWS account with S3 state bucket, IAM user, and access key. Run as yourself with admin credentials:

```shell
provider/eks/tools/setup -c config/eks-min-cpu.yaml -o provider/eks/keys
```

## 4. Apply

Deploy using the service account key from setup:

```shell
docker run --rm \
  -e KEY_CONTENT="$(base64 < provider/eks/keys/.min-cpu-615299774277-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-min-cpu.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```

## 5. Validate (optional)

Run post-deployment checks:

```shell
provider/eks/tools/validate -c config/eks-min-cpu.yaml
```

## 6. Output (optional)

Retrieve deployment outputs and save to a local directory:

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e KEY_CONTENT="$(base64 < provider/eks/keys/.min-cpu-615299774277-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-min-cpu.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest output
```

The output JSON is saved to `/state/min-cpu-615299774277-output.json`.

## 7. Destroy

Set `deployment.destroy: true` in the config and re-run apply (step 4).
