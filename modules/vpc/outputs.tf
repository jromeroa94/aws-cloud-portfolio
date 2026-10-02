output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR de la VPC."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Zonas de disponibilidad usadas."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Subredes públicas (ALB, NAT)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subredes privadas de cómputo."
  value       = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  description = "Subredes aisladas para bases de datos."
  value       = aws_subnet.data[*].id
}

output "private_route_table_ids" {
  description = "Tablas de rutas privadas (una por AZ)."
  value       = aws_route_table.private[*].id
}

output "nat_public_ips" {
  description = "IPs públicas de salida (útiles para allowlists de terceros)."
  value       = aws_eip.nat[*].public_ip
}
