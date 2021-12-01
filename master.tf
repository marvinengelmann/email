provider "aws" {
  region = "eu-central-1"
}

resource "aws_iam_role" "email_role" {
  name                = "email_role"
  assume_role_policy  = file("${path.module}/role.json")
}

resource "aws_iam_policy" "email_policy" {
  name    = "email_policy"
  policy  = file("${path.module}/logs_policy.json")
}

resource "aws_iam_role_policy_attachment" "email_attachment" {
  role        = aws_iam_role.email_role.name
  policy_arn  = aws_iam_policy.email_policy.arn
}

data "archive_file" "email_file" {
  type        = "zip"
  source_dir  = "${path.module}/src/"
  output_path = "${path.module}/src.zip"
}

resource "random_pet" "email_bucket_name" {
  prefix = "email"
  length = 4
}

resource "aws_s3_bucket" "email_bucket" {
  bucket = random_pet.email_bucket_name.id
  acl           = "private"
  force_destroy = true
}

resource "aws_s3_bucket_object" "email_bucket_object" {
  bucket  = aws_s3_bucket.email_bucket.id
  key     = "email.zip"
  source  = data.archive_file.email_file.output_path
  etag    = filemd5(data.archive_file.email_file.output_path)
}

resource "aws_lambda_function" "email_function" {
  description       = "Terraform"
  architectures     = ["arm64"]
  s3_bucket         = aws_s3_bucket.email_bucket.id
  s3_key            = aws_s3_bucket_object.email_bucket_object.key
  source_code_hash  = data.archive_file.email_file.output_base64sha256
  function_name     = "email"  
  handler           = "index.handler"
  runtime           = "python3.8"
  role              = aws_iam_role.email_role.arn
  depends_on        = [aws_iam_role_policy_attachment.email_attachment]
  publish           = true
}