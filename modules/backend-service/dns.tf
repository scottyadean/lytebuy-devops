# Reuse the EXISTING Route53 zone and the *.lytebuy.com wildcard ACM cert that
# lytebuy-blog-service already provisioned - no new zone or cert. Looked up by
# name so a wrong assumption fails loudly at plan time instead of hardcoding an
# ARN that might drift.

data "aws_route53_zone" "root" {
  name         = "${var.root_domain}."
  private_zone = false
}

# The regional cert (us-west-2) for the ALB HTTPS listener.
#
# LOOKED UP BY THE APEX, NOT THE WILDCARD. `domain` matches a certificate's
# PRIMARY DomainName only - it does not search the SANs. The real cert is
# DomainName "lytebuy.com" with "*.lytebuy.com" as a SAN, so querying
# "*.lytebuy.com" here returned "reading ACM Certificates: empty result" even
# though the right certificate was sitting there. Verified with
# `aws acm describe-certificate`: DomainName=lytebuy.com,
# SubjectAlternativeNames=[lytebuy.com, *.lytebuy.com].
#
# That SAN is what covers dev-api.lytebuy.com.
data "aws_acm_certificate" "wildcard" {
  domain      = var.root_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# api_hostname -> ALB (alias, so it auto-follows the ALB even if recreated).
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.root.zone_id
  name    = var.api_hostname
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_aaaa" {
  zone_id = data.aws_route53_zone.root.zone_id
  name    = var.api_hostname
  type    = "AAAA"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
