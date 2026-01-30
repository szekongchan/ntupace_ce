output "public_ip" {
   description = "Public IPv4 address assigned to the EC2 instance"
   value       = aws_instance.public.public_ip
}
