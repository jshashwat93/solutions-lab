### Service Provider 

# Create provider VPC
resource "aws_vpc" "provider" {
  cidr_block = "10.0.0.0/16"
  region = var.region
  enable_dns_hostnames = true
  tags = {
    Name = "provider-vpc"
  }
}

# Fetch online AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Create provider subnet
resource "aws_subnet" "provider" {
  vpc_id     = aws_vpc.provider.id
  cidr_block = cidrsubnet(aws_vpc.provider.cidr_block, 4, 0)
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = {
    Name = "provider-subnet"
  }
}

# Create provider internet gateway
resource "aws_internet_gateway" "provider" {
  vpc_id = aws_vpc.provider.id

  tags = {
    Name = "provider-internet-gateway"
  }
}

# Create provider route table
resource "aws_route_table" "provider" {
  vpc_id = aws_vpc.provider.id
  tags = {
    Name = "provider-rt"
  }
}

# Create provider route table association
resource "aws_route_table_association" "provider" {
  subnet_id      = aws_subnet.provider.id
  route_table_id = aws_route_table.provider.id
}

# Create provider route
resource "aws_route" "provider" {
  route_table_id = aws_route_table.provider.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.provider.id
}

# Create random suffix for provider instance SSM role
resource "random_pet" "provider" {
  length = 5
}

# Create IAM role for SSM on provider instance
resource "aws_iam_role" "provider" {
  name = "SSMRole-${random_pet.provider.id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
  tags = {
    Name = "provider-ssm-iam-role"
  }
}

# Attach SSM policy to IAM role for provider
resource "aws_iam_role_policy_attachment" "provider" {
  role       = aws_iam_role.provider.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
  
}

# AWS instance profile for provider 
resource "aws_iam_instance_profile" "provider" {
  name = "SSMInstanceProfile-${random_pet.provider.id}"
  role = aws_iam_role.provider.name
  tags = {
    Name = "provider-iam-instance-profile"
  }
}

# Create a security group for provider EC2 instance
resource "aws_security_group" "provider" {
  name        = "service-sg"
  description = "Security Group For Service Instance"
  vpc_id      = aws_vpc.provider.id

  ingress {
    description = "Allow 80 for Provider VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "provider-instance-security-group"
  }
}

# Fetch latest AMI for Amazon Linux
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# Create EC2 instance for provider nginx service
resource "aws_instance" "provider" {
  ami                     = data.aws_ssm_parameter.al2023.value
  instance_type           = "t3.micro"
  vpc_security_group_ids  = [aws_security_group.provider.id]
  subnet_id               = aws_subnet.provider.id
  associate_public_ip_address = true
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nginx
              service nginx start
              chkconfig nginx on
              echo "<h1>Hello from the PrivateLink Service!</h1>" > /usr/share/nginx/html/index.html
              EOF

  iam_instance_profile = aws_iam_instance_profile.provider.id
  tags = {
    Name = "provider-instance"
  }
}

# Create provider network load balancer
resource "aws_lb" "provider" {
  name               = "privatelink-nlb"
  internal           = true
  load_balancer_type = "network"

  subnets         = [aws_subnet.provider.id]

  tags = {
    Name = "provider-nlb"
  }
}

# Create provider target group for network load balancer
resource "aws_lb_target_group" "provider" {
  name     = "service-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.provider.id
  target_type = "instance"

  health_check {
  protocol            = "HTTP" 
  path                = "/"
  matcher             = "200-399"
  }

  tags = {
    Name = "provider-nlb-target-group"
  }
}

# Create listener port for network load balancer
resource "aws_lb_listener" "provider" {
  load_balancer_arn = aws_lb.provider.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.provider.arn
  }
  tags = {
    Name = "provider-nlb-listener"
  }
}

# Create target group for network load balancer
resource "aws_lb_target_group_attachment" "provider" {
  target_group_arn = aws_lb_target_group.provider.arn
  target_id        = aws_instance.provider.id
  port             = 80
}

# Create privatelink service for providers
resource "aws_vpc_endpoint_service" "provider" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.provider.arn]
  tags = {
    Name = "provider-vpc-endpoint-service"
  }
}

