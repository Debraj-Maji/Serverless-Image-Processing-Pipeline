terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
    random  = { source = "hashicorp/random", version = "~> 3.5" }
  }
}

provider "aws" {
  region = "ap-south-1"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# 1. CORE INFRASTRUCTURE: S3, SQS, DYNAMODB, SNS

resource "aws_s3_bucket" "source_bucket" {
  bucket        = "project2-source-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket" "destination_bucket" {
  bucket        = "project2-dest-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "destination_lifecycle" {
  bucket = aws_s3_bucket.destination_bucket.id
  rule {
    id     = "expire-processed"
    status = "Enabled"
    filter { prefix = "processed/" }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration { days = 90 }
  }
  rule {
    id     = "clean-temp"
    status = "Enabled"
    filter { prefix = "temp/" }
    expiration { days = 1 }
  }
}

resource "aws_sqs_queue" "image_dlq" {
  name                      = "project2-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "image_queue" {
  name                       = "project2-queue"
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.image_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "s3_to_sqs" {
  queue_url = aws_sqs_queue.image_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.image_queue.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.source_bucket.arn } }
    }]
  })
}

resource "aws_s3_bucket_notification" "source_notification" {
  bucket = aws_s3_bucket.source_bucket.id
  queue {
    queue_arn = aws_sqs_queue.image_queue.arn
    events    = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sqs_queue_policy.s3_to_sqs]
}

resource "aws_dynamodb_table" "metadata_table" {
  name         = "project2-image-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ImageName"
  attribute {
    name = "ImageName"
    type = "S"
  }
}

resource "aws_sns_topic" "notifications" {
  name = "project2-notifications"
}

# 2. IAM ROLES

# Shared Lambda Execution Role
resource "aws_iam_role" "lambda_role" {
  name = "project2-lambda-execution-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "project2-lambda-permissions"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.source_bucket.arn}/*", "${aws_s3_bucket.destination_bucket.arn}/*"] },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.image_queue.arn },
      { Effect = "Allow", Action = "states:StartExecution", Resource = "arn:aws:states:*:*:stateMachine:project2-workflow" },
      { Effect = "Allow", Action = "dynamodb:PutItem", Resource = aws_dynamodb_table.metadata_table.arn },
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.notifications.arn }
    ]
  })
}

# Step Functions Role
resource "aws_iam_role" "sfn_role" {
  name = "project2-sfn-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "states.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "project2-sfn-policy"
  role = aws_iam_role.sfn_role.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = "*" }]
  })
}

# 3. LAMBDA FUNCTIONS & LAYERS    // Note: You must compile Pillow for Amazon Linux and zip it as pillow_layer.zip locally.

resource "aws_lambda_layer_version" "pillow" {
  filename            = "pillow_layer.zip"
  layer_name          = "pillow-image-processing"
  compatible_runtimes = ["python3.11"]
}

# Zip local Python files
data "archive_file" "presigned_zip" {
  type        = "zip"
  source_file = "lambda_functions/presigned_url.py"
  output_path = "lambda_functions/presigned_url.zip"
}

data "archive_file" "processor_zip" {
  type        = "zip"
  source_file = "lambda_functions/image_processor.py"
  output_path = "lambda_functions/image_processor.zip"
}

data "archive_file" "workflow_zip" {
  type        = "zip"
  source_file = "lambda_functions/workflow_tasks.py"
  output_path = "lambda_functions/workflow_tasks.zip"
}

# 3A. API Gateway Endpoint Lambda
resource "aws_lambda_function" "presigned_url" {
  filename      = data.archive_file.presigned_zip.output_path
  function_name = "project2-presigned-url"
  role          = aws_iam_role.lambda_role.arn
  handler       = "presigned_url.lambda_handler"
  runtime       = "python3.11"

  # This tells Terraform to deploy if the python code changes!
  source_code_hash = data.archive_file.presigned_zip.output_base64sha256

  environment {
    variables = {
      SOURCE_BUCKET = aws_s3_bucket.source_bucket.id
      REGION_FIX    = "ap-south-1"
    }
  }
}

