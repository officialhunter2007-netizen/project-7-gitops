resource "aws_eks_cluster" "main" {
  name     = "${var.pro_name}-cluster"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = aws_subnet.private[*].id
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

resource "aws_eks_fargate_profile" "production" {
    cluster_name = aws_eks_cluster.main.name
    pod_execution_role_arn = aws_iam_role.pod.arn
    fargate_profile_name = "${var.pro_name}-fargate-pod"
    subnet_ids = aws_subnet.private[*].id
    selector {
        namespace = "production"
    }
    depends_on = [
        aws_iam_role_policy_attachment.pod_policy
    ]
}

resource "aws_eks_fargate_profile" "argocd" {
    cluster_name = aws_eks_cluster.main.name
    pod_execution_role_arn = aws_iam_role.pod.arn
    fargate_profile_name = "${var.pro_name}-fargate-argocd"
    subnet_ids = aws_subnet.private[*].id
    selector {
        namespace = "argocd"
    }
    depends_on = [
        aws_iam_role_policy_attachment.pod_policy
    ]
}

resource "aws_eks_fargate_profile" "kube_system" {
    cluster_name = aws_eks_cluster.main.name
    pod_execution_role_arn = aws_iam_role.pod.arn
    fargate_profile_name = "${var.pro_name}-fargate-kube_system"
    subnet_ids = aws_subnet.private[*].id
    selector {
        namespace = "kube-system"
    }
    depends_on = [
        aws_iam_role_policy_attachment.pod_policy
    ]
}