data "cloudflare_zone" "homeserver" {
  filter = {
    name = local.zone_name
  }
}

resource "cloudflare_dns_record" "app" {
  for_each = local.exposed

  zone_id = data.cloudflare_zone.homeserver.id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homeserver.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1

  depends_on = [terraform_data.apps_guard, cloudflare_zero_trust_access_application.app]
}
