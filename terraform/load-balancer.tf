locals {
  # Map keys are known before apply, so Terraform can create one attachment per
  # node even though the EC2 instance IDs are not known until apply.
  node_instance_ids = merge(
    { server = aws_instance.server.id },
    { for index, instance in aws_instance.agent : "agent-${index + 1}" => instance.id },
  )
}

resource "aws_security_group" "load_balancer" {
  name        = "${local.name_prefix}-nlb"
  description = "Internet access to the Emoselfie Network Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${local.name_prefix}-nlb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer_http" {
  security_group_id = aws_security_group.load_balancer.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP"
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer_https" {
  security_group_id = aws_security_group.load_balancer.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "load_balancer_http" {
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP to k3s nodes"
}

resource "aws_vpc_security_group_egress_rule" "load_balancer_https" {
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS to k3s nodes"
}

resource "aws_lb" "application" {
  name                             = substr("${local.name_prefix}-nlb", 0, 32)
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = slice(local.subnet_ids, 0, 3)
  security_groups                  = [aws_security_group.load_balancer.id]
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${local.name_prefix}-nlb"
  }
}

resource "aws_lb_target_group" "http" {
  name        = substr("${local.name_prefix}-http", 0, 32)
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "HTTP"
    path                = "/health/live"
    port                = "traffic-port"
  }

  tags = {
    Name = "${local.name_prefix}-http"
  }
}

resource "aws_lb_target_group" "https" {
  name        = substr("${local.name_prefix}-https", 0, 32)
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "TCP"
    port                = "traffic-port"
  }

  tags = {
    Name = "${local.name_prefix}-https"
  }
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = local.node_instance_ids

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = each.value
  port             = 80
}

resource "aws_lb_target_group_attachment" "https" {
  for_each = local.node_instance_ids

  target_group_arn = aws_lb_target_group.https.arn
  target_id        = each.value
  port             = 443
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.application.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}
