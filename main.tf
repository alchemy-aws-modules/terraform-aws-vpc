variable "cidr" {
  description = "The CIDR block for the VPC."
}

variable "public_subnets" {
  description = "List of public subnets"
  type        = "list"
}

variable "private_subnets" {
  description = "List of private subnets"
  type        = "list"
}

variable "environment" {
  description = "Environment tag, e.g prod"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = "list"
}

variable "name" {
  description = "Name tag, e.g stack"
  default     = "stack"
}

variable "use_nat_instances" {
  description = "If true, use EC2 NAT instances instead of the AWS NAT gateway service."
  default     = false
}

variable "nat_instance_type" {
  description = "Only if use_nat_instances is true, which EC2 instance type to use for the NAT instances."
  default     = "t2.nano"
}

variable "use_eip_with_nat_instances" {
  description = "Only if use_nat_instances is true, whether to assign Elastic IPs to the NAT instances. IF this is set to false, NAT instances use dynamically assigned IPs."
  default     = false
}

variable "tags" {
  description = "A map of tags to add to all resources"
  default     = {}
}

variable "vpc_tags" {
  description = "Additional tags for the VPC"
  default     = {}
}

variable "public_subnet_tags" {
  description = "Additional tags for the public subnets"
  default     = {}
}

variable "private_subnet_tags" {
  description = "Additional tags for the private subnets"
  default     = {}
}

variable "public_route_table_tags" {
  description = "Additional tags for the public route tables"
  default     = {}
}

variable "private_route_table_tags" {
  description = "Additional tags for the private route tables"
  default     = {}
}

# This data source returns the newest Amazon NAT instance AMI
data "aws_ami" "nat_ami" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat*"]
  }
}

variable "nat_instance_ssh_key_name" {
  description = "Only if use_nat_instance is true, the optional SSH key-pair to assign to NAT instances."
  default     = ""
}

/**
 * VPC
 */

resource "aws_vpc" "main" {
  cidr_block           = "${var.cidr}"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = "${merge(var.tags, var.vpc_tags, map("Name", format("%s", var.name), "Environment", "${var.environment}"))}"
}

/**
 * Gateways
 */

resource "aws_internet_gateway" "main" {
  vpc_id = "${aws_vpc.main.id}"

  tags = "${merge(var.tags, map("Name", format("%s", var.name), "Environment", "${var.environment}"))}"
}

resource "aws_nat_gateway" "main" {
  # Only create this if not using NAT instances.
  count         = "${(1 - var.use_nat_instances) * length(var.private_subnets)}"
  allocation_id = "${element(aws_eip.nat.*.id, count.index)}"
  subnet_id     = "${element(aws_subnet.public.*.id, count.index)}"
  depends_on    = ["aws_internet_gateway.main"]

  tags = "${merge(var.tags, map("Name", format("%s", var.name), "Environment", "${var.environment}"))}"
}

resource "aws_eip" "nat" {
  # Create these only if:
  # NAT instances are used and Elastic IPs are used with them,
  # or if the NAT gateway service is used (NAT instances are not used).
  count = "${signum((var.use_nat_instances * var.use_eip_with_nat_instances) + (var.use_nat_instances == 0 ? 1 : 0)) * length(var.private_subnets)}"

  vpc = true

  tags = "${merge(var.tags, map("Name", format("%s-%03d", var.name, element(var.availability_zones, count.index)), "Environment", "${var.environment}"))}"
}

resource "aws_security_group" "nat_instances" {
  # Create this only if using NAT instances, vs. the NAT gateway service.
  count       = "${0 + var.use_nat_instances}"
  name        = "nat"
  description = "Allow traffic from clients into NAT instances"

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = "${var.private_subnets}"
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = "${var.private_subnets}"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = "${aws_vpc.main.id}"

  tags = "${merge(var.tags, map("Name", format("%s-nat-instance", var.name), "Environment", "${var.environment}"))}"
}

resource "aws_instance" "nat_instance" {
  # Create these only if using NAT instances, vs. the NAT gateway service.
  count             = "${(0 + var.use_nat_instances) * length(var.private_subnets)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  key_name          = "${var.nat_instance_ssh_key_name}"
  ami               = "${data.aws_ami.nat_ami.id}"
  instance_type     = "${var.nat_instance_type}"
  source_dest_check = false

  # associate_public_ip_address is not used,,
  # as public subnets have map_public_ip_on_launch set to true.
  # Also, using associate_public_ip_address causes issues with
  # stopped NAT instances which do not use an Elastic IP.
  # - For more details: https://github.com/terraform-providers/terraform-provider-aws/issues/343
  subnet_id = "${element(aws_subnet.public.*.id, count.index)}"

  vpc_security_group_ids = ["${aws_security_group.nat_instances.id}"]

  lifecycle {
    # Ignore changes to the NAT AMI data source.
    ignore_changes = ["ami"]
  }

  tags        = "${merge(var.tags, map("Name", "${var.name}-${format("private-%03d NAT", count.index+1)}", "Environment", var.environment))}"
  volume_tags = "${merge(var.tags, map("Name", "${var.name}-${format("private-%03d NAT", count.index+1)}", "Environment", var.environment))}"
}

