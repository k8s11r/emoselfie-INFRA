provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project     = var.project_name
        Environment = var.environment
        ManagedBy   = "Terraform"
      },
      var.additional_tags,
    )
  }
}

locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  cluster_token = coalesce(var.cluster_token, random_password.cluster_token.result)
  subnet_ids    = sort(data.aws_subnets.default.ids)
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_key_pair" "selected" {
  key_name = var.key_name
}

resource "random_password" "cluster_token" {
  length  = 48
  special = false
}

resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-k3s-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name_prefix}-k3s-node"
  role = aws_iam_role.node.name
}

resource "aws_security_group" "k3s" {
  name        = "${local.name_prefix}-k3s"
  description = "Network access for the ${local.name_prefix} k3s cluster"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${local.name_prefix}-k3s"
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_internal" {
  security_group_id            = aws_security_group.k3s.id
  referenced_security_group_id = aws_security_group.k3s.id
  ip_protocol                  = "-1"
  description                  = "All traffic between k3s nodes"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the administrator IP"
}

resource "aws_vpc_security_group_ingress_rule" "kubernetes_api" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API from the administrator IP"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id            = aws_security_group.k3s.id
  referenced_security_group_id = aws_security_group.load_balancer.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP from the Application Load Balancer"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound internet and AWS API access"
}

# 인스턴스를 중지했다 켜면 자동 할당 공인 IP가 바뀐다. 그러면 k3s가 부팅 때
# 인증서에 박아 둔 주소와 달라져 kubectl이 TLS 검증에서 막히고, kubeconfig와
# Ansible 인벤토리도 함께 틀어진다. server만 주소를 고정해 그 연쇄를 끊는다.
# agent는 공인 IP로 통신하지 않으므로 필요 없다.
resource "aws_eip" "server" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-k3s-server"
  }
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}

resource "aws_instance" "server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  associate_public_ip_address = true
  key_name                    = data.aws_key_pair.selected.key_name
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name

  # 메타데이터로 부팅 당시의 주소를 읽지 않고 EIP를 직접 넣는다. 연결은 인스턴스
  # 생성 뒤에 이뤄지므로, 메타데이터를 읽으면 아직 자동 할당 주소가 보여 인증서에
  # 그 값이 박힌다.
  user_data = templatefile("${path.module}/user-data-server.sh.tftpl", {
    cluster_token    = local.cluster_token
    k3s_channel      = var.k3s_channel
    k3s_version      = var.k3s_version == null ? "" : var.k3s_version
    server_public_ip = aws_eip.server.public_ip
  })

  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name       = "${local.name_prefix}-k3s-server"
    K3sRole    = "server"
    K3sCluster = local.name_prefix
  }

  lifecycle {
    precondition {
      condition     = length(local.subnet_ids) >= 3
      error_message = "The selected default VPC must have default subnets in at least three availability zones."
    }
  }
}

resource "aws_instance" "agent" {
  count = 2

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[count.index + 1]
  associate_public_ip_address = true
  key_name                    = data.aws_key_pair.selected.key_name
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name

  user_data = templatefile("${path.module}/user-data-agent.sh.tftpl", {
    cluster_token     = local.cluster_token
    k3s_channel       = var.k3s_channel
    k3s_version       = var.k3s_version == null ? "" : var.k3s_version
    server_private_ip = aws_instance.server.private_ip
  })

  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name       = "${local.name_prefix}-k3s-agent-${count.index + 1}"
    K3sRole    = "agent"
    K3sCluster = local.name_prefix
  }
}
