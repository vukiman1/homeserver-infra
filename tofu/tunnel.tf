resource "cloudflare_zero_trust_tunnel_cloudflared" "homeserver" {
  account_id = var.account_id
  name       = "homeserver-iac"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homeserver" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homeserver.id

  config = {
    ingress = concat(
      [for expose in values(local.exposed) : { hostname = expose.hostname, service = "http://${expose.service}" }],
      [{ service = "http_status:404" }],
    )
  }

  # routes must never go live before their Access protection exists
  depends_on = [terraform_data.apps_guard, cloudflare_zero_trust_access_application.app]
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homeserver" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homeserver.id
}