resource "aws_eip_association" "nat_instance_eip" {
  # Create these only if using NAT instances, vs. the NAT gateway service.
  count         = "${(0 + (var.use_nat_instances * var.use_eip_with_nat_instances)) * length(var.private_subnets)}"
  instance_id   = "${element(aws_instance.nat_instance.*.id, count.index)}"
  allocation_id = "${element(aws_eip.nat.*.id, count.index)}"
}

/**
 * Subnets.
 */

resource "aws_subnet" "private" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${element(var.private_subnets, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"
  count             = "${length(var.private_subnets)}"

  tags = "${merge(var.tags, var.private_subnet_tags, map("Name", format("%s-private-%03d", var.name, count.index+1), "Environment", "${var.environment}"))}"
}

resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "${element(var.public_subnets, count.index)}"
  availability_zone       = "${element(var.availability_zones, count.index)}"
  count                   = "${length(var.public_subnets)}"
  map_public_ip_on_launch = true

  tags = "${merge(var.tags, var.public_subnet_tags, map("Name", format("%s-public-%03d", var.name, count.index+1), "Environment", "${var.environment}"))}"
}

/**
 * Route tables
 */

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.main.id}"

  tags = "${merge(var.tags, var.public_route_table_tags, map("Name", format("%s-public-001", var.name), "Environment", var.environment))}"
}

resource "aws_route" "public" {
  route_table_id         = "${aws_route_table.public.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.main.id}"
}

resource "aws_route_table" "private" {
  count  = "${length(var.private_subnets)}"
  vpc_id = "${aws_vpc.main.id}"

  tags = "${merge(var.tags, var.public_route_table_tags, map("Name", format("%s-private-%03d", var.name, count.index+1), "Environment", var.environment))}"
}

resource "aws_route" "private" {
  # Create this only if using the NAT gateway service, vs. NAT instances.
  count                  = "${(1 - var.use_nat_instances) * length(compact(var.private_subnets))}"
  route_table_id         = "${element(aws_route_table.private.*.id, count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = "${element(aws_nat_gateway.main.*.id, count.index)}"
}

resource "aws_route" "private_nat_instance" {
  count                  = "${(0 + var.use_nat_instances) * length(compact(var.private_subnets))}"
  route_table_id         = "${element(aws_route_table.private.*.id, count.index)}"
  destination_cidr_block = "0.0.0.0/0"
  instance_id            = "${element(aws_instance.nat_instance.*.id, count.index)}"
}

/**
 * Route associations
 */

resource "aws_route_table_association" "private" {
  count          = "${length(var.private_subnets)}"
  subnet_id      = "${element(aws_subnet.private.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.private.*.id, count.index)}"
}

resource "aws_route_table_association" "public" {
  count          = "${length(var.public_subnets)}"
  subnet_id      = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = "${aws_route_table.public.id}"
}

/**
 * Outputs
 */

// The VPC ID
output "id" {
  value = "${aws_vpc.main.id}"
}

// The VPC CIDR
output "cidr_block" {
  value = "${aws_vpc.main.cidr_block}"
}

// A comma-separated list of subnet IDs.
output "public_subnets" {
  value = ["${aws_subnet.public.*.id}"]
}

// A list of subnet IDs.
output "private_subnets" {
  value = ["${aws_subnet.private.*.id}"]
}

// The default VPC security group ID.
output "security_group" {
  value = "${aws_vpc.main.default_security_group_id}"
}

// The list of availability zones of the VPC.
output "availability_zones" {
  value = ["${aws_subnet.public.*.availability_zone}"]
}

// The private route table ID.
output "private_rtb_id" {
  value = "${join(",", aws_route_table.private.*.id)}"
}

// The public route table ID.
output "public_rtb_id" {
  value = "${aws_route_table.public.id}"
}

// The list of EIPs associated with the private subnets.
output "private_nat_ips" {
  value = ["${aws_eip.nat.*.public_ip}"]
}
