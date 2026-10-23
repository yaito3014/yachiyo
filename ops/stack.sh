# Sourced by ops/update.sh and ops/install.sh: the yachiyo-specific parts.

STACK=yachiyo
# A new Authentik release runs DB migrations on first boot; give it time.
HEALTH_TIMEOUT=300

# Gitignored files needed to rebuild the host (.env, with the generated secrets,
# is always included).
CONFIG_FILES="caddy/Caddyfile"

# Host schedule (local time). Staggered across the fleet: iroha 02:00,
# kaguya 03:00, yachiyo 04:00; reboots 05:00 / 05:20 / 05:40.
UPDATE_ON_CALENDAR="*-*-* 04:00:00"
REBOOT_TIME="05:40"

stack_backup() {
    # pg_dump is consistent while live, so nothing needs stopping. Restore with
    # pg_restore --clean into the same Postgres major version.
    docker compose exec -T postgresql sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' \
        > "$1/authentik.pgdump" &&
        backup_volume server /media "$1/media.tgz" &&
        backup_volume server /templates "$1/custom-templates.tgz"
}

stack_health() {
    probe "$ID_HOST" /-/health/ready/
}
