resource "aws_iam_role" "cluster" {
  name = "eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "eks.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "pod" {
    name = "pod_role"
    assume_role_policy = jsonencode(
        {
            Version = "2012-10-17"
            Statement = [
                {
                    Effect = "Allow"

                    Principal = {
                        Service = "eks-fargate-pods.amazonaws.com"
                    }
                    Action = "sts:AssumeRole"
                }
            ]
        }
    )
}

resource "aws_iam_role_policy_attachment" "pod_policy" {
    role = aws_iam_role.pod.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

resource "aws_iam_openid_connect_provider" "github" {
    url = "https://token.actions.githubusercontent.com"

    client_id_list = [
        "sts.amazonaws.com"
    ]
    thumbprint_list = [
        "6938fd4d98bab03faadb97b34396831e3780aea1"
    ]
}

resource "aws_iam_role" "github" {
    name = "github-actions-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"

        Statement = [
            {
                Effect = "Allow"

                Principal = {
                    Federated = aws_iam_openid_connect_provider.github.arn
                }

                Action = "sts:AssumeRoleWithWebIdentity"

                Condition = {
                    StringLike = {
                        "token.actions.githubusercontent.com:sub" = "repo:officialhunter2007-netizen@223306401/project-7-app@1344159111:*"
                    }
                }
            }
        ]
    })
}

resource "aws_iam_role_policy" "github_policy" {
    role = aws_iam_role.github.name
    name = "${var.pro_name}-github-policy"

    policy = jsonencode({
        Version = "2012-10-17"

        Statement = [
            {
                Effect = "Allow"

                Action = "ecr:GetAuthorizationToken"

                Resource = "*"
            },

            {
                Effect = "Allow"

                Action = [
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload",
                    "ecr:PutImage"
                ]

                Resource = aws_ecr_repository.rep1.arn
            }
        ]
    })
}
