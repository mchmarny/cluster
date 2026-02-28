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

Bootstrap the target tenancy (e.g. account on AWS or project on GCP) based on the config file:

> Assumes user is already authenticated to the target tenancy and the provider-specific credentials are passed into the setup step. The `/state` volume persists the generated service account key for use during apply. Do not commit that file into source control. 

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e CONFIG_CONTENT="$(base64 < $CLUSTER_CONFIG)" \
  ghcr.io/mchmarny/cluster/eks:latest setup
```

## Apply

Deploy the desired cluster state to the tenancy. Credentials are loaded from the key file saved during setup (in `/state`), or from env vars if set.

> Set `deployment.destroy: true` in the config to destroy the previously applied cluster and all of its resources.

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e CONFIG_CONTENT="$(base64 < $CLUSTER_CONFIG)" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```
