variable "account_id" {
  type = string
}

variable "state_passphrase" {
  type      = string
  sensitive = true
}

variable "access_allowed_emails" {
  description = "Comma separated emails that may pass Cloudflare Access"
  type        = string

  validation {
    condition     = length([for email in split(",", var.access_allowed_emails) : email if can(regex("^[^@\\s]+@[^@\\s]+$", trimspace(email)))]) == length(split(",", var.access_allowed_emails))
    error_message = "access_allowed_emails must be a non-empty comma separated list of emails."
  }
}

variable "apps_file" {
  type    = string
  default = "../apps.yaml"
}
