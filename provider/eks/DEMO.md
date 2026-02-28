# Demo

The same pattern applies to all providers — only the config file and provider path change.

## Init

Generate a starter config:

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/eks:latest init /config/eks-example.yaml
```

## Setup

Bootstrap the target tenancy (one-time, as yourself with admin credentials):

```shell
provider/eks/tools/setup -c config/eks-example.yaml -o ./keys
```

This creates the S3 state bucket, IAM user, policy, and access key. The key file is saved to `./keys/.{id}-{account}-key.json`.

## Apply

Deploy the desired cluster state using the service account key from setup:

> Set `deployment.destroy: true` in the config to destroy the cluster.

```shell
docker run --rm \
  -e KEY_CONTENT="$(base64 < ./keys/.{id}-{account}-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-example.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```

## Output

Retrieve deployment outputs (endpoint, access command, etc.) and save to the state volume:

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e KEY_CONTENT="$(base64 < ./keys/.{id}-{account}-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-example.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest output
```

The output JSON is saved to `/state/<id>-<tenancy>-output.json`.
