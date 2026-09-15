output "server_public_ip" {
  description = "Public IPv4 address of the k3s server."
  value       = aws_instance.server.public_ip
}

output "server_private_ip" {
  description = "Private IPv4 address used by agents to join the server."
  value       = aws_instance.server.private_ip
}

output "agent_public_ips" {
  description = "Public IPv4 addresses of the two k3s agents."
  value       = aws_instance.agent[*].public_ip
}

output "node_public_ips" {
  description = "Public IPv4 addresses keyed by node name."
  value = merge(
    { server = aws_instance.server.public_ip },
    { for index, instance in aws_instance.agent : "agent-${index + 1}" => instance.public_ip },
  )
}

output "ssh_commands" {
  description = "Example SSH commands. Set the private key path to the local project1_key.pem location."
  value = merge(
    { server = "ssh -i /path/to/project1_key.pem ubuntu@${aws_instance.server.public_ip}" },
    { for index, instance in aws_instance.agent : "agent-${index + 1}" => "ssh -i /path/to/project1_key.pem ubuntu@${instance.public_ip}" },
  )
}

output "kubeconfig_command" {
  description = "Copies the kubeconfig from the server and rewrites its endpoint for local use."
  value       = "scp -i /path/to/project1_key.pem ubuntu@${aws_instance.server.public_ip}:/etc/rancher/k3s/k3s.yaml ./k3s.yaml && sed -i.bak 's/127.0.0.1/${aws_instance.server.public_ip}/' ./k3s.yaml"
}

output "cluster_check_command" {
  description = "Checks that all three nodes joined the cluster."
  value       = "KUBECONFIG=./k3s.yaml kubectl get nodes -o wide"
}

output "load_balancer_dns_name" {
  description = "DNS name of the internet-facing Network Load Balancer."
  value       = aws_lb.application.dns_name
}

output "application_http_url" {
  description = "HTTP URL for accessing the application through the Network Load Balancer."
  value       = "http://${aws_lb.application.dns_name}"
}

output "vpc_cidr" {
  description = "CIDR block of the VPC the cluster runs in. Ansible passes it to Traefik as the trusted proxy range."
  value       = data.aws_vpc.default.cidr_block
}
