Adapted from [Segment's stack](https://github.com/segmentio/stack) as well as various [Terraform community modules](https://github.com/terraform-aws-modules).

# terraform-aws-vpc
Module to create a VPC in AWS.

# Usage
```hcl
module "vpc" {
  source             = "github.com/alchemy-aws-modules/terraform-aws-vpc"
  version            = "0.1"
  name               = "${var.name}"
  environment        = "${var.environment}"
  cidr               = "${var.cidr}"
  private_subnets    = "${var.private_subnets}"
  public_subnets     = "${var.public_subnets}"
  availability_zones = "${var.availability_zones}"
  use_nat_instances  = true

  tags = "${var.tags}"
}
```