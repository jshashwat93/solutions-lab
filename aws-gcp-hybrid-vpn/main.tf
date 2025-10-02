terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.14.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.4.0"
    }
  }
}

### Cloud Deployment on AWS

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "cloud" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "cloud-vpc"
  }
}

# Fetch AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Public Subnet
resource "aws_subnet" "cloud_public" {
  vpc_id     = aws_vpc.cloud.id
  cidr_block = cidrsubnet(aws_vpc.cloud.cidr_block, 4, 3)
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = {
    Name = "cloud-public-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "cloud" {
  vpc_id = aws_vpc.cloud.id
  tags = {
    Name = "cloud-internet-gateway"
  }
}

# Route table for the public subnet
resource "aws_route_table" "cloud_public" {
  vpc_id = aws_vpc.cloud.id
  tags = {
    Name = "cloud-public-rt"
  }
}

# Route
resource "aws_route" "cloud_public" {
  route_table_id = aws_route_table.cloud_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.cloud.id
}

resource "aws_route_table_association" "cloud_public" {
  subnet_id      = aws_subnet.cloud_public.id
  route_table_id = aws_route_table.cloud_public.id
}

resource "aws_subnet" "cloud_private" {
  count = 3

  vpc_id            = aws_vpc.cloud.id
  cidr_block        = cidrsubnet(aws_vpc.cloud.cidr_block, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "cloud-private-subnet-${count.index + 1}"
  }
}

resource "aws_eip" "cloud" {
  domain = "vpc"
}

resource "aws_nat_gateway" "cloud" {
  allocation_id = aws_eip.cloud.id
  subnet_id     = aws_subnet.cloud_public.id
  tags = {
    Name = "cloud-nat-gw"
  }
  depends_on = [aws_internet_gateway.cloud]
}

# Route Table
resource "aws_route_table" "cloud_private" {
  vpc_id = aws_vpc.cloud.id
  tags = {
    Name = "cloud-private-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "cloud_private" {
  count = 3

  subnet_id      = aws_subnet.cloud_private[count.index].id
  route_table_id = aws_route_table.cloud_private.id
}

# Route
resource "aws_route" "cloud_private" {
  route_table_id = aws_route_table.cloud_private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.cloud.id
}

# IAM Role
resource "aws_iam_role" "cloud" {
  name_prefix = "SSMRole-"
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
    Name = "cloud-ssm-iam-role"
  }
}

# SSM Policy
resource "aws_iam_role_policy_attachment" "cloud" {
  role       = aws_iam_role.cloud.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "cloud" {
  name_prefix = "SSMInstanceProfile-"
  role = aws_iam_role.cloud.name
  tags = {
    Name = "cloud-iam-instance-profile"
  }
}

# Security Group
resource "aws_security_group" "cloud" {
  name        = "service-sg"
  description = "Security Group For Service Instance"
  vpc_id      = aws_vpc.cloud.id

  ingress {
  description = "Allow ICMP from on-prem"
  from_port   = -1
  to_port     = -1
  protocol    = "icmp"
  cidr_blocks = [google_compute_subnetwork.on_prem.ip_cidr_range]
  }

  ingress {
    description = "Allow 80 from on-prem"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [google_compute_subnetwork.on_prem.ip_cidr_range]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "cloud-instance-security-group"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name   = "vpc-endpoints-sg"
  vpc_id = aws_vpc.cloud.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.cloud.id]
  }
}

resource "aws_vpc_endpoint" "ssm_endpoints" {
  for_each = toset([ "ssm", "ec2messages", "ssmmessages" ])

  vpc_id              = aws_vpc.cloud.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.cloud_private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}


# Fetch Latest AMI
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# EC2
resource "aws_instance" "cloud" {
  ami                     = data.aws_ssm_parameter.al2023.value
  instance_type           = "t3.micro"
  vpc_security_group_ids  = [aws_security_group.cloud.id]
  subnet_id               = aws_subnet.cloud_private[0].id
  iam_instance_profile = aws_iam_instance_profile.cloud.id
  tags = {
    Name = "cloud-instance"
  }
}

# Virtual Private Gateway
resource "aws_vpn_gateway" "cloud" {
  vpc_id = aws_vpc.cloud.id
  tags = {
    Name = "vpn-gateway"
  }
}

# Customer Gateway
resource "aws_customer_gateway" "cloud" {
  bgp_asn    = 65000
  ip_address = google_compute_address.on_prem.address
  type       = "ipsec.1"
  tags = {
    Name = "customer-gateway"
  }
}

# VPN Connection
resource "aws_vpn_connection" "cloud" {
  vpn_gateway_id      = aws_vpn_gateway.cloud.id
  customer_gateway_id = aws_customer_gateway.cloud.id
  type                = "ipsec.1"
  static_routes_only  = true
}

# VPN Connection Route
resource "aws_vpn_connection_route" "cloud" {
  destination_cidr_block = google_compute_subnetwork.on_prem.ip_cidr_range
  vpn_connection_id      = aws_vpn_connection.cloud.id
}

# VPN Route Propagation
resource "aws_vpn_gateway_route_propagation" "cloud" {
  vpn_gateway_id = aws_vpn_gateway.cloud.id
  route_table_id = aws_route_table.cloud_private.id
}

### On-Prem Deployment on GCP

provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

# VPC
resource "google_compute_network" "on_prem" {
  name                    = "gcp-network-on-prem"
  auto_create_subnetworks = false
}

# Subnet
resource "google_compute_subnetwork" "on_prem" {
  name          = "subnet-1"
  ip_cidr_range = "172.16.0.0/24"
  region        = var.gcp_region
  network       = google_compute_network.on_prem.id
}

# Firewall - Ingress: TCP + HTTP + ICMP
resource "google_compute_firewall" "on_prem_allow_ingress_from_aws" {
  name    = "allow-ingress-from-aws"
  network = google_compute_network.on_prem.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22", "80"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [aws_vpc.cloud.cidr_block]
}

# Firewall - Egress: TCP + HTTP + ICMP + HTTPS + Kafka
resource "google_compute_firewall" "on_prem_allow_egress_to_aws" {
  name    = "allow-egress-to-aws"
  network = google_compute_network.on_prem.name
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "9092"]
  }

  allow {
    protocol = "icmp"
  }

  destination_ranges = [aws_vpc.cloud.cidr_block]
}

