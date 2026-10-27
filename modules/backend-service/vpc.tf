# VPC with two PUBLIC subnets across two AZs. No private subnets, no NAT gateway
# (saves ~$32/mo): the ECS task runs in a public subnet with a public IP for
# egress (ECR pull, SSM, Stripe), but its security group only accepts inbound
# from the ALB. RDS sits in the same subnets, reachable only from the task SG.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "lytebuy-backend-${var.env}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

# DUALSTACK (IPv4 + IPv6).
#
# dns.tf publishes an AAAA record for the ALB, so anything that prefers IPv6
# resolves an address that must actually answer. It did not: the ALB was IPv4
# only, so Amplify's Lambda compute connected over IPv6 to nothing and failed
# with "fetch failed". A browser or curl hides this by falling back to IPv4;
# Lambda does not.
#
# IPv6 on a VPC, its subnets and an ALB is FREE - AWS charges for public IPv4
# addresses, not IPv6. It also keeps the API reachable from IPv6-only mobile
# carrier networks, which the apps will meet eventually.
resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = true
  tags                             = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in local.azs : az => i }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  map_public_ip_on_launch = true

  # AWS hands the VPC a /56; each subnet takes a /64 out of it, which is the
  # smallest IPv6 subnet AWS allows.
  ipv6_cidr_block = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, each.value)
  # The ALB needs IPv6 addresses in its subnets to serve dualstack. Tasks keep
  # using IPv4 egress, so nothing about the existing networking changes.
  assign_ipv6_address_on_creation = true

  tags = { Name = "${local.name}-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  # IPv6 egress through the same internet gateway. Without this the subnets have
  # IPv6 addresses but no route, so inbound connections land and never reply.
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
