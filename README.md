# Cluster

Collection of Kubernetes cluster deployment tools for multiple cloud platforms and local development. This repository provides deployment tools and configurations for creating Kubernetes clusters across different platforms:

### Managed Kubernetes Platforms

#### Azure Kubernetes Service (AKS)
- **Location**: `aks/`
- **Tool**: Azure CLI with Makefile automation
- **Features**: Configurable cluster parameters, static IP provisioning, node pool management
- **Usage**: `make cluster` for deployment

#### Amazon Elastic Kubernetes Service (EKS)
- **CloudFormation**: `eks/cf/`
  - AWS CloudFormation templates for EKS deployment
  - Custom AMI support for specialized workloads
- **eksctl**: `eks/eksctl/` 
  - Simple YAML-based cluster configuration
  - Quick cluster creation with `eksctl create cluster`
- **Terraform**: `eks/tf/`
  - Production-ready with advanced networking and security
  - Multi-AZ deployment, custom VPC, VPC CNI custom networking
  - Self-managed node groups with system/worker separation

#### Google Kubernetes Engine (GKE)
- **gcloud CLI**: `gke/gcloud/`
  - Simple script-based deployment
  - Basic cluster setup with essential APIs
- **Terraform**: `gke/tf/`
  - Enterprise-grade deployment with advanced features
  - Regional cluster, custom VPC networking, Workload Identity
  - Private cluster with authorized networks

#### Oracle Kubernetes Engine (OKE)
- **Terraform**: `oci/tf/`
  - Production-ready deployment for Oracle Cloud Infrastructure
  - VCN-native pod networking for optimal performance
  - Regional cluster with flexible compute shapes
  - Advanced IAM with dynamic groups and policies
  - Support for GPU and ARM-based workloads

### Local Development

#### KinD (Kubernetes in Docker)
- **Location**: `kind/`
- **Tool**: KinD with Makefile automation
- **Features**: Local cluster for development and testing
- **Usage**: `make cluster-up` for creation, `make cluster-down` for cleanup

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