# 3B. SQS Trigger Lambda
resource "aws_lambda_function" "image_processor" {
  filename      = data.archive_file.processor_zip.output_path
  function_name = "project2-image-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "image_processor.lambda_handler"
  runtime       = "python3.11"
  environment { variables = { STATE_MACHINE_ARN = aws_sfn_state_machine.workflow.arn } }
}
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.image_queue.arn
  function_name    = aws_lambda_function.image_processor.arn
}

# 3C. Workflow Handlers (4 Lambdas sharing 1 code package)
locals {
  workflow_env = {
    DESTINATION_BUCKET = aws_s3_bucket.destination_bucket.id
    TABLE_NAME         = aws_dynamodb_table.metadata_table.name
    SNS_TOPIC_ARN      = aws_sns_topic.notifications.arn
  }
}

resource "aws_lambda_function" "validate" {
  filename      = data.archive_file.workflow_zip.output_path
  function_name = "project2-task-validate"
  role          = aws_iam_role.lambda_role.arn
  handler       = "workflow_tasks.validate_handler"
  runtime       = "python3.11"
  layers        = [aws_lambda_layer_version.pillow.arn]
}
resource "aws_lambda_function" "resize" {
  filename      = data.archive_file.workflow_zip.output_path
  function_name = "project2-task-resize"
  role          = aws_iam_role.lambda_role.arn
  handler       = "workflow_tasks.resize_handler"
  runtime       = "python3.11"
  layers        = [aws_lambda_layer_version.pillow.arn]
  timeout       = 15
  environment {
    variables = local.workflow_env
  }
}
resource "aws_lambda_function" "watermark" {
  filename      = data.archive_file.workflow_zip.output_path
  function_name = "project2-task-watermark"
  role          = aws_iam_role.lambda_role.arn
  handler       = "workflow_tasks.watermark_handler"
  runtime       = "python3.11"
  layers        = [aws_lambda_layer_version.pillow.arn]
  timeout       = 15
  environment { variables = local.workflow_env }
}
resource "aws_lambda_function" "store" {
  filename      = data.archive_file.workflow_zip.output_path
  function_name = "project2-task-store"
  role          = aws_iam_role.lambda_role.arn
  handler       = "workflow_tasks.store_handler"
  runtime       = "python3.11"
  layers        = [aws_lambda_layer_version.pillow.arn]
  environment { variables = local.workflow_env }
}

# 4. STEP FUNCTIONS WORKFLOW

resource "aws_sfn_state_machine" "workflow" {
  name     = "project2-workflow"
  role_arn = aws_iam_role.sfn_role.arn
  definition = jsonencode({
    StartAt = "Validate"
    States = {
      Validate  = { Type = "Task", Resource = aws_lambda_function.validate.arn, Next = "Resize" }
      Resize    = { Type = "Task", Resource = aws_lambda_function.resize.arn, Next = "Watermark" }
      Watermark = { Type = "Task", Resource = aws_lambda_function.watermark.arn, Next = "Store" }
      Store     = { Type = "Task", Resource = aws_lambda_function.store.arn, End = true }
    }
  })
}

# 5. API GATEWAY

resource "aws_apigatewayv2_api" "http_api" {
  name          = "project2-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
  }
}
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.presigned_url.invoke_arn
}
resource "aws_apigatewayv2_route" "get_upload" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /upload"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presigned_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# 6. CLOUDFRONT DISTRIBUTION (GLOBAL CONTENT DELIVERY)

# Origin Access Control (OAC) to securely restrict S3 access to CloudFront
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "project2-oac-${random_id.suffix.hex}"
  description                       = "OAC for Project 2 Processed Images"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Distribution configured for image caching
resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Project 2 Image Processing CDN"

  origin {
    domain_name              = aws_s3_bucket.destination_bucket.bucket_regional_domain_name
    origin_id                = "S3-Project2-Destination"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-Project2-Destination"
    viewer_protocol_policy = "redirect-to-https"

    # Cache behaviors optimized for static assets
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# S3 Bucket Policy allowing CloudFront to read processed images
resource "aws_s3_bucket_policy" "cloudfront_s3_access" {
  bucket = aws_s3_bucket.destination_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.destination_bucket.arn}/processed/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# 7. FINAL OUTPUT

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.cdn.domain_name
  description = "Use this domain to view your fully processed, watermarked images"
}

output "api_upload_endpoint" {
  value = "${aws_apigatewayv2_api.http_api.api_endpoint}/upload"
}
