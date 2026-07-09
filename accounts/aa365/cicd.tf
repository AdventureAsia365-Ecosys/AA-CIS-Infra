data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "cicd" {
  name = "aa-cis-dev-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:AdventureAsia365-CIS/*:*"
        }
      }
    }]
  })
}

locals {
  cicd_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonRDSFullAccess",
    "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
    "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccess",
    "arn:aws:iam::aws:policy/AmazonSQSFullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess",
    "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess",
  ]
}

resource "aws_iam_role_policy_attachment" "cicd_managed" {
  for_each   = toset(local.cicd_managed_policies)
  role       = aws_iam_role.cicd.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "cicd_inline" {
  name = "CISDevInlinePolicy"
  role = aws_iam_role.cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:TagResource",
        ]
        Resource = "*"
      },
      {
        Sid      = "ELBDescribe"
        Effect   = "Allow"
        Action   = "elasticloadbalancing:Describe*"
        Resource = "*"
      },
      {
        Sid      = "EFSDescribeList"
        Effect   = "Allow"
        Action   = ["elasticfilesystem:Describe*", "elasticfilesystem:List*"]
        Resource = "*"
      },
      {
        Sid      = "AutoscalingDescribeList"
        Effect   = "Allow"
        Action   = ["application-autoscaling:Describe*", "application-autoscaling:List*"]
        Resource = "*"
      },
      {
        Sid    = "IAMRoleManage"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:AttachRolePolicy",
          "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:PassRole", "iam:GetRole", "iam:GetRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:TagRole",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMInstanceProfileManage"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
        ]
        Resource = "*"
      },
    ]
  })
}

output "cicd_role_arn" {
  value = aws_iam_role.cicd.arn
}
