locals {
  # Map keys are known before apply, so Terraform can create one attachment per
  # node even though the EC2 instance IDs are not known until apply.
  node_instance_ids = merge(
    { "server-1" = aws_instance.server.id },
    { for index, instance in aws_instance.server_join : "server-${index + 2}" => instance.id },
  )
}

# 콘솔에서 한 번 발급해 둔 인증서를 찾아 쓴다. 발급은 도메인 소유 검증이 필요해
# 사람이 하고, Terraform은 그 결과를 참조하기만 한다. ALB와 같은 리전에 있어야
# 하며, 다른 리전의 인증서는 이 data가 찾지 못해 plan에서 실패한다.
data "aws_acm_certificate" "application" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_route53_zone" "application" {
  name         = "${var.domain_name}."
  private_zone = false
}

# 보안 그룹 이름은 -nlb로 남겨 둔다. 이름과 설명은 바꿀 수 없는 속성이라 고치면
# 보안 그룹이 교체되고, 이것을 참조하는 노드 규칙까지 연쇄로 교체된다. 가동 중인
# 클러스터에서 감수할 이유가 없다. 클러스터를 새로 만들 때 함께 정리한다.
resource "aws_security_group" "load_balancer" {
  name        = "${local.name_prefix}-nlb"
  description = "Internet access to the Emoselfie Network Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer_http" {
  security_group_id = aws_security_group.load_balancer.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public HTTP, redirected to HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer_https" {
  security_group_id = aws_security_group.load_balancer.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS"
}

# ALB가 TLS를 종료하고 노드에는 평문 HTTP로 보낸다. 노드 443으로 나갈 일이 없다.
resource "aws_vpc_security_group_egress_rule" "load_balancer_http" {
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP to k3s nodes"
}

resource "aws_lb" "application" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  subnets            = slice(local.subnet_ids, 0, 3)
  security_groups    = [aws_security_group.load_balancer.id]

  # 현재 Socket.IO ping은 25초다. 일시적인 지연에도 연결을 유지할 여유를 둔다.
  # 기본값 60초는 Socket.IO 연결에 빠듯하다. 핑 주기가 바뀌거나 라운드 사이
  # 유휴 구간이 길어지면 ALB가 먼저 끊는다. 여유를 둔다 (spec 13장).
  idle_timeout = 300

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "http" {
  name        = substr("${local.name_prefix}-http", 0, 32)
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id

  # FE는 WebSocket 우선이다. polling 사용 시 ALB 쿠키는 노드를,
  # Traefik의 es_route 쿠키는 backend Pod를 선택한다. ClientIP affinity는 쓰지 않는다.
  # Socket.IO 핸드셰이크가 polling으로 시작하므로 한 사용자의 요청이 노드를
  # 오가면 세션이 깨진다. ALB 쿠키로 노드를 고정한다. 노드 안에서 pod를 고정하는
  # 것은 backend Service의 sessionAffinity가 맡는다 (k8s/base/ingress.yaml 주석).
  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 86400
  }

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    protocol            = "HTTP"
    path                = "/health/live"
    port                = "traffic-port"
    matcher             = "200"
  }

  tags = {
    Name = "${local.name_prefix}-http"
  }
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = local.node_instance_ids

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = each.value
  port             = 80
}

# 카메라 API는 secure context에서만 동작한다(PM-14). http로 들어온 요청을 받아
# 주면 그 페이지에서 촬영이 실패하므로 평문은 아예 남기지 않고 넘긴다.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.application.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.application.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

# ALB의 DNS 이름은 교체할 때마다 바뀐다. alias 레코드는 이름이 아니라 ALB 자체를
# 가리키므로 교체돼도 도메인이 따라간다.
resource "aws_route53_record" "application" {
  zone_id = data.aws_route53_zone.application.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.application.dns_name
    zone_id                = aws_lb.application.zone_id
    evaluate_target_health = true
  }
}
