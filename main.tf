provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

locals {
  vpc_name = "${var.cluster_name}-vpc-${random_string.suffix.result}"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = local.vpc_name

  cidr = var.vpc_cidr
  azs  = local.azs
  private_subnets = var.vpc_private_subnets
  public_subnets  = var.vpc_public_subnets

  enable_nat_gateway   = false
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_flow_log = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_cloudwatch_log_group_retention_in_days = 7
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = 1
  }
}

module "nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.4.0"

  name               = "${local.vpc_name}-nat"
  vpc_id             = module.vpc.vpc_id
  subnet_id          = module.vpc.public_subnets[0]
  update_route_tables = true
  route_tables_ids    = { for idx, id in module.vpc.private_route_table_ids : tostring(idx) => id }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.8.0"

  name    = var.cluster_name
  kubernetes_version = var.eks_cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  endpoint_public_access = true
  create_cloudwatch_log_group    = true
  cloudwatch_log_group_retention_in_days = 7

  # This is crucial - it grants admin permissions to whoever is creating the cluster
  enable_cluster_creator_admin_permissions = true

  # EKS Addons
  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    metrics-server = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  access_entries = {
    marat-admin = {
      principal_arn = "arn:aws:iam::876379898882:root"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type       = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = var.eks_managed_node_groups

  # additional node security group rules to allow access from control plane to Sysdig Admission Controller webhook port
  node_security_group_additional_rules = {
    ingress_allow_access_from_control_plane_to_sysdig_ac = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 5000
      to_port                       = 5000
      source_cluster_security_group = true
      description                   = "Allow access from control plane to webhook port of Sysdig Admission Controller"
    }
    ingress_allow_access_from_control_plane_to_sysdig_kspm_ac = {
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 7443
      to_port                       = 7443
      source_cluster_security_group = true
      description                   = "Allow access from control plane to webhook port of Sysdig KSPM Admission Controller"
    }
  }
  # depends_on = [module.nat, module.vpc]
  # depends_on = [module.nat,resource.aws_route.private_default_nat,resource.aws_eip.nat, module.vpc]
}

data "aws_iam_policy" "efs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

module "irsa-efs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.3"

  name             = "AmazonEKSTFEFSCSIRole-${module.eks.cluster_name}"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "efs-csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  addon_version               = "v2.1.13-eksbuild.1"
  service_account_role_arn    = module.irsa-efs-csi.arn
  resolve_conflicts_on_update = "OVERWRITE"
  tags = {
    "eks_addon" = "efs-csi"
    "terraform" = "true"
  }
}

# EFS file system for EKS
resource "aws_efs_file_system" "eks" {
  creation_token = "eks-efs-${random_string.suffix.result}"
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  tags = {
    Name = "eks-efs-${random_string.suffix.result}"
  }
}

# EFS Security Group
resource "aws_security_group" "efs" {
  name        = "efs-sg-${var.region}"
  description = "Allow NFS from EKS nodes"
  vpc_id      = module.vpc.vpc_id
  tags = {
    Name = "efs-sg-${var.region}"
  }
}

# EFS Mount Targets for each private subnet
resource "aws_efs_mount_target" "eks" {
  for_each = { for idx, subnet in module.vpc.private_subnets : idx => subnet }
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Allow NFS from EKS nodes to EFS
resource "aws_security_group_rule" "efs_nfs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.efs.id
  source_security_group_id = module.eks.cluster_primary_security_group_id
}