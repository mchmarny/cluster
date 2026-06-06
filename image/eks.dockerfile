# EKS v2 Actuator Image
# Self-contained Terraform deployment with Go CLI entrypoint
# Supports: linux/amd64, linux/arm64
#
# Build:
#   ./tools/mirror eks           # optional: pre-cache TF providers for offline
#   docker build -f image/eks.dockerfile -t cluster:dev .
#
# Run:
#   docker run --rm cluster:dev --version
#   docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
#     -v $PWD/config:/configs cluster:dev apply -c /configs/demo.yaml

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
ARG AWSCLI_VERSION=2.34.63

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl unzip \
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

# AWS CLI
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH="x86_64" ;; \
      arm64) AWS_ARCH="aarch64" ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o /tmp/awscli.zip && \
    unzip -q /tmp/awscli.zip -d /tmp && \
    /tmp/aws/install --install-dir /opt/aws-cli --bin-dir /usr/local/bin && \
    rm -rf /tmp/awscli.zip /tmp/aws

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
       ca-certificates jq git \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash builder \
    && mkdir -p /builder/terraform /opt/mirror/providers /opt/mirror/modules /state \
    && chown -R builder:builder /builder /opt/mirror /state

# Tools from stage 2
COPY --from=tools /usr/local/bin/terraform /usr/local/bin/terraform
COPY --from=tools /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=tools /opt/aws-cli /opt/aws-cli
RUN ln -s /opt/aws-cli/v2/current/bin/aws /usr/local/bin/aws && \
    ln -s /opt/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer

# Go binary from stage 1
COPY --from=gobuild /cluster /usr/local/bin/cluster

# Terraform mirror content from stage 3
COPY --from=mirror-prep --chown=builder:builder /mirror/providers /opt/mirror/providers
COPY --from=mirror-prep --chown=builder:builder /mirror/modules /opt/mirror/modules
COPY --from=mirror-prep --chown=builder:builder /mirror/terraform /builder/terraform
COPY --from=mirror-prep --chown=builder:builder /mirror/terraformrc /etc/terraformrc

# EKS Terraform source (always available)
COPY --chown=builder:builder provider/eks/terraform /builder/terraform

ENV TF_CLI_CONFIG_FILE=/etc/terraformrc

ARG VERSION=dev
ARG TERRAFORM_VERSION=1.15.5
ARG KUBECTL_VERSION=1.36.1
ARG AWSCLI_VERSION=2.34.63
LABEL org.opencontainers.image.title="EKS v2 Actuator" \
      org.opencontainers.image.description="Self-contained Terraform deployment for AWS EKS" \
      org.opencontainers.image.version="${VERSION}" \
      terraform.version="${TERRAFORM_VERSION}" \
      kubectl.version="${KUBECTL_VERSION}" \
      awscli.version="${AWSCLI_VERSION}"

USER builder
WORKDIR /builder

ENTRYPOINT ["cluster"]
CMD ["--help"]
