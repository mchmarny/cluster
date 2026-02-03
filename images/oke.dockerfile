# OKE Actuator Image
# Self-contained Terraform deployment image with pre-mirrored providers

FROM debian:bookworm-slim

# Tool versions (pinned)
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

# Install Terraform
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/tf.zip \
    && unzip /tmp/tf.zip -d /usr/local/bin/ \
    && rm /tmp/tf.zip \
    && terraform version

# Install kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# Install yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && yq --version

# Install OCI CLI
RUN pip3 install --break-system-packages oci-cli==${OCI_CLI_VERSION} \
    && oci --version

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash builder

# Create directories
RUN mkdir -p /builder/terraform /builder/tools /opt/mirror/providers /opt/mirror/modules \
    && chown -R builder:builder /builder /opt/mirror

# Copy mirrored Terraform dependencies
COPY --chown=builder:builder mirror/providers /opt/mirror/providers
COPY --chown=builder:builder mirror/modules /opt/mirror/modules
COPY --chown=builder:builder mirror/terraform /builder/terraform
COPY --chown=builder:builder mirror/terraformrc /etc/terraformrc

# Copy tools
COPY --chown=builder:builder tools/actuate /builder/tools/actuate
COPY --chown=builder:builder tools/common /builder/tools/common
RUN chmod +x /builder/tools/actuate

# Configure Terraform to use mirror
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc
ENV PATH="/builder/tools:${PATH}"

# Switch to non-root user
USER builder
WORKDIR /builder

# Default entrypoint
ENTRYPOINT ["/builder/tools/actuate"]
CMD ["--help"]
