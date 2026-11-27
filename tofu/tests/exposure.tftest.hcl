mock_provider "cloudflare" {
  mock_data "cloudflare_zero_trust_access_identity_providers" {
    defaults = {
      result = [
        { id = "otp-id", type = "onetimepin", name = "One-time PIN", config = null, read_only = null, saml_certificate_set = null, saml_certificate_set_id = null, scim_config = null },
        { id = "google-id", type = "google", name = "Google", config = null, read_only = null, saml_certificate_set = null, saml_certificate_set_id = null, scim_config = null },
      ]
    }
  }
}

variables {
  account_id            = "00000000000000000000000000000000"
  state_passphrase      = "test-only-passphrase-not-a-secret"
  access_allowed_emails = "owner@example.com"
}

run "no_expose_creates_no_dns_or_access" {
  command = plan
  variables {
    apps_file = "tests/fixtures/no-expose.yaml"
  }
  assert {
    condition     = length(cloudflare_dns_record.app) == 0
    error_message = "an app without expose must not get a DNS record"
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.app) == 0
    error_message = "an app without expose must not get an Access application"
  }
}

run "access_defaults_to_private" {
  command = plan
  variables {
    apps_file = "tests/fixtures/default-access.yaml"
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.app["blog"].domain == "blog.kimanlab.online"
    error_message = "an expose without access must be protected by Access"
  }
}

run "public_has_dns_without_access" {
  command = plan
  variables {
    apps_file = "tests/fixtures/public.yaml"
  }
  assert {
    condition     = length(cloudflare_dns_record.app) == 1
    error_message = "a public app needs a DNS record"
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.app) == 0
    error_message = "a public app must not get an Access application"
  }
}

run "only_listed_emails_are_allowed" {
  command = plan
  variables {
    apps_file             = "tests/fixtures/default-access.yaml"
    access_allowed_emails = "a@example.com, b@example.com"
  }
  assert {
    condition     = toset([for rule in cloudflare_zero_trust_access_policy.allowed_emails[0].include : rule.email.email]) == toset(["a@example.com", "b@example.com"])
    error_message = "the policy must include exactly the configured emails"
  }
}

run "empty_email_list_fails" {
  command = plan
  variables {
    apps_file             = "tests/fixtures/default-access.yaml"
    access_allowed_emails = ""
  }
  expect_failures = [var.access_allowed_emails]
}

run "unknown_access_value_fails" {
  command = plan
  variables {
    apps_file = "tests/fixtures/unknown-access.yaml"
  }
  expect_failures = [terraform_data.apps_guard]
}

run "null_access_value_fails" {
  command = plan
  variables {
    apps_file = "tests/fixtures/null-access.yaml"
  }
  expect_failures = [terraform_data.apps_guard]
}

run "unknown_expose_key_fails" {
  command = plan
  variables {
    apps_file = "tests/fixtures/unknown-expose-key.yaml"
  }
  expect_failures = [terraform_data.apps_guard]
}

run "unknown_app_key_fails" {
  command = plan
  variables {
    apps_file = "tests/fixtures/unknown-app-key.yaml"
  }
  expect_failures = [terraform_data.apps_guard]
}

run "ingress_ends_with_404" {
  command = plan
  variables {
    apps_file = "tests/fixtures/default-access.yaml"
  }
  assert {
    condition     = cloudflare_zero_trust_tunnel_cloudflared_config.homeserver.config.ingress[0].service == "http://blog:80"
    error_message = "the exposed app must be routed to its service"
  }
  assert {
    condition     = cloudflare_zero_trust_tunnel_cloudflared_config.homeserver.config.ingress[length(cloudflare_zero_trust_tunnel_cloudflared_config.homeserver.config.ingress) - 1].service == "http_status:404"
    error_message = "the last ingress rule must reject unknown hostnames"
  }
}

run "private_apps_allow_google_login_only" {
  command = plan
  variables {
    apps_file = "tests/fixtures/default-access.yaml"
  }
  assert {
    condition     = toset(cloudflare_zero_trust_access_application.app["blog"].allowed_idps) == toset(["google-id"])
    error_message = "private apps must accept the Google login method only"
  }
}

run "missing_google_login_fails" {
  command = plan
  variables {
    apps_file = "tests/fixtures/default-access.yaml"
  }
  override_data {
    target = data.cloudflare_zero_trust_access_identity_providers.configured
    values = {
      result = [{ id = "otp-id", type = "onetimepin", name = "One-time PIN", config = null, read_only = null, saml_certificate_set = null, saml_certificate_set_id = null, scim_config = null }]
    }
  }
  expect_failures = [cloudflare_zero_trust_access_application.app]
}
