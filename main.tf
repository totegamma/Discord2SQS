
variable "discord_public_key" {}
variable "sqs_access_key"     {}
variable "sqs_secret_key"     {}
variable "sqs_queue_url"      {}

terraform {
    backend "s3" {
        bucket = "net.gammalab.terraform-test-tfstate"
        key    = "Discord2SQS.tfstate"
        region = "ap-northeast-1"
    }
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 3.27"
        }
    }
    required_version = ">= 0.14.9"
}

provider "aws" {
    region = "ap-northeast-1"
}

resource "aws_iam_role" "lambda_sqs_job" {
    name = "lambda_sqs"

    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
            Action = [
                "sts:AssumeRole"
            ],
            Effect = "Allow",
            Principal = {
                Service = "lambda.amazonaws.com"
            }
        }]
    })

    inline_policy {
        name = "sqs_policy"

        policy = jsonencode({
            Version = "2012-10-17"
            Statement = [{
                Action   = [
                    "sqs:SendMessage",
                    "sqs:ReceiveMessage",
                    "sqs:DeleteMessage"
                ]
                Effect   = "Allow"
                Resource = "*"
            }]
        })
    }

    inline_policy {
        name = "AWSLambdaBasicExecutionRole"
        policy = jsonencode({
            Version = "2012-10-17"
            Statement = [{
                Action = [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ]
                Effect = "Allow"
                Resource = "*"
            }]
        })
    }
}

data "archive_file" "lambda_payload" {
    type = "zip"
    source_dir = "${path.module}/src"
    output_path = "${path.module}/payload.zip"
}

resource "aws_lambda_function" "sqs_send" {
    filename      = data.archive_file.lambda_payload.output_path
    function_name = "Discord_SQS_send"
    runtime       = "python3.7"
    role          = aws_iam_role.lambda_sqs_job.arn
    handler       = "lambda_function.lambda_handler"

    source_code_hash = data.archive_file.lambda_payload.output_base64sha256

    environment {
        variables = {
            discord_public_key = var.discord_public_key
            sqs_access_key = var.sqs_access_key
            sqs_secret_key = var.sqs_secret_key
            sqs_queue_url = var.sqs_queue_url
        }
    }
}

resource "aws_apigatewayv2_api" "discordSlashCommand" {
    name          = "DiscordSlashCommand"
    protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "terraform_test" {
    api_id = aws_apigatewayv2_api.discordSlashCommand.id

    name        = "serverless_lambda_stage"
    auto_deploy = true

    access_log_settings {
        destination_arn = aws_cloudwatch_log_group.api_gw.arn

        format = jsonencode({
            requestId               = "$context.requestId"
            sourceIp                = "$context.identity.sourceIp"
            requestTime             = "$context.requestTime"
            protocol                = "$context.protocol"
            httpMethod              = "$context.httpMethod"
            resourcePath            = "$context.resourcePath"
            routeKey                = "$context.routeKey"
            status                  = "$context.status"
            responseLength          = "$context.responseLength"
            integrationErrorMessage = "$context.integrationErrorMessage"
        })
    }
}

resource "aws_apigatewayv2_integration" "discordSlashCommand" {
    api_id = aws_apigatewayv2_api.discordSlashCommand.id

    integration_uri    = aws_lambda_function.sqs_send.invoke_arn
    integration_type   = "AWS_PROXY"
    integration_method = "POST"
}

resource "aws_apigatewayv2_route" "main" {
    api_id = aws_apigatewayv2_api.discordSlashCommand.id

    route_key = "POST /"
    target    = "integrations/${aws_apigatewayv2_integration.discordSlashCommand.id}"
}

resource "aws_cloudwatch_log_group" "api_gw" {
    name = "/aws/api_gw/${aws_apigatewayv2_api.discordSlashCommand.name}"
    retention_in_days = 30
}

resource "aws_lambda_permission" "api_gw" {
    statement_id  = "AllowExecutionFromAPIGateway"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.sqs_send.function_name
    principal     = "apigateway.amazonaws.com"
    source_arn = "${aws_apigatewayv2_api.discordSlashCommand.execution_arn}/*/*"
}
