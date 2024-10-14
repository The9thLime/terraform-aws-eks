locals {
  # General
  name            = var.cluster_name
  region          = var.region
  tags            = var.tags
  cluster_version = var.kubernetes_version

  # EKS
  oidc_provider            = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  iamproxy-service-account = "${var.cluster_name}-iamproxy-service-account"

  # EKS Access
  eks_access_iam_roles_map = { for role in var.eks_access_account_iam_roles : role.role_name => role }
  eks_access_entries = merge(
    { for role in data.aws_iam_roles.eks_access_iam_roles : role.name_regex => merge(local.eks_access_iam_roles_map[role.name_regex], { "arn" : tolist(role.arns)[0] }) },
    { for role in var.eks_access_cross_account_iam_roles : role.role_name => merge({ "role_name" = role.role_name, "access_scope" = role.access_scope, "policy_name" = role.policy_name, "arn" = role.prefix != null ? format("arn:aws:iam::%s:role/%s/%s", role.account, role.prefix, role.role_name) : format("arn:aws:iam::%s:role/%s", role.account, role.role_name) }) }
  )

  # EKS Node Groups
  default_critical_addon_nodegroup = {
    instance_types = var.default_critical_addon_node_group_instance_types
    ami_type       = "AL2023_ARM_64_STANDARD"
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 100
          volume_type           = "gp3"
          encrypted             = true
          delete_on_termination = true
          kms_key_id            = var.default_critical_nodegroup_kms_key_id
        }
      }
    }
    min_size     = 3
    max_size     = 3
    desired_size = 3
    labels = {
      CriticalAddonsOnly = "true"
    }
    taints = {
      addons = {
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      },
    }
  }

  eks_managed_node_groups = merge(
    { for k, v in var.eks_managed_node_groups : "${var.cluster_name}-${k}" => v },
    var.create_default_critical_addon_node_group ? {
      "truemark-system" = local.default_critical_addon_nodegroup
    } : {}
  )

  # VPC
  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  # GitOps Addons URL
  gitops_addons_url      = "${var.gitops_addons_org}/${var.gitops_addons_repo}"
  gitops_addons_basepath = var.gitops_addons_basepath
  gitops_addons_path     = var.gitops_addons_path
  gitops_addons_revision = var.gitops_addons_revision

  # GitOps Workload URL
  gitops_workload_url      = "${var.gitops_workload_org}/${var.gitops_workload_repo}"
  gitops_workload_basepath = var.gitops_workload_basepath
  gitops_workload_path     = var.gitops_workload_path
  gitops_workload_revision = var.gitops_workload_revision

  # GitOps Bridge AWS Addons
  aws_addons = {
    enable_cert_manager                 = try(var.addons.enable_cert_manager, false)
    enable_aws_cloudwatch_metrics       = try(var.addons.enable_aws_cloudwatch_metrics, false)
    enable_cluster_autoscaler           = try(var.addons.enable_cluster_autoscaler, false)
    enable_external_dns                 = try(var.addons.enable_external_dns, false)
    enable_external_secrets             = try(var.addons.enable_external_secrets, false)
    enable_aws_load_balancer_controller = try(var.addons.enable_aws_load_balancer_controller, false)
    enable_karpenter                    = try(var.addons.enable_karpenter, false)
    enable_aws_ebs_csi_resources        = try(var.addons.enable_aws_ebs_csi_resources, false)
  }

  # GitOps Bridge OSS Addons
  oss_addons = {
    enable_argocd                 = try(var.addons.enable_argocd, true)
    enable_istio_base             = try(var.addons.enable_istio_base, false)
    enable_istio_discovery        = try(var.addons.enable_istio_discovery, false)
    enable_istio_internal_gateway = try(var.addons.enable_istio_internal_gateway, false)
    enable_istio_external_gateway = try(var.addons.enable_istio_internal_gateway, false)
    enable_kube_prometheus_stack  = try(var.addons.enable_kube_prometheus_stack, false)
    enable_metrics_server         = try(var.addons.enable_metrics_server, false)
    enable_vpa                    = try(var.addons.enable_vpa, false)
  }

  addons = merge(
    local.aws_addons,
    local.oss_addons,
    { kubernetes_version = local.cluster_version },
    { aws_cluster_name = module.eks.cluster_name }
  )

  # GitOps Bridge Addons Metadata
  addons_metadata = merge(
    module.eks_blueprints_addons.gitops_metadata,
    {
      aws_cluster_name = module.eks.cluster_name
      aws_region       = local.region
      aws_account_id   = data.aws_caller_identity.current.account_id
      aws_vpc_id       = var.create_vpc ? module.vpc.vpc_id : var.vpc_id
    },
    {
      istio_public_subnet_ids = data.aws_subnets.istio_private_subnet_ids
      istio_private_subnets_ids = data.aws_subnets.istio_private_subnet_ids
    },
    {
      addons_repo_url      = local.gitops_addons_url
      addons_repo_basepath = local.gitops_addons_basepath
      addons_repo_path     = local.gitops_addons_path
      addons_repo_revision = local.gitops_addons_revision
    },
    {
      workload_repo_url      = local.gitops_workload_url
      workload_repo_basepath = local.gitops_workload_basepath
      workload_repo_path     = local.gitops_workload_path
      workload_repo_revision = local.gitops_workload_revision
    }
  )

  argocd_apps = {
    addons    = file("${path.module}/bootstrap/addons.yaml")
    workloads = file("${path.module}/bootstrap/workloads.yaml")
  }
}

