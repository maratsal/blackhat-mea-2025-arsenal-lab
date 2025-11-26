module "falco_cloudtrail" {
  source      = "github.com/falcosecurity/falco-aws-terraform//examples/single-account?ref=main"
}

# Falco Helm chart
resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "7.0.1"
  namespace        = "falco"
  create_namespace = true
  wait             = false
  recreate_pods    = true
  timeout          = 600

  values = [
    templatefile("${path.module}/helm-values/values-falco.yaml", {
      aws_region              = var.region
      sqs_name                = "ffc"
      irsa_role_arn           = module.irsa-falco.arn
      cluster_name            = var.cluster_name
      falco_registry_user     = var.falco_registry_user
      falco_registry_host     = var.falco_registry_host
      falco_registry_password = var.falco_registry_password
    })
  ]
}

module "irsa-falco" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.3"

  name             = "irsa-ffc"

  policies = {
    policy = aws_iam_policy.falco.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["falco:falco"]
    }
  }
}

resource "aws_iam_policy" "falco" {
  name = "ffc"
  path = "/"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "S3Access",
        Action = [
          "s3:Get*",
          "s3:List*",
          "s3:Describe*",
          "s3-object-lambda:Get*",
          "s3-object-lambda:List*"
        ]
        Effect   = "Allow"
        Resource = ["*"]
      },
      {
        Sid = "SQSAccess",
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:GetQueueUrl",
          "sqs:DeleteMessage",
          "sqs:ListDeadLetterSourceQueues",
          "sqs:ListQueues",
          "sqs:ListMessageMoveTasks",
          "sqs:ListQueueTags"
        ]
        Effect   = "Allow"
        Resource = ["*"]
      },
      {
        Sid    = "ReadAccessToCloudWatchLogs",
        Effect = "Allow",
        Action = [
          "logs:Describe*",
          "logs:FilterLogEvents",
          "logs:Get*",
          "logs:List*"
        ],
        Resource = [
          "${module.eks.cloudwatch_log_group_arn}:*"
        ]
      }
    ]
  })
}