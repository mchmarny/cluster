# OKE Actuator Image
# Self-contained Terraform deployment image with pre-mirrored providers
# Supports: linux/amd64, linux/arm64

# Pin base image by digest for reproducibility
FROM debian:bookworm-slim@sha256:98f4b71de414932439ac6ac690d7060df1f27161073c5036a7553723881bffbe

# Build arguments
ARG TARGETARCH
ARG TARGETOS=linux

# Tool versions - pinned for reproducibility
ARG TERRAFORM_VERSION=1.13.0
ARG KUBECTL_VERSION=1.32.0
ARG YQ_VERSION=4.44.1
ARG OCI_CLI_VERSION=3.50.1

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    jq \
    git \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Terraform (architecture-aware)
RUN set -eux; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -o /tmp/tf.zip; \
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

# Install OCI CLI (architecture-independent via pip)
RUN pip3 install --break-system-packages oci-cli==${OCI_CLI_VERSION} \
    && oci --version

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
LABEL org.opencontainers.image.title="OKE Actuator"
LABEL org.opencontainers.image.description="Self-contained Terraform deployment for Oracle OKE"
LABEL terraform.version="${TERRAFORM_VERSION}"
LABEL kubectl.version="${KUBECTL_VERSION}"
LABEL yq.version="${YQ_VERSION}"
LABEL oci_cli.version="${OCI_CLI_VERSION}"

# Switch to non-root user
USER builder
WORKDIR /builder

# Default entrypoint
ENTRYPOINT ["/builder/tools/actuate"]
CMD ["--help"]
