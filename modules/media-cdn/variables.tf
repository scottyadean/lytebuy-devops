variable "env" {
  description = "Environment name, used in resource names and comments."
  type        = string
}

variable "root_domain" {
  description = "Apex domain. The wildcard ACM certificate and the Route53 zone are both looked up from it."
  type        = string
  default     = "lytebuy.com"
}

variable "media_hostname" {
  description = "Hostname the CDN answers on, e.g. media.lytebuy.com. Must be covered by the wildcard certificate."
  type        = string
}

variable "media_bucket" {
  description = "Name of the existing media bucket this CDN fronts. Created by the backend-service module, not here."
  type        = string
}

variable "resize_widths" {
  description = <<-DESC
    Widths the resizer will produce, in pixels. A request for any other width
    is refused rather than generated, so a crawler cannot mint unlimited
    variants and bill us for the storage (lb-28).
  DESC
  type        = list(number)
  default     = [400, 800]
}

variable "resize_quality" {
  description = "WebP quality for derived images. 80 is the usual sweet spot - visually indistinguishable from the original at thumbnail size, roughly a tenth the bytes."
  type        = number
  default     = 80
}

variable "media_bucket_region" {
  description = "Region the media bucket lives in, for the S3 origin hostname. Passed in rather than inferred so the origin can never silently point at the wrong region."
  type        = string
}

variable "resize_zip_path" {
  description = "Path to the built Lambda bundle. Produced by function/build.sh, which compiles sharp for linux/arm64 inside the Lambda base image - a host-built bundle fails on every invocation."
  type        = string
}
