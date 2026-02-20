# DEMO

## Discover

```shell
tools/disco
```

## Config

```shell
export CLUSTER_CONFIG="configs/test-demo.yaml"
```

## Setup

Account:

```shell
tools/setup $CLUSTER_CONFIG
```

Variables:

```shell
export AWS_ACCOUNT=$(yq .deployment.tenancy $CLUSTER_CONFIG)
export DEP_ID=$(yq .deployment.id $CLUSTER_CONFIG)
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId ".${DEP_ID}-${AWS_ACCOUNT}-key.json")
export AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey ".${DEP_ID}-${AWS_ACCOUNT}-key.json")
```

## Plan

```shell
docker run \
  -e CONFIG_CONTENT="$(base64 < $CLUSTER_CONFIG)" \
  -e AUTO_APPROVE=true \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```

## Cleanup 

```shell
docker run \
  -e CONFIG_CONTENT="$(base64 < $CLUSTER_CONFIG)" \
  -e AUTO_APPROVE=true \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  ghcr.io/mchmarny/cluster/eks:latest destroy
```