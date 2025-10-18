# =====================================================================================
# Status to standard output
# =====================================================================================

output "status" {
  description = "Deployment"
  value = {
    deployment = {
      accountId  = data.aws_caller_identity.current.account_id
      region     = local.region
      updated    = local.updateTime
      prefix     = local.prefix
      tags       = try(local.config.deployment.tags, {})
      statusFile = local.statusFilePath
    }
    access = {
      command = "aws eks update-kubeconfig --region ${local.region} --name ${aws_eks_cluster.main.name} --alias ${aws_eks_cluster.main.name}"
    }
  }
}

# =====================================================================================
# Status to YAML file (next to config file)
# =====================================================================================
locals {
  status_data = {
    apiVersion = "github.com/mchmarny/cluster/v1alpha1"
    kind       = "ClusterStatus"
    metadata = {
      name      = aws_eks_cluster.main.name
      timestamp = local.updateTime
    }
    deployment = {
      id        = local.prefix
      accountId = data.aws_caller_identity.current.account_id
      region    = local.region
      tags      = try(local.config.deployment.tags, {})
    }
    cluster = {
      name    = aws_eks_cluster.main.name
      version = aws_eks_cluster.main.version
      status  = aws_eks_cluster.main.status
      kubernetes = {
        endpoint = aws_eks_cluster.main.endpoint
        ca       = aws_eks_cluster.main.certificate_authority[0].data
        cidr     = aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr
      }
      oidc = {
        issuer = aws_eks_cluster.main.identity[0].oidc[0].issuer
        arn    = aws_iam_openid_connect_provider.oidc_provider.arn
      }
      addons = {
        for addon_name, addon_config in {
          coredns = {
            enabled  = length(aws_eks_addon.coredns) > 0
            resource = length(aws_eks_addon.coredns) > 0 ? aws_eks_addon.coredns[0] : null
          }
          vpcCni = {
            enabled  = length(aws_eks_addon.vpc_cni) > 0
            resource = length(aws_eks_addon.vpc_cni) > 0 ? aws_eks_addon.vpc_cni[0] : null
          }
          kubeProxy = {
            enabled  = length(aws_eks_addon.kube_proxy) > 0
            resource = length(aws_eks_addon.kube_proxy) > 0 ? aws_eks_addon.kube_proxy[0] : null
          }
          cloudwatchObservability = {
            enabled  = length(aws_eks_addon.cloudwatch_observability) > 0
            resource = length(aws_eks_addon.cloudwatch_observability) > 0 ? aws_eks_addon.cloudwatch_observability[0] : null
            role     = length(aws_eks_addon.cloudwatch_observability) > 0 ? aws_iam_role.cloudwatch_observability.arn : null
          }
          metricsServer = {
            enabled  = length(aws_eks_addon.metrics_server) > 0
            resource = length(aws_eks_addon.metrics_server) > 0 ? aws_eks_addon.metrics_server[0] : null
          }
          ebsCsiDriver = {
            enabled  = length(aws_eks_addon.ebs_csi_driver) > 0
            resource = length(aws_eks_addon.ebs_csi_driver) > 0 ? aws_eks_addon.ebs_csi_driver[0] : null
            role     = length(aws_eks_addon.ebs_csi_driver) > 0 ? aws_iam_role.ebs_csi_driver.arn : null
          }
          } : addon_name => addon_config.enabled ? {
          name               = addon_name
          version            = addon_config.resource.addon_version
          arn                = addon_config.resource.arn
          serviceAccountRole = try(addon_config.role, null)
        } : null if addon_config.enabled
      }
    }
    network = {
      vpc = {
        id            = aws_vpc.main.id
        cidr          = aws_vpc.main.cidr_block
        secondaryCidr = aws_vpc_ipv4_cidr_block_association.secondary_cidr.cidr_block
      }
      subnets = {
        public = [
          for i, subnet in local.config.network.subnets.public : {
            name = "public${i + 1}"
            id   = aws_subnet.main["${local.prefix}-public-${subnet.zone}"].id
            cidr = aws_subnet.main["${local.prefix}-public-${subnet.zone}"].cidr_block
            zone = aws_subnet.main["${local.prefix}-public-${subnet.zone}"].availability_zone
          }
        ]
        system = [
          for i, subnet in local.config.network.subnets.system : {
            name = "system${i + 1}"
            id   = aws_subnet.main["${local.prefix}-system-${subnet.zone}"].id
            cidr = aws_subnet.main["${local.prefix}-system-${subnet.zone}"].cidr_block
            zone = aws_subnet.main["${local.prefix}-system-${subnet.zone}"].availability_zone
          }
        ]
        worker = [
          for i, subnet in local.config.network.subnets.worker : {
            name = "worker${i + 1}"
            id   = aws_subnet.main["${local.prefix}-worker-${subnet.zone}"].id
            cidr = aws_subnet.main["${local.prefix}-worker-${subnet.zone}"].cidr_block
            zone = aws_subnet.main["${local.prefix}-worker-${subnet.zone}"].availability_zone
          }
        ]
        pod = [
          for i, subnet in local.config.network.subnets.pod : {
            name = "pod${i + 1}"
            id   = aws_subnet.main["${local.prefix}-pod-${subnet.zone}"].id
            cidr = aws_subnet.main["${local.prefix}-pod-${subnet.zone}"].cidr_block
            zone = aws_subnet.main["${local.prefix}-pod-${subnet.zone}"].availability_zone
          }
        ]
      }
      securityGroups = {
        cluster = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
        system  = aws_security_group.main["${local.prefix}-system"].id
        worker  = aws_security_group.main["${local.prefix}-worker"].id
        pod     = aws_security_group.main["${local.prefix}-pod"].id
      }
      natGateways = [
        for i, subnet in local.config.network.subnets.public : {
          name             = "nat${i + 1}"
          id               = aws_nat_gateway.main["${local.prefix}-nat-${i}"].id
          publicIp         = aws_eip.nat["${local.prefix}-eip-${i}"].public_ip
          allocationId     = aws_eip.nat["${local.prefix}-eip-${i}"].id
          availabilityZone = subnet.zone
        }
      ]
      internetGateway = {
        id = aws_internet_gateway.main.id
      }
    }
    compute = {
      nodeGroups = [
        for ng in local.all_node_groups : {
          name                  = ng.name
          type                  = ng.type
          instanceType          = aws_launch_template.node_groups["${local.prefix}-${ng.name}"].instance_type
          autoscalingGroup      = aws_autoscaling_group.node_groups["${local.prefix}-${ng.name}"].name
          autoscalingGroupArn   = aws_autoscaling_group.node_groups["${local.prefix}-${ng.name}"].arn
          desiredCapacity       = aws_autoscaling_group.node_groups["${local.prefix}-${ng.name}"].desired_capacity
          minSize               = aws_autoscaling_group.node_groups["${local.prefix}-${ng.name}"].min_size
          maxSize               = aws_autoscaling_group.node_groups["${local.prefix}-${ng.name}"].max_size
          launchTemplate        = aws_launch_template.node_groups["${local.prefix}-${ng.name}"].name
          launchTemplateId      = aws_launch_template.node_groups["${local.prefix}-${ng.name}"].id
          launchTemplateVersion = aws_launch_template.node_groups["${local.prefix}-${ng.name}"].latest_version
        }
      ]
    }
    iam = {
      roles = {
        cluster     = aws_iam_role.eks_cluster.arn
        systemNodes = aws_iam_role.system_nodes.arn
        workerNodes = aws_iam_role.worker_nodes.arn
        cloudwatch  = aws_iam_role.cloudwatch_observability.arn
        ebsCsi      = aws_iam_role.ebs_csi_driver.arn
        vpcFlowLogs = aws_iam_role.vpc_flow_logs.arn
      }
      instanceProfiles = {
        systemNodes = aws_iam_instance_profile.system_nodes.arn
        workerNodes = aws_iam_instance_profile.worker_nodes.arn
      }
    }
    security = {
      kms = {
        keyId    = aws_kms_key.eks.id
        keyArn   = aws_kms_key.eks.arn
        aliasArn = aws_kms_alias.eks.arn
      }
      logging = {
        eksClusterLogs   = aws_cloudwatch_log_group.eks_cluster.name
        eksLogsRetention = aws_cloudwatch_log_group.eks_cluster.retention_in_days
        vpcFlowLogs      = aws_cloudwatch_log_group.vpc_flow_logs.name
        vpcFlowRetention = aws_cloudwatch_log_group.vpc_flow_logs.retention_in_days
      }
    }
  }
}

// Write status to YAML file
resource "local_file" "status" {
  filename = local.statusFilePath
  content  = jsonencode(local.status_data)

  file_permission      = "0644"
  directory_permission = "0755"
}
