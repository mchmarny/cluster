data "aws_caller_identity" "current" {}
data "http" "egress_ip" {
  url             = "https://checkip.amazonaws.com"
  request_headers = { Accept = "text/plain" }
}

locals {
  // Load configuration from YAML file
  config = yamldecode(file(var.CONFIG_PATH))

  configDir      = dirname(var.CONFIG_PATH)
  configFilename = basename(var.CONFIG_PATH)
  configBasename = replace(local.configFilename, "/\\.ya?ml$/", "")
  statusFilePath = "${local.configDir}/${local.configBasename}-status.json"

  // Update time 
  updateTime = timestamp()

  // Extract required deployment settings
  prefix      = local.config.deployment.id
  region      = local.config.deployment.location
  account     = data.aws_caller_identity.current.account_id
  egress_cidr = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Extract optional deployment settings with defaults
  eks_version = try(local.config.cluster.version, null)

  // Observability
  logRetentionInDays        = try(local.config.observability.logRetentionInDays, 7)
  vpcFlowLogRetentionInDays = try(local.config.observability.vpcFlowLogs.retentionInDays, 7)
  metricsGranularity        = try(local.config.observability.metrics.granularity, "1Minute")

  // Security
  kmsDeletionWindowInDays = try(local.config.security.kms.deletionWindowInDays, 30)

  // Networking
  vpcCniMinimumIpTarget = tostring(try(local.config.networking.vpcCni.minimumIpTarget, 30))
  vpcCniWarmIpTarget    = tostring(try(local.config.networking.vpcCni.warmIpTarget, 20))

  // ASG Configuration
  asgHealthCheckGracePeriod = try(local.config.compute.autoscaling.healthCheck.gracePeriod, 300)
  asgCapacityTimeout        = try(local.config.compute.autoscaling.capacityTimeout, "10m")
  asgMinHealthyPercentage   = try(local.config.compute.autoscaling.instanceRefresh.minHealthyPercentage, 90)
  asgInstanceWarmup         = try(local.config.compute.autoscaling.instanceRefresh.instanceWarmup, 300)
  asgCheckpointPercentages  = try(local.config.compute.autoscaling.instanceRefresh.checkpointPercentages, [50, 100])

  // Storage 
  blockVolumeMountDefault = "/dev/sda1" // Default mount point if not specified
  blockVolumeTypeDefault  = "gp3"       // Default volume type if not specified
  blockVolumeSizeDefault  = 50          // Default volume size in GB if not specified

  // Taints
  system_node_taints = "dedicated=system-workload:NoSchedule,dedicated=system-workload:NoExecute"
  worker_node_taints = "dedicated=worker-workload:NoSchedule,dedicated=worker-workload:NoExecute"
  node_group_taints = {
    system : local.system_node_taints
    worker : local.worker_node_taints
  }
}

// =====================================================================================
// Validation 
// =====================================================================================

check "account_matches" {
  assert {
    condition     = local.account == local.config.deployment.account
    error_message = "Invalid AWS account (want: ${local.config.deployment.account}, got: ${local.account})."
  }
}
