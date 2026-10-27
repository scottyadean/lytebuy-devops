terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      # A CloudFront viewer certificate must live in us-east-1 regardless of
      # where the bucket is, so this module takes both providers.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
