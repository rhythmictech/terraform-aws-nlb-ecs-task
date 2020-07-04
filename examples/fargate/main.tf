########################################
# Tags and Naming
########################################
variable "vpc_id" {}
variable "subnet_ids" {}
locals {
  env       = "sandbox"
  name      = "example-nlb-service"
  namespace = "aws-rhythmic-sandbox"
  owner     = "Rhythmictech Engineering"
  region    = "us-east-1"

  extra_tags = {
    delete_me = "please"
    purpose   = "testing"
  }
}

module "tags" {
  source  = "rhythmictech/tags/terraform"
  version = "1.1.0"

  names = [local.name, local.env, local.namespace]

  tags = merge({
    "Env"       = local.env,
    "Namespace" = local.namespace,
    "Owner"     = local.owner
  }, local.extra_tags)
}

########################################=
#  ECS and NLB
########################################=

resource "aws_ecs_cluster" "example" {
  name = module.tags.name
  tags = module.tags.tags
}

resource "aws_lb" "public" {
  internal           = false #tfsec:ignore:AWS005
  load_balancer_type = "network"
  name               = "${local.name}-external-alb"
  subnets            = var.subnet_ids
  tags               = module.tags.tags
}

########################################
# Example module invocation
########################################

module "example" {
  source = "../.."

  assign_ecs_service_public_ip = true
  cluster_name                 = aws_ecs_cluster.example.name
  container_port               = 80
  container_image              = "docker.io/library/nginx:alpine"
  load_balancer_arn            = aws_lb.public.arn
  listener_port                = 80
  name                         = local.name
  subnets                      = var.subnet_ids
  tags                         = module.tags.tags
  vpc_id                       = var.vpc_id
}

output "example_module" {
  description = "the whole module"
  value       = module.example
}

output "dns_name" {
  description = "DNS name of ALB"
  value       = aws_lb.public.dns_name
}
