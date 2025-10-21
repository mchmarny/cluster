apiVersion: v1
kind: Config
current-context: ${cluster_name}
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: ${cluster_endpoint}
  name: ${cluster_name}
contexts:
- context:
    cluster: ${cluster_name}
    user: ${cluster_name}-user
  name: ${cluster_name}
users:
- name: ${cluster_name}-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: oci
      args:
      - ce
      - cluster
      - generate-token
      - --cluster-id
      - ${cluster_id}
      - --region
      - ${region}
