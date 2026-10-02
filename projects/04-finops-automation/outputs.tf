output "reports_bucket" {
  description = "Bucket con los informes (reports/AAAA/MM/DD/)."
  value       = aws_s3_bucket.reports.bucket
}

output "alerts_topic_arn" {
  description = "Tema de presupuestos, anomalías e informes."
  value       = aws_sns_topic.finops.arn
}

output "scanner_function" {
  description = "Lambda del escáner (se puede invocar a demanda)."
  value       = aws_lambda_function.scanner.function_name
}

output "run_now" {
  description = "Ejecuta el escáner sin esperar al lunes."
  value       = "aws lambda invoke --function-name ${aws_lambda_function.scanner.function_name} --cli-binary-format raw-in-base64-out --payload '{}' /dev/stdout"
}
