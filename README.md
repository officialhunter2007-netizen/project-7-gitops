# Project 7 — GitOps on Kubernetes with EKS and ArgoCD

## Overview

This project builds a production-grade GitOps pipeline on Kubernetes using Amazon EKS with Fargate, ArgoCD, and GitHub Actions. It extends Project 6 (ECS-based GitOps) by replacing ECS with Kubernetes, introducing ArgoCD as the GitOps engine, and implementing advanced Kubernetes health checking patterns that ECS does not support.

The application never gets deployed directly from the pipeline. GitHub Actions builds and pushes the image to ECR, then updates the image tag in a separate GitOps repository. ArgoCD detects the change in Git and syncs the cluster automatically. The pipeline never touches the cluster.

## Architecture

Two GitHub repositories serve two separate purposes:

**project-7-app** contains the Flask application, Dockerfile, tests, and GitHub Actions pipeline. Every push to main triggers a build, security scan, and image push to ECR. The pipeline then commits the new image tag to project-7-gitops.

**project-7-gitops** contains Terraform infrastructure and Kubernetes manifests. ArgoCD watches the k8s/production directory and syncs any changes to the EKS cluster automatically.

Three systems own three separate responsibilities:

- Terraform owns AWS infrastructure: VPC, EKS, ECR, IAM, subnets, NAT Gateway
- GitHub Actions owns the build pipeline: lint, test, build, scan, push
- ArgoCD owns cluster state: it continuously reconciles what is in Git with what is running

This separation means infrastructure changes, application changes, and deployment state are never mixed together.

## Why Kubernetes Over ECS

In Project 6, ECS worked well for a single service. But ECS does not scale cleanly to multiple services. Each service requires its own task definition, ECS service, target group, and ALB listener rule. Managing 50 microservices means 50 of each of those resources with no unified control plane.

Kubernetes provides a single API for all workloads. One cluster, one control plane, unlimited services. The Kubernetes resource model, Deployment, Service, Ingress, HPA, ConfigMap, is consistent regardless of how many services run inside the cluster.

EKS on Fargate preserves the same serverless cost model from Project 6. There are no EC2 nodes to manage, patch, or right-size. AWS provisions compute invisibly when pods are scheduled and removes it when pods terminate.

## Application

The Flask application exposes four endpoints:

- `GET /` returns project name, status, and engineer name as JSON
- `GET /health` returns a general health status
- `GET /live` is the liveness probe endpoint. Kubernetes restarts the pod if this fails
- `GET /ready` is the readiness probe endpoint. Kubernetes removes the pod from the Service rotation if this fails without restarting it

The liveness and readiness probes serve different purposes. A failing liveness probe means the container is fundamentally broken and needs to be replaced. A failing readiness probe means the container is alive but not ready to serve traffic, for example during startup initialization. This distinction does not exist in ECS, which has only one health check that always results in task replacement.

The readiness endpoint uses a background thread that sets a global variable to True after 20 seconds. This simulates a startup initialization period and prevents Kubernetes from sending traffic to the pod before it is ready.

## Infrastructure

### VPC

- CIDR: 10.0.0.0/16
- 2 public subnets across eu-west-1a and eu-west-1b for the ALB
- 2 private subnets across eu-west-1a and eu-west-1b for EKS Fargate nodes
- Internet Gateway for public subnet outbound traffic
- NAT Gateway in the first public subnet for private subnet outbound traffic
- Public subnets tagged with `kubernetes.io/role/elb: 1` for ALB discovery
- Private subnets tagged with `kubernetes.io/role/internal-elb: 1` for internal LB discovery
- Both subnet types tagged with `kubernetes.io/cluster/project-7-eks-cluster: shared` so the Load Balancer Controller can discover them

### EKS

- EKS cluster running Kubernetes in eu-west-1
- Three Fargate profiles covering production, argocd, and kube-system namespaces
- Each pod runs on its own dedicated Fargate instance
- Each pod receives its own IP address from the VPC subnet via the AWS VPC CNI plugin
- CoreDNS runs in kube-system namespace providing internal cluster DNS

### ECR

- Repository: project-7-eks-ecr
- Image tags are immutable to prevent overwriting existing images
- Scan on push enabled for every image
- Lifecycle policy retains the last 10 images

### IAM

- EKS cluster role: allows the EKS control plane to manage AWS resources
- EKS Fargate pod execution role: allows Fargate nodes to pull from ECR and write logs to CloudWatch
- GitHub Actions role: OIDC-based, allows the pipeline to authenticate without static credentials
- AWS Load Balancer Controller role: IRSA-based, allows the controller pods to create and manage ALBs

### AWS Load Balancer Controller

The AWS Load Balancer Controller runs inside the cluster in kube-system and watches for Ingress resources. When it detects an Ingress with the `alb` annotation it provisions an internet-facing ALB, creates a target group pointing directly to pod IPs, and creates an HTTP listener. It uses IRSA to authenticate with AWS, meaning it assumes an IAM role via the EKS OIDC provider without any static credentials.

## Kubernetes Manifests

All manifests live in k8s/production and are managed by ArgoCD.

**deployment.yaml** runs 2 replicas of the Flask container with 256m CPU and 512Mi memory requests. It defines separate liveness and readiness probes on /live and /ready endpoints. The PORT environment variable is injected from the ConfigMap.

