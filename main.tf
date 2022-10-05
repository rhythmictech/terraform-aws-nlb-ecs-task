########################################
# Security Groups for ECS service
########################################

resource "aws_security_group" "ecs_service" {
  name_prefix = var.name
  description = "Security Group for ECS Service ${var.name}"
  tags        = var.tags
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "allow_all_egress" {
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:AWS007
  description       = "Allow all traffic to egress from ${var.name}"
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.ecs_service.id
  to_port           = 0
  type              = "egress"
}

resource "aws_security_group_rule" "nlb_to_ecs_ingress" {
  cidr_blocks       = values(data.aws_subnet.this)[*].cidr_block
  description       = "Allow ingress from NLB to ${var.name}"
  from_port         = 0
  protocol          = "-1"
  security_group_id = aws_security_group.ecs_service.id
  to_port           = 0
  type              = "ingress"
}

########################################
# Logs
########################################

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/ecs/${var.name}"
  tags = var.tags

  lifecycle {
    ignore_changes = [name, name_prefix]
  }
}

########################################
# LB
########################################

data "aws_lb" "this" {
  arn = var.load_balancer_arn
}

data "aws_subnet" "this" {
  for_each = data.aws_lb.this.subnets
  id       = each.value
}

resource "aws_lb_target_group" "this" {
  name_prefix = local.lb_target_group_name_prefix
  port        = var.target_group_port
  protocol    = var.internal_protocol
  tags        = var.tags
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    healthy_threshold   = var.health_check.healthy_threshold
    interval            = var.health_check.interval
    port                = var.health_check.port
    protocol            = var.health_check.protocol
    unhealthy_threshold = var.health_check.unhealthy_threshold
  }

  dynamic "stickiness" {
    for_each = var.stickiness != null ? toset([var.stickiness]) : []
    content {
      enabled = lookup(stickiness.value, "enabled", false)
      type    = lookup(stickiness.value, "type", "lb_cookie")
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "this" {
  depends_on        = [aws_lb_target_group.this]
  load_balancer_arn = var.load_balancer_arn
  port              = var.listener_port
  protocol          = var.internal_protocol #tfsec:ignore:AWS004

  default_action {
    target_group_arn = aws_lb_target_group.this.arn
    type             = "forward"
  }
}

########################################
# ECS
########################################
module "container_definition" {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.1"

  environment       = var.environment_variables
  container_cpu     = var.task_cpu
  container_image   = var.container_image
  container_memory  = var.task_memory
  container_name    = local.container_name
  log_configuration = local.log_configuration
  port_mappings     = local.port_mappings
  secrets           = var.secrets
}

resource "aws_ecs_task_definition" "this" {
  container_definitions    = module.container_definition.json_map_encoded_list
  cpu                      = var.task_cpu
  execution_role_arn       = try(aws_iam_role.ecs_exec[0].arn, var.ecs_execution_role)
  family                   = var.name
  memory                   = var.task_memory
  network_mode             = var.network_mode
  requires_compatibilities = [var.launch_type]
  tags                     = var.tags
  task_role_arn            = try(aws_iam_role.ecs_task[0].arn, var.ecs_task_role)

  dynamic "volume" {
    for_each = var.volumes
    content {
      name = volume.value.name
    }
  }
  lifecycle {
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "this" {
  cluster                = var.cluster_name
  desired_count          = var.task_desired_count
  enable_execute_command = true
  launch_type            = var.launch_type
  name                   = var.name
  task_definition        = aws_ecs_task_definition.this.arn

  load_balancer {
    container_name   = local.container_name
    container_port   = var.container_port
    target_group_arn = aws_lb_target_group.this.arn
  }

  lifecycle {
    # Subsequent deploys are likely to be done through an external deployment pipeline
    #  so if this is rerun without ignoring the task def change
    #  then terraform will roll it back :(
    ignore_changes = [task_definition]
  }

  network_configuration {
    assign_public_ip = var.assign_ecs_service_public_ip
    security_groups  = compact(concat(var.security_group_ids, [aws_security_group.ecs_service.id]))
    subnets          = var.subnets
  }

  dynamic "service_registries" {
    for_each = var.service_registry_arn == null ? [] : [1]
    content {
      registry_arn   = var.service_registry_arn
      container_name = local.container_name
      container_port = var.container_port
    }
  }
}
