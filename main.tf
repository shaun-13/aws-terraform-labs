terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region  = "us-east-1"
  profile = "sphua-admin-profile"

  default_tags {
    tags = {
      Environment = "aws-labs"
    }
  }
}

resource "aws_vpc" "demo" {
  cidr_block       = "10.192.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "demo"
  }
}

resource "aws_subnet" "publicSubnet" {
  vpc_id                  = aws_vpc.demo.id
  cidr_block              = "10.192.10.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "publicSubnet"
  }
}

resource "aws_subnet" "privateSubnet" {
  vpc_id     = aws_vpc.demo.id
  cidr_block = "10.192.20.0/24"
  tags = {
    Name = "privateSubnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "igw"
  }
}

resource "aws_eip" "nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "NAT EIP"
  }
}
resource "aws_nat_gateway" "natGw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.publicSubnet.id

  tags = {
    Name = "NAT GW"
  }
  # To ensure proper ordering, it is recommended to add an explicit dependency
  # on the Internet Gateway for the VPC.
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "publicRouteTable" {
  vpc_id = aws_vpc.demo.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "Public Route Table"
  }
}
resource "aws_route_table_association" "publicRouteTableAssociation" {
  subnet_id      = aws_subnet.publicSubnet.id
  route_table_id = aws_route_table.publicRouteTable.id
}

resource "aws_route_table" "privateRouteTable" {
  vpc_id = aws_vpc.demo.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natGw.id
  }
  tags = {
    Name = "Private Route Table"
  }
}
resource "aws_route_table_association" "privateRouteTableAssociation" {
  subnet_id      = aws_subnet.privateSubnet.id
  route_table_id = aws_route_table.privateRouteTable.id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_instance" "ubuntu_instance" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro" # Free tier
  subnet_id              = aws_subnet.privateSubnet.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name               = "aws_labs_key"

  user_data = <<-EOF
              #!/bin/bash
              # Update the package list and install Docker
              apt-get update
              apt-get install -y docker.io

              # Start the Docker service
              systemctl start docker
              systemctl enable docker

              # Create a custom index.html file
              echo "<html><body><h1>Shaun Phua</h1></body></html>" > /home/ubuntu/index.html

              # Run the Nginx Docker container with the custom index.html file
              docker run -d -p 80:80 -v /home/ubuntu/index.html:/usr/share/nginx/html/index.html:ro nginx:1.18.0
              EOF

  tags = {
    Name = "Ubuntu Instance"
  }
}

resource "aws_security_group" "instance_sg" {
  name        = "instance_security_group"
  description = "Allow SSH and HTTP access"
  vpc_id      = aws_vpc.demo.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow SSH from any IP
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["118.189.0.0/16", "116.206.0.0/16", "223.25.0.0/16", "10.192.10.0/24"]  # Allow HTTP from specified IP ranges
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Ubuntu Instance Security Group"
  }
}

resource "aws_lb" "nlb" {
  name               = "network-load-balancer"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.publicSubnet.id]

  enable_deletion_protection = false

  tags = {
    Name = "Network Load Balancer"
  }
}

resource "aws_lb_target_group" "nlb_tg_http" {
  name        = "nlb-tg-http"
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "Network Load Balancer Target Group HTTP"
  }
}

resource "aws_lb_target_group" "nlb_tg_ssh" {
  name        = "nlb-tg-ssh"
  port        = 22
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.demo.id

  tags = {
    Name = "Network Load Balancer Target Group SSH"
  }
}

resource "aws_lb_target_group_attachment" "nlb_tg_attachment_http" {
  target_group_arn = aws_lb_target_group.nlb_tg_http.arn
  target_id        = aws_instance.ubuntu_instance.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "nlb_tg_attachment_ssh" {
  target_group_arn = aws_lb_target_group.nlb_tg_ssh.arn
  target_id        = aws_instance.ubuntu_instance.id
  port             = 22
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg_http.arn
  }

  tags = {
    Name = "HTTP Listener"
  }
}

resource "aws_lb_listener" "ssh_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 22
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg_ssh.arn
  }

  tags = {
    Name = "SSH Listener"
  }
}