################################################################################
# GitOps Bridge: Bootstrap
################################################################################
module "gitops_bridge_bootstrap" {
  source = "gitops-bridge-dev/gitops-bridge/helm"

  # Metadata and list of addons for GitOps bridge
  cluster = {
    # Cluster name
    name = local.name
    # Metadata is passed to a secret as annotations
    metadata = local.addons_metadata
    # Addons are created usign
    addons = local.addons
    # Environment
    environment = local.environment
  }

  # Argo CD apps to deploy
  apps = local.argocd_apps
}

################################################################################
# EKS Blueprints Addons
################################################################################
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  # Cluster info
  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # GitOps bridge creates resources in this module's stead
  create_kubernetes_resources = false

  # EKS Blueprints Addons
  enable_cert_manager                 = local.aws_addons.enable_cert_manager
  enable_aws_cloudwatch_metrics       = local.aws_addons.enable_aws_cloudwatch_metrics
  enable_cluster_autoscaler           = local.aws_addons.enable_cluster_autoscaler
  enable_external_dns                 = local.aws_addons.enable_external_dns
  enable_external_secrets             = local.aws_addons.enable_external_secrets
  enable_aws_load_balancer_controller = local.aws_addons.enable_aws_load_balancer_controller
  enable_karpenter                    = local.aws_addons.enable_karpenter

  tags = local.tags
}

################################################################################
# EKS Cluster
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.13"

  # General EKS configuration
  cluster_name                    = local.name
  cluster_version                 = local.cluster_version
  cluster_endpoint_private_access = var.cluster_endpoint_private_access
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access

  # VPC configuration
  vpc_id     = var.create_vpc ? module.vpc.vpc_id : var.vpc_id
  subnet_ids = var.create_vpc ? module.vpc.private_subnets : var.vpc_id

  # Node Groups definition
  eks_managed_node_groups = local.eks_managed_node_groups

  # CloudWatch Configuration
  create_cloudwatch_log_group = var.create_cloudwatch_log_group
  cluster_enabled_log_types   = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Security Groups definition
  cluster_security_group_additional_rules = var.cluster_security_group_additional_rules
  node_security_group_additional_rules    = var.node_security_group_additional_rules
  cluster_additional_security_group_ids   = var.cluster_additional_security_group_ids

  # KMS Configuration
  kms_key_users  = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  kms_key_owners = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]

  # EKS Addons
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      most_recent              = true
      before_compute           = var.vpc_cni_before_compute
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
  }
  tags = local.tags
}

# IRSAs for EKS addons
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.20"
  role_name_prefix      = "${module.eks.cluster_name}-ebs-csi-"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

module "vpc_cni_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name             = "${var.cluster_name}-AmazonEKSVPCCNIRole"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
  tags = var.tags
}

# EKS Access Configuration
resource "aws_eks_access_entry" "access_entries" {
  for_each      = local.eks_access_entries
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.arn
  user_name     = "${each.key}:{{SessionName}}"
}

resource "aws_eks_access_policy_association" "access_policy_associations" {
  for_each      = local.eks_access_entries
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/${each.value.policy_name}"
  principal_arn = each.value.arn
  dynamic "access_scope" {
    for_each = each.value.access_scope != null ? [each.value.access_scope] : []
    content {
      type       = access_scope.value.type
      namespaces = access_scope.value.namespaces != null ? access_scope.value.namespaces : []
    }
  }
}
################################################################################
# Supporting Resources
################################################################################
module "vpc" {
  count              = var.create_vpc ? 1 : 0
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~> 5.0"
  name               = local.name
  cidr               = local.vpc_cidr
  azs                = local.azs
  private_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  enable_nat_gateway = true
  single_nat_gateway = true
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
  tags = local.tags
}