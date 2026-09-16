output "s3_endpoint_id" {
  description = "S3 Gateway Endpoint ID (vpce-xxxx). 보안팀 검증·인계 문서용."
  value       = aws_vpc_endpoint.s3.id
}

output "s3_endpoint_prefix_list_id" {
  description = <<-EOT
    이 Endpoint 가 라우팅 테이블에 심는 prefix list ID (pl-xxxx).
    "S3 주소 묶음"이라는 뜻이고, 0.0.0.0/0(NAT)보다 길어서
    longest prefix match 로 S3 트래픽이 NAT 를 타지 않는다.
  EOT
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "associated_route_table_ids" {
  description = "실제로 연결된 라우팅 테이블 map. rt-public 이 없어야 정상."
  value       = var.route_table_ids
}
