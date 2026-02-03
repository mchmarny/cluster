# EKS Actuator Image
# Self-contained Terraform deployment image with pre-mirrored providers
# Supports: linux/amd64, linux/arm64

# Pin base image by digest for reproducibility
# debian:bookworm-slim as of 2024-01-15
FROM debian:bookworm-slim@sha256:1537a6a1cbc4b4fd401da800ee9480207e7dc1f23560c21b2a31c09e745250e3

# Build arguments
ARG TARGETARCH
ARG TARGETOS=linux

# Tool versions - pinned for reproducibility
ARG TERRAFORM_VERSION=1.13.0
ARG KUBECTL_VERSION=1.32.0
ARG YQ_VERSION=4.44.1
ARG AWSCLI_VERSION=2.22.0

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Terraform (architecture-aware)
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) TF_ARCH="amd64" ;; \
      arm64) TF_ARCH="arm64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip" -o /tmp/tf.zip; \
    unzip /tmp/tf.zip -d /usr/local/bin/; \
    rm /tmp/tf.zip; \
    terraform version

# Install kubectl (architecture-aware)
RUN set -eux; \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

# Install yq (architecture-aware)
RUN set -eux; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}" -o /usr/local/bin/yq; \
    chmod +x /usr/local/bin/yq; \
    yq --version

# Install AWS CLI (architecture-aware)
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH="x86_64" ;; \
      arm64) AWS_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o /tmp/awscli.zip; \
    unzip /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscli.zip /tmp/aws; \
    aws --version

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash builder

# Create directories
RUN mkdir -p /builder/terraform /builder/tools /opt/mirror/providers /opt/mirror/modules \
    && chown -R builder:builder /builder /opt/mirror

# Copy mirrored Terraform dependencies (architecture-specific providers)
COPY --chown=builder:builder mirror/providers/${TARGETARCH} /opt/mirror/providers
COPY --chown=builder:builder mirror/modules /opt/mirror/modules
COPY --chown=builder:builder mirror/terraform /builder/terraform
COPY --chown=builder:builder mirror/terraformrc /etc/terraformrc

# Copy provider checksums for verification
COPY --chown=builder:builder mirror/providers.sha256 /opt/mirror/providers.sha256

# Copy tools
COPY --chown=builder:builder tools/actuate /builder/tools/actuate
COPY --chown=builder:builder tools/common /builder/tools/common
RUN chmod +x /builder/tools/actuate

# Configure Terraform to use mirror
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc
ENV PATH="/builder/tools:${PATH}"

# Labels for reproducibility tracking
LABEL org.opencontainers.image.title="EKS Actuator"
LABEL org.opencontainers.image.description="Self-contained Terraform deployment for AWS EKS"
LABEL terraform.version="${TERRAFORM_VERSION}"
LABEL kubectl.version="${KUBECTL_VERSION}"
LABEL yq.version="${YQ_VERSION}"
LABEL awscli.version="${AWSCLI_VERSION}"

# Switch to non-root user
USER builder
WORKDIR /builder

# Default entrypoint
ENTRYPOINT ["/builder/tools/actuate"]
CMD ["--help"]
