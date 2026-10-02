output "inbox_bucket" {
  description = "Sube aquí los pedidos (prefijo incoming/)."
  value       = aws_s3_bucket.inbox.bucket
}

output "orders_table" {
  description = "Tabla DynamoDB de pedidos."
  value       = aws_dynamodb_table.orders.name
}

output "events_topic_arn" {
  description = "Tema SNS con los eventos de pedidos."
  value       = aws_sns_topic.orders.arn
}

output "consumer_queue_urls" {
  description = "Colas de cada servicio descendente."
  value       = { for k, q in aws_sqs_queue.consumer : k => q.url }
}

output "lambda_function_name" {
  description = "Función procesadora."
  value       = aws_lambda_function.order_processor.function_name
}

output "try_it" {
  description = "Prueba rápida extremo a extremo."
  value       = <<-EOT
    aws s3 cp examples/order-valid.json s3://${aws_s3_bucket.inbox.bucket}/incoming/order-valid.json
    aws dynamodb get-item --table-name ${aws_dynamodb_table.orders.name} --key '{"order_id":{"S":"ORD-1001"}}'
    aws sqs receive-message --queue-url ${aws_sqs_queue.consumer["shipping"].url}
  EOT
}
