#!/usr/bin/env bash
# OKE node bootstrap for custom images (pools with imageId). OKE only injects
# its default bootstrap when user_data is unset. Follows Oracle's Ubuntu flow
# (oracle-quickstart/oci-hpc-oke files/oke-ubuntu-cloud-init.sh):
#   - images with oke-init.service (OKE node images, e.g. NVIDIA DGXC): start it
#   - Ubuntu without the OKE node package (e.g. Oracle GPU images): install
#     oci-oke-node-all-<k8s-version> from Oracle's OKE repo, then oke bootstrap
#   - Oracle Linux: the init script OKE publishes in instance metadata
set -euo pipefail

imds() {
  curl -fsS -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/$1"
}

retry() {
  local attempt
  for attempt in $(seq 1 20); do
    "$@" && return 0
    echo "attempt $attempt failed: $*" >&2
    sleep 15
  done
  return 1
}

# Instance principal certs must exist before the node can authenticate to OKE.
until imds identity/cert.pem 2>/dev/null | grep -q "BEGIN CERTIFICATE"; do sleep 2; done

. /etc/os-release
SHAPE=$(imds instance/shape || true)
K8S_VERSION=$(imds instance/metadata/oke-k8version || true)

if [[ "$SHAPE" == *GPU* ]]; then
  # GPU/RDMA workloads (NCCL) need unlimited locked memory.
  mkdir -p /etc/crio/crio.conf.d
  printf '[crio.runtime]\ndefault_ulimits = [\n  "memlock=-1:-1"\n]\n' >/etc/crio/crio.conf.d/12-memlock.conf
fi

if [[ "$SHAPE" == BM.GPU.GB200* || "$SHAPE" == BM.GPU.GB300* ]]; then
  # IMEX is coordinated in-cluster (DRA ComputeDomains), not by the host service.
  if systemctl list-unit-files nvidia-imex.service | grep -q nvidia-imex; then
    systemctl disable --now nvidia-imex.service
    systemctl mask nvidia-imex.service
  fi
fi

if [[ -n "$K8S_VERSION" && "$(printf '%s\n' "$K8S_VERSION" v1.34 | sort -V | head -1)" == v1.34 ]]; then
  # CRI-O 1.34+ rejects unqualified image names by default.
  mkdir -p /etc/crio/crio.conf.d
  printf '[crio.image]\nshort_name_mode = "disabled"\n' >/etc/crio/crio.conf.d/11-default.conf
fi

if systemctl cat oke-init.service &>/dev/null; then
  # Static-pod dir must exist and a stale cri-o unit override must not shadow
  # the one oke-init installs.
  mkdir -p /etc/kubernetes/manifests
  rm -f /etc/systemd/system/cri-o.service
  systemctl --no-block enable --now oke-init.service
elif [[ "$ID" == ubuntu ]]; then
  if ! command -v oke >/dev/null; then
    [[ -n "$K8S_VERSION" ]] || { echo "oke-k8version metadata missing" >&2; exit 1; }
    version="${K8S_VERSION#v}"
    repo="https://odx-oke.objectstorage.us-sanjose-1.oci.customer-oci.com/n/odx-oke/b/okn-repositories/o/prod/ubuntu-${VERSION_CODENAME}/kubernetes-${version%.*}"
    # Oracle publishes this repo unsigned (oci-hpc-oke uses the same source).
    printf 'Enabled: yes\nTypes: deb\nURIs: %s\nSuites: stable\nComponents: main\nTrusted: yes\n' "$repo" \
      >/etc/apt/sources.list.d/oke-node-client.sources
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 1; done
    retry apt-get -y update
    retry apt-get -y install "oci-oke-node-all-${version}"
  fi
  retry oke bootstrap
else
  imds instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh
  retry bash /var/run/oke-init.sh
fi
