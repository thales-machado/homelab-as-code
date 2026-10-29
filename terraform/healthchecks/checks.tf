data "healthchecksio_channel" "homelab" {
  kind = "webhook"
}

# Old "vaultwarden-backup" check, generalized; keeps the same id/ping URL
moved {
  from = healthchecksio_check.vaultwarden_backup
  to   = healthchecksio_check.sqlite_backup
}

resource "healthchecksio_check" "sqlite_backup" {
  name     = "sqlite-backup"
  schedule = "30 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 900
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "sqlite_backup_urahara" {
  name     = "sqlite-backup-urahara"
  schedule = "20 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 900
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "postgres_backup" {
  name     = "postgres-backup"
  schedule = "35 2 * * *"
  timezone = "America/Sao_Paulo"
  # 900s (15min) caused false alarms when the first attempt is SIGKILLed
  # (memory pressure on the RPi5 during the Immich dump) and Dagu's automatic
  # retry (interval_sec: 900) only finishes ~15min later. Seen twice in
  # production. 1500s (25min) covers one full retry without a false alarm.
  grace    = 1500
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_backup_zangetsu" {
  name     = "restic-backup-zangetsu"
  schedule = "40 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 2700
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_backup_urahara" {
  name     = "restic-backup-urahara"
  schedule = "45 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 2700
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_prune_zangetsu" {
  name     = "restic-prune-zangetsu"
  schedule = "0 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 3600
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_prune_urahara" {
  name     = "restic-prune-urahara"
  schedule = "30 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 3600
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "immich_album_naming" {
  name     = "immich-album-naming"
  schedule = "0 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 1800
  tags     = ["dagu"]
  channels = [data.healthchecksio_channel.homelab.id]
}

output "ping_urls" {
  value = {
    sqlite_backup          = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.sqlite_backup.id}"
    sqlite_backup_urahara  = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.sqlite_backup_urahara.id}"
    postgres_backup        = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.postgres_backup.id}"
    restic_backup_zangetsu = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.restic_backup_zangetsu.id}"
    restic_backup_urahara  = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.restic_backup_urahara.id}"
    restic_prune_zangetsu  = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.restic_prune_zangetsu.id}"
    restic_prune_urahara   = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.restic_prune_urahara.id}"
    immich_album_naming    = "https://healthchecks.lan.example.com/ping/${healthchecksio_check.immich_album_naming.id}"
  }
}
