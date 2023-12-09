locals {
  lambdas = [
    "github-sync",
    "migrate",
    "handle-coverage"
  ]

  # create a map of lambdas and their environment variables
  lambda_overrides = {
    "github-sync" = {
      timeout = 900
      environment = {
        variables = {
          DATABASE_HOST     = aws_instance.db.public_ip
          DATABASE_PORT     = 5432
          DATABASE_USER     = var.db_user
          DATABASE_PASSWORD = var.db_password
          DATABASE_NAME     = var.db_database

          GITHUB_ACCESS_TOKEN = var.github_token
        }
      }
    },
    "migrate" = {
      timeout = 60
      environment = {
        variables = {
          DATABASE_HOST     = aws_instance.db.public_ip
          DATABASE_PORT     = 5432
          DATABASE_USER     = var.db_user
          DATABASE_PASSWORD = var.db_password
          DATABASE_NAME     = var.db_database
        }
      }
    },
    "handle-coverage" = {
      timeout = 900
      environment = {
        variables = {
          DATABASE_HOST     = aws_instance.db.public_ip
          DATABASE_PORT     = 5432
          DATABASE_USER     = var.db_user
          DATABASE_PASSWORD = var.db_password
          DATABASE_NAME     = var.db_database

          GITHUB_ACCESS_TOKEN = var.github_token
        }
      }
    },
  }
}

data "aws_iam_policy_document" "assume_lambda_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

// create lambda role, that lambda function can assume (use)
resource "aws_iam_role" "lambda" {
  name               = "AssumeLambdaRole"
  description        = "Role for lambda to assume lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_role.json
}


data "aws_iam_policy_document" "allow_lambda_logging" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "arn:aws:logs:*:*:*",
    ]
  }
}

data "aws_iam_policy_document" "allow_lambda_sqs" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
    ]

    resources = [
      aws_sqs_queue.corecheck_queue.arn,
    ]
  }
}

resource "aws_iam_policy" "function_sqs_policy" {
  name        = "AllowLambdaSQSPolicy"
  description = "Policy for lambda sqs"
  policy      = data.aws_iam_policy_document.allow_lambda_sqs.json
}

resource "aws_iam_role_policy_attachment" "lambda_sqs_policy_attachment" {
  role       = aws_iam_role.lambda.id
  policy_arn = aws_iam_policy.function_sqs_policy.arn
}

// create a policy to allow writing into logs and create logs stream
resource "aws_iam_policy" "function_logging_policy" {
  name        = "AllowLambdaLoggingPolicy"
  description = "Policy for lambda cloudwatch logging"
  policy      = data.aws_iam_policy_document.allow_lambda_logging.json
}

// attach policy to out created lambda role
resource "aws_iam_role_policy_attachment" "lambda_logging_policy_attachment" {
  role       = aws_iam_role.lambda.id
  policy_arn = aws_iam_policy.function_logging_policy.arn
}

# AWSLambdaVPCAccessExecutionRole
data "aws_iam_policy" "lambda_vpc_access" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_s3_object" "lambda_zip" {
  provider = aws.compute_region
  for_each = toset(local.lambdas)
  bucket   = aws_s3_bucket.corecheck-lambdas.id
  key      = "${each.value}.zip"
}

resource "aws_cloudwatch_log_group" "function_logs" {
  for_each = toset(local.lambdas)
  name     = "/aws/lambda/${each.value}"
  provider = aws.compute_region

  retention_in_days = 7

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = false
  }
}

resource "aws_lambda_function" "function" {
  for_each = toset(local.lambdas)

  provider = aws.compute_region
  function_name = each.value
  description   = "Syncs github repositories with the database"
  role          = aws_iam_role.lambda.arn
  handler       = each.value
  memory_size   = 128
  architectures = ["arm64"]
  timeout       = local.lambda_overrides[each.value].timeout

  s3_key            = data.aws_s3_object.lambda_zip[each.value].key
  s3_object_version = data.aws_s3_object.lambda_zip[each.value].version_id
  s3_bucket         = aws_s3_bucket.corecheck-lambdas.id

  environment {
    variables = local.lambda_overrides[each.value].environment.variables
  }

  runtime = "provided.al2"
}


resource "aws_lambda_invocation" "invoke" {
  function_name = "migrate"
  input         = "{\"action\": \"up\"}"
  depends_on = [
    aws_lambda_function.function,
  ]
}

# state machine role
resource "aws_iam_role" "state_machine_role" {
  name = "state_machine_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "states.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# state machine policy (batch + lambda), create managed-rule
#   - events:PutTargets
#   - events:PutRule
#   - events:DescribeRule
resource "aws_iam_role_policy" "state_machine_policy" {
  name = "state_machine_policy"
  role = aws_iam_role.state_machine_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "batch:SubmitJob",
        "batch:TerminateJob",
        "batch:DescribeJobs",
        "batch:DescribeJobDefinitions",
        "batch:DescribeJobQueues",
        "batch:RegisterJobDefinition"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "events:PutTargets",
        "events:PutRule",
        "events:DescribeRule"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

# statemachine resource
resource "aws_sfn_state_machine" "state_machine" {
  name     = "start-jobs"
  role_arn = aws_iam_role.state_machine_role.arn
  provider = aws.compute_region

  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "StartAt": "Start coverage",
  "States": {
    "Start coverage": {
      "Type": "Task",
      "Resource": "arn:aws:states:::batch:submitJob.sync",
      "Parameters": {
        "Parameters.$": "$.params",
        "JobDefinition": "${aws_batch_job_definition.coverage_job.arn}",
        "JobName": "coverage",
        "JobQueue": "${aws_batch_job_queue.coverage_queue.arn}"
      },
      "Next": "Handle coverage",
      "ResultPath": "$.coverage_job"
    },
    "Handle coverage": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "handle-coverage:$LATEST",
        "Payload.$": "$"
      },
      "End": true
    }
  }
}
EOF
}
