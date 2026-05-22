terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "eu-west-1"
}

variable "your_ip" {
  description = "Your local IP for SSH access. Run: curl ifconfig.me"
  type        = string
}

# ─── VPC ───────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "devops-assignment-vpc" }
}

# ─── Subnets ───────────────────────────────────────────
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = { Name = "devops-assignment-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "devops-assignment-private" }
}

# ─── Internet Gateway ──────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "devops-assignment-igw" }
}

# ─── NAT Gateway (private subnet outbound only) ────────
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "devops-assignment-nat" }
}

# ─── Route Tables ──────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "devops-assignment-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "devops-assignment-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ─── Security Groups ───────────────────────────────────

# Caller VM — public facing API gateway
resource "aws_security_group" "caller" {
  name   = "caller-worker-sg"
  vpc_id = aws_vpc.main.id

  # SSH from your IP only
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.your_ip}/32"]
  }

  # JSON API — open to world
  ingress {
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # iii engine WebSocket — from private subnet only
  ingress {
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "caller-worker-sg" }
}

# Inference VM — private, only reachable from caller VM
resource "aws_security_group" "inference" {
  name   = "inference-worker-sg"
  vpc_id = aws_vpc.main.id

  # SSH via bastion (caller VM) only
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.caller.id]
  }

  # All outbound (for package downloads via NAT)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "inference-worker-sg" }
}

# ─── SSH Key ───────────────────────────────────────────
resource "aws_key_pair" "deployer" {
  key_name   = "devops-assignment-key"
  public_key = file("~/.ssh/devops-assignment.pub")
}

# ─── AMI ───────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ─── EC2 Instances ─────────────────────────────────────

# Caller VM — public subnet
resource "aws_instance" "caller" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.caller.id]
  key_name               = aws_key_pair.deployer.key_name
  root_block_device { volume_size = 20 }
  tags = { Name = "caller-worker-vm" }
}

# Inference VM — private subnet, needs more RAM for model
resource "aws_instance" "inference" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.inference.id]
  key_name               = aws_key_pair.deployer.key_name
  root_block_device { volume_size = 20 }
  tags = { Name = "inference-worker-vm" }
}

# ─── Outputs ───────────────────────────────────────────
output "caller_public_ip" {
  value = aws_instance.caller.public_ip
}

output "inference_private_ip" {
  value = aws_instance.inference.private_ip
}

output "api_endpoint" {
  value = "http://${aws_instance.caller.public_ip}:3111/v1/chat/completions"
}