### Service Consumer 

# Create consumer VPC
resource "aws_vpc" "consumer" {
  cidr_block = "172.16.0.0/16"
  instance_tenancy = "default"
  region = var.region
  enable_dns_hostnames = true
  tags = {
    Name = "consumer-vpc"
  }
}

# Create consumer subnet
resource "aws_subnet" "consumer" {
  vpc_id     = aws_vpc.consumer.id
  cidr_block = cidrsubnet(aws_vpc.consumer.cidr_block, 4, 0)  # First /20 subnet
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = {
    Name = "consumer-subnet"
  }
}

# Create consumer internet gateway
resource "aws_internet_gateway" "consumer" {
  vpc_id = aws_vpc.consumer.id

  tags = {
    Name = "consumer-internet-gateway"
  }
}

# Create consumer route table
resource "aws_route_table" "consumer" {
  vpc_id = aws_vpc.consumer.id
  tags = {
    Name = "consumer-rt"
  }
}

# Create consumer route table association
resource "aws_route_table_association" "consumer" {
  subnet_id      = aws_subnet.consumer.id
  route_table_id = aws_route_table.consumer.id
}

# Create consumer route
resource "aws_route" "consumer" {
  route_table_id = aws_route_table.consumer.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.consumer.id
}

# Create random suffix for consumer instance SSM role
resource "random_pet" "consumer" {
  length = 5
}

# Create IAM role for SSM on consumer instance
resource "aws_iam_role" "consumer" {
  name = "SSMRole-${random_pet.consumer.id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
  tags = {
    Name = "consumer-ssm-iam-role"
  }
}

# Attach SSM policy to IAM role for consumer
resource "aws_iam_role_policy_attachment" "consumer" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

# AWS instance profile for consumer 
resource "aws_iam_instance_profile" "consumer" {
  name = "SSMInstanceProfile-${random_pet.consumer.id}"
  role = aws_iam_role.consumer.name
  tags = {
    Name = "consumer-iam-instance-profile"
  }
}

# Create a security group for consumer EC2 instance
resource "aws_security_group" "consumer" {
  name        = "consumer-sg"
  description = "Security Group For Consumer Instance"
  vpc_id      = aws_vpc.consumer.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "consumer-instance-security-group"
  }
}

# Create EC2 instance for consumer nginx service
resource "aws_instance" "consumer" {
  ami                     = data.aws_ssm_parameter.al2023.value
  instance_type           = "t3.micro"
  vpc_security_group_ids  = [aws_security_group.consumer.id]
  subnet_id               = aws_subnet.consumer.id
  associate_public_ip_address = true
  iam_instance_profile = aws_iam_instance_profile.consumer.id
  tags = {
    Name = "consumer-instance"
  }
}

# Create security group for VPC endpoint in consumer VPC
resource "aws_security_group" "vpc_endpoint" {
  name        = "vpc-endpoint-sg"
  description = "Security Group For VPC Endpoint"
  vpc_id      = aws_vpc.consumer.id

  ingress {
    description = "Allow 80 for Consumer VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["172.16.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "consumer-vpc-endpoint-security-group"
  }
}

# Create VPC endpoint in consumer VPC
resource "aws_vpc_endpoint" "consumer" {
  vpc_id            = aws_vpc.consumer.id
  service_name      = aws_vpc_endpoint_service.provider.service_name
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.consumer.id]
  security_group_ids = [aws_security_group.vpc_endpoint.id]

  tags = {
    Name        = "consumer-vpc-endpoint"
  }
}

# Create Private Hosted Zone for Consumer
resource "aws_route53_zone" "consumer" {
  name = "privatelink.internal"

  vpc {
    vpc_id = aws_vpc.consumer.id
  }

  tags = {
    Name = "consumer-private-hosted-zone"
  }
}

# Create DNS Record for Consumer
resource "aws_route53_record" "consumer" {
  zone_id = aws_route53_zone.consumer.zone_id
  name    = "nginx"
  type    = "CNAME"
  ttl     = 60
  records = [aws_vpc_endpoint.consumer.dns_entry[0].dns_name]
}