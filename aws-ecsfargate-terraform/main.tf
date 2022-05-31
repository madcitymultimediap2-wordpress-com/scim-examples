terraform {
  required_version = ">= 0.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = var.name_prefix != "" ? var.name_prefix : "op-scim-bridge"
  domain      = join(".", slice(split(".", var.domain_name), 1, length(split(".", var.domain_name))))
  tags        = merge(var.tags, {
                  application = "1Password SCIM Bridge",
                  version     = trimprefix(jsondecode(file("task-definitions/scim.json"))[0].image, "1password/scim:v")
                })
}

data "aws_vpc" "this" {
  # Use the default VPC or find the VPC by name if specified
  default = var.vpc_name == "" ? true : false
  tags    = var.vpc_name != "" ? { Name = var.vpc_name } : {}
}

data "aws_subnet_ids" "public" {
  vpc_id = data.aws_vpc.this.id
  # Find the public subnets in the VPC
  tags   = var.vpc_name != "" ? { SubnetTier = "public"} : {}
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scimsession" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = [
      aws_secretsmanager_secret.scimsession.arn,
    ]
  }
}

data "aws_acm_certificate" "wildcard_cert" {
  count  =  !var.wildcard_cert ? 0 : 1

  domain = "*.${local.domain}"
}

data "aws_route53_zone" "zone" {
  count        = var.using_route53 ? 1 : 0

  name         = local.domain
  private_zone = false
}

resource "aws_secretsmanager_secret" "scimsession" {
  name_prefix             = local.name_prefix
  # Allow `terraform destroy` to delete secret (hint: save your scimsession file in 1Password)
  recovery_window_in_days = 0

  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "scimsession_1" {
  secret_id     = aws_secretsmanager_secret.scimsession.id
  secret_string = base64encode(file("${path.module}/scimsession"))
}

resource "aws_cloudwatch_log_group" "op_scim_bridge" {
  name_prefix       = local.name_prefix
  retention_in_days = var.log_retention_days 
  
  tags              = local.tags
}

resource "aws_ecs_cluster" "op_scim_bridge" {
  name = var.name_prefix == "" ? "op-scim-bridge" : format("%s-%s",local.name_prefix,"scim-bridge")

  tags = local.tags
}

resource "aws_ecs_task_definition" "op_scim_bridge" {
  family                   = var.name_prefix == "" ? "op_scim_bridge" : format("%s_%s",local.name_prefix,"scim_bridge")
  container_definitions    = templatefile("task-definitions/scim.json",
    { secret_arn     = aws_secretsmanager_secret.scimsession.arn,
      aws_logs_group = aws_cloudwatch_log_group.op_scim_bridge.name,
      region         = var.aws_region
  })
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 1024
  cpu                      = 256
  execution_role_arn       = aws_iam_role.op_scim_bridge.arn

  tags                     = local.tags
}

resource "aws_iam_role" "op_scim_bridge" {
  name_prefix = local.name_prefix
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json

  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "op_scim_bridge" {
  role       = aws_iam_role.op_scim_bridge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "scimsession" {
  name_prefix = local.name_prefix
  role        = aws_iam_role.op_scim_bridge.id
  policy      = data.aws_iam_policy_document.scimsession.json
}

resource "aws_ecs_service" "op_scim_bridge" {
  name             = format("%s_%s",local.name_prefix,"service")
  cluster          = aws_ecs_cluster.op_scim_bridge.id
  task_definition  = aws_ecs_task_definition.op_scim_bridge.arn
  launch_type      = "FARGATE"
  platform_version = "1.4.0"
  desired_count    = 1
  
  load_balancer {
    target_group_arn = aws_lb_target_group.op_scim_bridge.arn
    container_name   = jsondecode(file("task-definitions/scim.json"))[0].name
    container_port   = 3002
  }

  network_configuration {
    subnets          = data.aws_subnet_ids.public.ids
    assign_public_ip = true
    security_groups  = [aws_security_group.service.id]
  }

  tags             = local.tags

  depends_on       = [aws_lb_listener.https]
}

resource "aws_alb" "op_scim_bridge" {
  name               = var.name_prefix == "" ? "op-scim-bridge-alb" : format("%s-%s",local.name_prefix,"alb")
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.public.ids
  security_groups    = [aws_security_group.alb.id]
  
  tags               = local.tags
}

resource "aws_security_group" "alb" {
  # Create a security group for the load balancer
  vpc_id = data.aws_vpc.this.id

  # Allow HTTP traffic from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS traffic from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags   = local.tags
}

resource "aws_security_group" "service" {
  # Create a security group for the service
  vpc_id = data.aws_vpc.this.id
  
  # Only allow traffic from the load balancer security group
  ingress {
    from_port = 3002
    to_port   = 3002
    protocol  = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_lb_target_group" "op_scim_bridge" {
  name        = var.name_prefix == "" ? "op-scim-bridge-tg" : format("%s-%s",local.name_prefix,"tg")
  port        = 3002
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.this.id
  health_check {
    matcher = "200,301,302"
    path    = "/app"
  }

  tags        = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_alb.op_scim_bridge.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = !var.wildcard_cert ? (
                        var.using_route53 ?
                          aws_acm_certificate_validation.op_scim_bridge[0].certificate_arn : aws_acm_certificate.op_scim_bridge[0].arn
                        ) : data.aws_acm_certificate.wildcard_cert[0].arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.op_scim_bridge.arn
  }
}

resource "aws_acm_certificate" "op_scim_bridge" {
  count             = !var.wildcard_cert ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "op_scim_bridge" {
  count                   = var.using_route53 && !var.wildcard_cert ? 1 : 0

  certificate_arn         = aws_acm_certificate.op_scim_bridge[0].arn
  validation_record_fqdns = [for record in aws_route53_record.op_scim_bridge_validation : record.fqdn]
}


resource "aws_route53_record" "op_scim_bridge_validation" {
  for_each = (
    var.using_route53 && !var.wildcard_cert ?
    {
      for dvo in aws_acm_certificate.op_scim_bridge[0].domain_validation_options : dvo.domain_name => {
        name   = dvo.resource_record_name
        record = dvo.resource_record_value
        type   = dvo.resource_record_type
      }
    } : {}
  )

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.zone[0].id
}

resource "aws_route53_record" "op_scim_bridge" {
  count   = var.using_route53 ? 1 : 0

  zone_id = data.aws_route53_zone.zone[0].id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_alb.op_scim_bridge.dns_name
    zone_id                = aws_alb.op_scim_bridge.zone_id
    evaluate_target_health = true
  }
}