**service.yaml** provides a stable ClusterIP that routes traffic from the ALB to the current healthy pods. Pod IPs change every time a pod is recreated. The Service IP never changes.

**ingress.yaml** tells the AWS Load Balancer Controller to create an internet-facing ALB. The `alb.ingress.kubernetes.io/target-type: ip` annotation routes traffic directly to pod IPs, which is required for Fargate since there are no EC2 node IPs.

**hpa.yaml** automatically scales replicas between 2 and 5 based on CPU utilization. When average CPU exceeds 70 percent, new pods are added. Each new pod gets its own Fargate instance provisioned automatically.

**configmap.yaml** stores the PORT configuration value separately from the Deployment. Configuration changes do not require image rebuilds.

## GitOps Flow

1. Developer pushes code to project-7-app main branch
2. GitHub Actions runs lint, tests, Docker build, Trivy security scan
3. GitHub Actions pushes image to ECR tagged with the Git commit SHA
4. GitHub Actions updates the image field in k8s/production/deployment.yaml in project-7-gitops
5. ArgoCD detects the change in Git within minutes
6. ArgoCD applies the updated Deployment to the cluster
7. Kubernetes performs a rolling update, starting new pods before terminating old ones
8. The cluster state now matches Git exactly

The cluster is never touched directly by the pipeline. If the pipeline fails after pushing the image but before updating Git, the cluster continues running the previous version unaffected.

## IRSA: IAM Roles for Service Accounts

The AWS Load Balancer Controller needs AWS credentials to create ALBs. Instead of storing static credentials as Kubernetes secrets, IRSA links the controller's Kubernetes service account to an IAM role via the EKS OIDC provider.

When the controller pod starts, the EKS Pod Identity Webhook injects a signed JWT token and two environment variables into the pod: AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE. The AWS SDK inside the pod reads these automatically, calls sts:AssumeRoleWithWebIdentity with the JWT token, and receives temporary credentials valid for one hour. The credentials are automatically rotated. No static keys exist anywhere.

## Real Bugs Debugged

**Bug 1: CoreDNS pods stuck in Pending state**
CoreDNS runs in kube-system but the initial Fargate profiles only covered production and argocd namespaces. Kubernetes had no compute available for kube-system pods so they stayed Pending forever. ArgoCD could not connect to the repo server because internal DNS resolution was broken. Fixed by adding a third Fargate profile for kube-system and restarting the CoreDNS deployment.

**Bug 2: Subnet tags referencing wrong cluster name**
The variables.tf cluster variable default was project-7-cluster but the actual EKS cluster name was project-7-eks-cluster. The subnet tags said kubernetes.io/cluster/project-7-cluster but the Load Balancer Controller looked for kubernetes.io/cluster/project-7-eks-cluster. The controller found the subnets but rejected them as belonging to a different cluster. Fixed by correcting the variable default and running terraform apply to update the tags.

**Bug 3: Load Balancer Controller CrashLoopBackOff on Fargate**
The controller tried to auto-discover the VPC ID from EC2 instance metadata. This works on EC2 nodes but Fargate does not expose the instance metadata service to pods. The controller crashed on every startup attempt. Fixed by explicitly passing the VPC ID to the Helm installation with --set vpcId.

**Bug 4: Missing IAM permission for DescribeListenerAttributes**
The official IAM policy document for the Load Balancer Controller was missing the elasticloadbalancing:DescribeListenerAttributes action which was added in a newer version of the controller. The ALB, target group, and listener were all created successfully but the final reconciliation step failed with AccessDenied. Fixed by adding the missing action to lbc-policy.json and running terraform apply.

**Bug 5: Trivy action supply chain compromise**
The aquasecurity/trivy-action GitHub Action was compromised in March 2026. Tags 0.0.1 through 0.34.2 were replaced with credential-stealing malware that exfiltrated secrets to an attacker-controlled domain. Using the compromised version would have exposed AWS credentials and GitHub tokens. Fixed by pinning to v0.35.0 which uses new immutable tags pointing to verified legitimate commits.

**Bug 6: Flask version 3.3.5 does not exist**
The requirements.txt specified flask==3.3.5 but the highest available version on PyPI is 3.1.3. The Docker build failed during pip install. Fixed by correcting the version to flask==3.1.3.

## Comparison to Project 6

| Concern | Project 6 (ECS) | Project 7 (EKS) |
|---|---|---|
| Orchestrator | ECS | Kubernetes |
| Deployment engine | GitHub Actions pushes directly | ArgoCD syncs from Git |
| Health checks | One check per target group | Separate liveness and readiness probes |
| Scaling | Manual desired count | HorizontalPodAutoscaler |
| Node model | Fargate tasks | Fargate pods, one per pod |
| Pod credentials | Task execution role | IRSA via EKS OIDC |
| Load balancer provisioning | Terraform | AWS Load Balancer Controller |
| Configuration | Task definition environment | ConfigMap |

## Live Infrastructure

- ALB: k8s-producti-flaskapp-9c899e55a7-647197149.eu-west-1.elb.amazonaws.com
- ECR: 485141927791.dkr.ecr.eu-west-1.amazonaws.com/project-7-eks-ecr
- EKS Cluster: project-7-eks-cluster
- Region: eu-west-1
- AWS Account: 485141927791

