locals {
  zone_name     = "kimanlab.online"
  app_keys      = ["name", "data", "env", "expose"]
  expose_keys   = ["hostname", "service", "access"]
  access_values = ["private", "public"]

  apps    = yamldecode(file(var.apps_file)).apps
  exposed = { for app in local.apps : app.name => app.expose if contains(keys(app), "expose") }
  # anything that is not explicitly public stays behind Access
  private = { for name, expose in local.exposed : name => expose if try(expose.access, "private") != "public" }
}

resource "terraform_data" "apps_guard" {
  lifecycle {
    precondition {
      condition     = alltrue([for app in local.apps : length(setsubtract(keys(app), local.app_keys)) == 0])
      error_message = "apps.yaml has an unknown app key."
    }
    precondition {
      condition     = alltrue([for expose in values(local.exposed) : length(setsubtract(keys(expose), local.expose_keys)) == 0])
      error_message = "apps.yaml has an unknown expose key."
    }
    precondition {
      condition = alltrue([
        for expose in values(local.exposed) :
        contains(keys(expose), "access") ? contains(local.access_values, coalesce(expose.access, "unset")) : true
      ])
      error_message = "apps.yaml access must be exactly \"private\" or \"public\"."
    }
  }
}
