output "alb_url" {
  description = "URL of load balancer"
  value       = "http://${aws_lb.nlb.dns_name}/"
}