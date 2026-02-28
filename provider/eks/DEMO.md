# EKS Demo

## Discovery (optional)

If you are deploying into new tenancy...

```shell
provider/eks/tools/disco -r us-east-1
```

## Init (optional)

Generate a starter config if you don't already have one:

```shell
docker run --rm -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/eks:latest init /config/eks-min.test.yaml
```

## Setup

Bootstrap the target tenancy (one-time, as yourself with admin credentials):

```shell
provider/eks/tools/setup -c config/eks-min.test.yaml -o provider/eks/keys
```

This creates the S3 state bucket, IAM user, policy, and access key (in the target folder)

## Apply

Deploy the desired cluster state using the service account key from setup:

> Set `deployment.destroy: true` in the config to destroy the cluster.

```shell
docker run --rm \
  -e KEY_CONTENT="$(base64 < provider/eks/keys/.mini-615299774277-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-min.test.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```

## Output

Retrieve deployment outputs (endpoint, access command, etc.) and save to the state volume:

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e KEY_CONTENT="$(base64 < provider/eks/keys/.mini-615299774277-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-min.test.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest output
```

The output JSON is saved to `/state/mini-615299774277-output.json`.
