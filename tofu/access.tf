# the Google OAuth client is configured by hand in the dashboard
data "cloudflare_zero_trust_access_identity_providers" "configured" {
  account_id = var.account_id
}

locals {
  google_login_ids = [
    for provider in data.cloudflare_zero_trust_access_identity_providers.configured.result : provider.id
    if provider.type == "google"
  ]
}

resource "cloudflare_zero_trust_access_policy" "allowed_emails" {
  count = length(local.private) > 0 ? 1 : 0

  account_id = var.account_id
  name       = "homeserver-allowed-emails"
  decision   = "allow"
  include    = [for email in split(",", var.access_allowed_emails) : { email = { email = trimspace(email) } }]
}

resource "cloudflare_zero_trust_access_application" "app" {
  for_each = local.private

  account_id                = var.account_id
  name                      = each.key
  domain                    = each.value.hostname
  type                      = "self_hosted"
  session_duration          = "24h"
  allowed_idps              = local.google_login_ids
  auto_redirect_to_identity = true
  policies                  = [{ id = cloudflare_zero_trust_access_policy.allowed_emails[0].id, precedence = 1 }]

  lifecycle {
    precondition {
      condition     = length(local.google_login_ids) == 1
      error_message = "Exactly one Google login method must be configured in Cloudflare Zero Trust."
    }
  }

  depends_on = [terraform_data.apps_guard]
}
