# OKE v2 Actuator Image
# Self-contained Terraform deployment with Go CLI entrypoint
# Supports: linux/amd64, linux/arm64
#
# Build:
#   ./tools/mirror oke           # optional: pre-cache TF providers for offline
#   docker build -f image/oke.dockerfile -t cluster:dev .
#
# Run:
#   docker run --rm cluster:dev --version
#   docker run --rm -e CONFIG_CONTENT -e KEY_CONTENT -e OCI_S3_ENDPOINT \
#     cluster:dev apply

# =============================================================================
# Stage 1: Build Go binary
# =============================================================================
FROM golang:1.26-bookworm AS gobuild

ARG VERSION=dev
ARG COMMIT=unknown
ARG TARGETOS=linux
ARG TARGETARCH

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY pkg/ pkg/
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
    -o /cluster ./cmd/cluster

# =============================================================================
# Stage 2: Download and verify external tools
# =============================================================================
FROM debian:bookworm-slim AS tools

ARG TARGETARCH
ARG TERRAFORM_VERSION=1.15.5
ARG KUBECTL_VERSION=1.36.1
ARG OCI_VERSION=3.89.0

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl unzip \
       python3 python3-venv python3-dev build-essential libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Terraform (with checksum verification)
RUN set -eux; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -o /tmp/tf.zip && \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" -o /tmp/tf.sha && \
    grep "linux_${TARGETARCH}.zip" /tmp/tf.sha | awk '{print $1 "  /tmp/tf.zip"}' | sha256sum -c - && \
    unzip /tmp/tf.zip -d /usr/local/bin/ && \
    rm /tmp/tf.zip /tmp/tf.sha

# kubectl (with checksum verification)
RUN set -eux; \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl && \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" -o /tmp/kubectl.sha256 && \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - && \
    chmod +x /usr/local/bin/kubectl && \
    rm /tmp/kubectl.sha256

# OCI CLI (Python package installed into a relocatable venv)
RUN set -eux; \
    python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir "oci-cli==${OCI_VERSION}"

# =============================================================================
# Stage 3: Prepare mirror content (handles missing mirror gracefully)
# =============================================================================
FROM debian:bookworm-slim AS mirror-prep

ARG TARGETARCH

# Create default empty directories (used when mirror hasn't been run)
RUN mkdir -p /mirror/providers /mirror/modules /mirror/terraform

# Copy mirror content if it exists (COPY will fail on missing dir,
# so we use a wildcard + default fallback)
COPY mirror/provider[s]/${TARGETARCH} /mirror/providers/
COPY mirror/module[s] /mirror/modules/
COPY mirror/terrafor[m] /mirror/terraform/
COPY mirror/terraformr[c] /mirror/

# Create fallback terraformrc if mirror wasn't run
RUN test -f /mirror/terraformrc || echo 'provider_installation { filesystem_mirror { path = "/opt/mirror/providers" include = ["*/*"] } direct { exclude = ["*/*"] } }' > /mirror/terraformrc

# =============================================================================
# Stage 4: Final image (minimal runtime)
# =============================================================================
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       ca-certificates jq git python3 libffi8 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash builder \
    && mkdir -p /builder/terraform /opt/mirror/providers /opt/mirror/modules /state \
    && chown -R builder:builder /builder /opt/mirror /state

# Tools from stage 2
COPY --from=tools /usr/local/bin/terraform /usr/local/bin/terraform
COPY --from=tools /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=tools /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Go binary from stage 1
COPY --from=gobuild /cluster /usr/local/bin/cluster

# Terraform mirror content from stage 3
COPY --from=mirror-prep --chown=builder:builder /mirror/providers /opt/mirror/providers
COPY --from=mirror-prep --chown=builder:builder /mirror/modules /opt/mirror/modules
COPY --from=mirror-prep --chown=builder:builder /mirror/terraform /builder/terraform
COPY --from=mirror-prep --chown=builder:builder /mirror/terraformrc /etc/terraformrc

# OKE Terraform source (always available)
COPY --chown=builder:builder provider/oke/terraform /builder/terraform

ENV TF_CLI_CONFIG_FILE=/etc/terraformrc

ARG VERSION=dev
ARG TERRAFORM_VERSION=1.15.5
ARG KUBECTL_VERSION=1.36.1
ARG OCI_VERSION=3.89.0
LABEL org.opencontainers.image.title="OKE v2 Actuator" \
      org.opencontainers.image.description="Self-contained Terraform deployment for Oracle OKE" \
      org.opencontainers.image.version="${VERSION}" \
      terraform.version="${TERRAFORM_VERSION}" \
      kubectl.version="${KUBECTL_VERSION}" \
      oci.version="${OCI_VERSION}"

USER builder
WORKDIR /builder

ENTRYPOINT ["cluster"]
CMD ["--help"]
