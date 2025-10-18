# EKS

## Create the EKS cluster

```shell
eksctl create cluster -f cluster.yaml --name labz-demo --region us-west-2
```

## Describe the EKS cluster stack to resolve any bringup issues

```shell
eksctl utils describe-stacks --cluster labz-demo --region us-west-2
```

## Update kubeconfig

```shell
aws eks update-kubeconfig --name labz-demo --region us-west-2
```

## Test cluster connection 

```shell
kubectl get nodes -o wide
```

## Set roles (protected label, can't be set at inception)

```shell
for l in system worker; do for n in $(kubectl get nodes -l nodeGroup=$l -o jsonpath='{.items[*].metadata.name}'); do kubectl label nodes "$n" node-role.kubernetes.io/$l="" --overwrite; done; done
```