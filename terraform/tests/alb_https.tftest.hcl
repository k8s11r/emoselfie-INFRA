# AWS 자격 증명이나 실제 리소스 없이 HTTPS 경로의 병합 회귀를 검사한다.
mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-00000000000000001"
      cidr_block = "10.0.0.0/16"
    }
  }
  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
    }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-00000000000000001" }
  }
  mock_data "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000001"
    }
  }
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z0000000000001" }
  }
}

mock_provider "random" {}

variables {
  admin_cidr    = "192.0.2.1/32"
  domain_name   = "emoselfie.click"
  cluster_token = "isolated-test-token-not-for-deployment"
}

run "alb_https_routing" {
  command = plan

  assert {
    condition     = aws_lb.application.load_balancer_type == "application"
    error_message = "HTTPS 경로가 NLB로 되돌아갔습니다."
  }
  assert {
    condition = (
      aws_lb_listener.http.protocol == "HTTP" &&
      aws_lb_listener.http.default_action[0].type == "redirect" &&
      aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS" &&
      aws_lb_listener.http.default_action[0].redirect[0].port == "443"
    )
    error_message = "HTTP는 HTTPS로 리다이렉트해야 합니다."
  }
  assert {
    condition = (
      aws_lb_listener.https.protocol == "HTTPS" &&
      aws_lb_listener.https.certificate_arn == data.aws_acm_certificate.application.arn &&
      aws_lb_listener.https.default_action[0].type == "forward"
    )
    error_message = "ALB에서 ACM 인증서로 TLS를 종료해야 합니다."
  }
  assert {
    condition = (
      aws_lb_target_group.http.protocol == "HTTP" &&
      aws_lb_target_group.http.port == 80 &&
      aws_lb_target_group.http.health_check[0].path == "/health/live" &&
      aws_lb_target_group.http.health_check[0].matcher == "200" &&
      aws_lb_target_group.http.stickiness[0].enabled
    )
    error_message = "Traefik 대상 포트, health 경로 또는 노드 stickiness가 잘못되었습니다."
  }
  assert {
    condition     = aws_route53_record.application.name == var.domain_name && aws_route53_record.application.type == "A"
    error_message = "서비스 도메인의 A alias 레코드가 필요합니다."
  }
}