# Firewall - Ingress: SSH
resource "google_compute_firewall" "on_prem_allow_ssh_iap" {
  name    = "allow-ssh-from-iap-only"
  network = google_compute_network.on_prem.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# Compute
resource "google_compute_instance" "on_prem" {
  name         = "on-prem-vm"
  machine_type = "e2-micro"
  zone         = "${var.gcp_region}-b"
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.on_prem.id
    access_config {}
  }
}

# Public Static IP Address
resource "google_compute_address" "on_prem" {
  name   = "vpn-ip-address"
  region = "us-east1"
}

# VPN Gateway
resource "google_compute_vpn_gateway" "on_prem" {
  name    = "vpn-to-cloud"
  network = google_compute_network.on_prem.id
}

# VPN Forwarding Rule 1
resource "google_compute_forwarding_rule" "on_prem_fr_esp" {
  name        = "fr-esp"
  ip_protocol = "ESP"
  ip_address  = google_compute_address.on_prem.address
  target      = google_compute_vpn_gateway.on_prem.id
}

# VPN Forwarding Rule 2
resource "google_compute_forwarding_rule" "on_prem_fr_udp500" {
  name        = "fr-udp500"
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.on_prem.address
  target      = google_compute_vpn_gateway.on_prem.id
}

# VPN Forwarding Rule 3
resource "google_compute_forwarding_rule" "on_prem_fr_udp4500" {
  name        = "fr-udp4500"
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.on_prem.address
  target      = google_compute_vpn_gateway.on_prem.id
}

# VPN Tunnel 1
resource "google_compute_vpn_tunnel" "on_prem_tunnel1" {
  name          = "tunnel1"
  peer_ip       = aws_vpn_connection.cloud.tunnel1_address
  shared_secret = aws_vpn_connection.cloud.tunnel1_preshared_key
  local_traffic_selector  = [google_compute_subnetwork.on_prem.ip_cidr_range]
  remote_traffic_selector = [aws_vpc.cloud.cidr_block]     
  target_vpn_gateway = google_compute_vpn_gateway.on_prem.id

  depends_on = [
    google_compute_forwarding_rule.on_prem_fr_esp,
    google_compute_forwarding_rule.on_prem_fr_udp500,
    google_compute_forwarding_rule.on_prem_fr_udp4500,
  ]
}

# VPN Tunnel 2
resource "google_compute_vpn_tunnel" "on_prem_tunnel2" {
  name          = "tunnel2"
  peer_ip       = aws_vpn_connection.cloud.tunnel2_address
  shared_secret = aws_vpn_connection.cloud.tunnel2_preshared_key
  local_traffic_selector  = [google_compute_subnetwork.on_prem.ip_cidr_range]
  remote_traffic_selector = [aws_vpc.cloud.cidr_block]     
  target_vpn_gateway = google_compute_vpn_gateway.on_prem.id

  depends_on = [
    google_compute_forwarding_rule.on_prem_fr_esp,
    google_compute_forwarding_rule.on_prem_fr_udp500,
    google_compute_forwarding_rule.on_prem_fr_udp4500,
  ]
}

# VPN Route 1
resource "google_compute_route" "on_prem_route1_tunnel1" {
  name       = "route1-tunnel1"
  network    = google_compute_network.on_prem.name
  dest_range = aws_vpc.cloud.cidr_block
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.on_prem_tunnel1.id
}

# VPN Route 2
resource "google_compute_route" "on_prem_route1_tunnel2" {
  name       = "route1-tunnel2"
  network    = google_compute_network.on_prem.name
  dest_range = aws_vpc.cloud.cidr_block
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.on_prem_tunnel2.id
}
