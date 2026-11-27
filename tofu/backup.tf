resource "cloudflare_r2_bucket" "backup" {
  account_id = var.account_id
  name       = "homeserver-backup"
  location   = "APAC"

  lifecycle {
    prevent_destroy = true
  }
}
