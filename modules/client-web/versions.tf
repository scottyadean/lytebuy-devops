terraform {
  required_version = ">= 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      # CloudFront certificates must come from us-east-1 regardless of where the
      # rest of the stack lives, so this module needs both providers passed in.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
