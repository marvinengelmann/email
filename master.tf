terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

variable "name" {
  default = "email"
}

variable "domain" {
  default = "marvinengelmann.email"
}

data "aws_route53_zone" "email_zone" {
  name          = var.domain
  private_zone  = false
}

resource "aws_iam_role" "email_role" {
  name                = var.name
  assume_role_policy  = file("${path.module}/role.json")
}

resource "aws_iam_policy" "email_policy" {
  name    = var.name
  policy  = file("${path.module}/policy.json")
}

resource "aws_iam_role_policy_attachment" "email_policy_attachment" {
  role        = aws_iam_role.email_role.name
  policy_arn  = aws_iam_policy.email_policy.arn
}

data "archive_file" "email_archive" {
  type        = "zip"
  source_dir  = "${path.module}/src/"
  output_path = "${path.module}/src.zip"
}

resource "random_pet" "email_bucket_name" {
  prefix = var.name
  length = 4
}

resource "aws_s3_bucket" "email_bucket" {
  bucket        = random_pet.email_bucket_name.id
  acl           = "private"
  force_destroy = true
}

resource "aws_s3_bucket_object" "email_bucket_object" {
  bucket  = aws_s3_bucket.email_bucket.id
  key     = "${var.name}.zip"
  source  = data.archive_file.email_archive.output_path
  etag    = filemd5(data.archive_file.email_archive.output_path)
}

resource "aws_lambda_function" "email_lambda" {
  architectures     = ["arm64"]
  s3_bucket         = aws_s3_bucket.email_bucket.id
  s3_key            = aws_s3_bucket_object.email_bucket_object.key
  source_code_hash  = data.archive_file.email_archive.output_base64sha256
  function_name     = var.name 
  handler           = "index.handler"
  runtime           = "python3.8"
  role              = aws_iam_role.email_role.arn
  depends_on        = [aws_iam_role_policy_attachment.email_policy_attachment]
  publish           = true
}

resource "aws_acm_certificate" "email_certificate" {
  domain_name       = var.domain
  validation_method = "DNS"  

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "email_certificate_record" {
  for_each = {
    for options in aws_acm_certificate.email_certificate.domain_validation_options : options.domain_name => {
      name    = options.resource_record_name
      record  = options.resource_record_value
      type    = options.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.email_zone.zone_id
}

resource "aws_acm_certificate_validation" "email_certificate_validation" {
  certificate_arn         = aws_acm_certificate.email_certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.email_certificate_record : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "email_api_domain_name" {
  domain_name = var.domain

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.email_certificate_validation.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_route53_record" "email_api_record" {
  name    = aws_apigatewayv2_domain_name.email_api_domain_name.domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.email_zone.zone_id

  alias {
    name                   = aws_apigatewayv2_domain_name.email_api_domain_name.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.email_api_domain_name.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_apigatewayv2_api" "email_api" {
  name          = var.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "email_api_stage" {
  api_id      = aws_apigatewayv2_api.email_api.id
  name        = var.name
  auto_deploy = true
}

resource "aws_apigatewayv2_api_mapping" "email_api_mapping" {
  api_id      = aws_apigatewayv2_api.email_api.id
  domain_name = aws_apigatewayv2_domain_name.email_api_domain_name.id
  stage       = aws_apigatewayv2_stage.email_api_stage.id
}

resource "aws_apigatewayv2_integration" "email_api_integration" {
  api_id              = aws_apigatewayv2_api.email_api.id
  integration_type    = "AWS_PROXY"
  integration_method  = "POST"
  integration_uri     = aws_lambda_function.email_lambda.invoke_arn
}

resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowEmailAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.email_api.execution_arn}/*/GET/"
}

resource "aws_apigatewayv2_route" "email_api_route" {
  api_id    = aws_apigatewayv2_api.email_api.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.email_api_integration.id}"
}