terraform {
  required_version = ">= 1.5.0"
  
  # Tracks cluster states securely within AWS
  backend "s3" {
    bucket = "k8s-learning-s3-bucket-manju" 
    key    = "eks/production.tfstate"
    region = "eu-north-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ==============================================================================
# 1. NETWORKING LAYER (RAW VPC, SUBNETS, INTERNET & NAT GATEWAYS)
# ==============================================================================

# Core VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "native-production-vpc"
  }
}

# Internet Gateway for Public Internet Access
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "native-igw"
  }
}

# Public Subnets (For Load Balancers)
resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.101.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "native-public-1a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.102.0/24"
  availability_zone = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "native-public-1b"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets (Where EC2 Worker Nodes safely sit)
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name                              = "native-private-1a"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name                              = "native-private-1b"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
}

# NAT Gateway so private EC2 nodes can safely talk to the internet (e.g. pull Docker images)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id

  tags = {
    Name = "native-nat-gw"
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/8"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Route Table for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

# Route Table Associations
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}


# ==============================================================================
# 2. SECURITY LAYER (IAM ROLES FOR EKS MASTER CONTROL PLANE)
# ==============================================================================

# IAM Role for EKS Master
resource "aws_iam_role" "eks_master_role" {
  name = "native-eks-master-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "://amazonaws.com"
      }
    }]
  })
}

# Attach core cluster policy to the Master Role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_master_role.name
}


# ==============================================================================
# 3. KUBERNETES CONTROL PLANE (THE EKS MASTER CLUSTER RESOUCE)
# ==============================================================================

resource "aws_eks_cluster" "core_cluster" {
  name     = "production-core-cluster"
  role_arn = aws_iam_role.eks_master_role.arn

  vpc_config {
    endpoint_public_access = true
    subnet_ids = [
      aws_subnet.public_1.id,
      aws_subnet.public_2.id,
      aws_subnet.private_1.id,
      aws_subnet.private_2.id
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}


# ==============================================================================
# 4. DATA PLANE ACCESS & WORKER NODES (IAM & EC2 NODE GROUP RESOUCES)
# ==============================================================================

# IAM Role for EC2 Worker Nodes
resource "aws_iam_role" "eks_nodes_role" {
  name = "native-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "://amazonaws.com"
      }
    }]
  })
}

# Attach worker node policies so they can talk to the Master and pull images
resource "aws_iam_role_policy_attachment" "amazon_eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes_role.name
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes_role.name
}

resource "aws_iam_role_policy_attachment" "amazon_ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes_role.name
}

# The actual EC2 Auto Scaling Node Group running our app pods
resource "aws_eks_node_group" "compute_nodes" {
  cluster_name    = aws_eks_cluster.core_cluster.name
  node_group_name = "compute-nodes"
  node_role_arn   = aws_iam_role.eks_nodes_role.arn
  
  # Run worker nodes safely isolated inside the private subnets
  subnet_ids      = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.amazon_eks_worker_node_policy,
    aws_iam_role_policy_attachment.amazon_eks_cni_policy,
    aws_iam_role_policy_attachment.amazon_ecr_read_only
  ]
}

# Enable direct cluster admin entries for the creator role identity
resource "aws_eks_access_entry" "creator_access" {
  cluster_name  = aws_eks_cluster.core_cluster.name
  principal_arn = data.aws_arn.current_identity.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "creator_admin" {
  cluster_name  = aws_eks_cluster.core_cluster.name
  policy_arn    = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
  principal_arn = data.aws_arn.current_identity.arn

  access_scope {
    type = "cluster"
  }
}

data "aws_caller_identity" "current" {}

data "aws_arn" "current_identity" {
  arn = data.aws_caller_identity.current.arn
}


# ==============================================================================
# 5. CONTAINER REGISTRY (ECR RESOURCE)
# ==============================================================================

resource "aws_ecr_repository" "app_repo" {
  name                 = "my-custom-node-app"
  image_tag_mutability = "MUTABLE"
  force_delete        = true
}
