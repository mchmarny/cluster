# Cluster

Collection of Kubernetes cluster deployment tools for multiple cloud platforms and local development. This repository provides deployment tools and configurations for creating Kubernetes clusters across different platforms:

## Managed Kubernetes Platforms

### [Azure Kubernetes Service (AKS)](./aks/)

  - Production-ready with comprehensive security and networking
  - Network Security Groups for system/worker/pod isolation
  - Azure AD Workload Identity for pod-level authentication
  - Private cluster support with private DNS zones
  - Key Vault Secrets Provider and Container Insights integration

### [Amazon Elastic Kubernetes Service (EKS)](./eks/)

  - Production-ready with advanced networking and security
  - Multi-AZ deployment, custom VPC, VPC CNI custom networking
  - Self-managed node groups with system/worker separation

### [Google Kubernetes Engine (GKE)](./gke/)

  - Enterprise-grade deployment with advanced features
  - Regional cluster, custom VPC networking, Workload Identity
  - Private cluster with authorized networks

### [Oracle Kubernetes Engine (OKE)](./oke/)

  - Production-ready deployment for Oracle Cloud Infrastructure
  - VCN-native pod networking for optimal performance
  - Regional cluster with flexible compute shapes
  - Advanced IAM with dynamic groups and policies
  - Support for GPU and ARM-based workloads

## Local Development

### [KinD (Kubernetes in Docker)](./kind/)

- KinD with Makefile automation
- Local cluster for development and testing

## Getting Started

1. Choose your target platform from the options above
2. Navigate to the corresponding directory
3. Follow the README instructions for your selected deployment method
4. Each deployment option includes configuration examples and usage instructions

## Prerequisites

- Platform-specific CLI tools (Azure CLI, AWS CLI, gcloud, OCI CLI, kubectl)
- For Terraform deployments: Terraform >= 1.13.0 installed
- For KinD: Docker installed and running
- yq (YAML processor) for configuration management
