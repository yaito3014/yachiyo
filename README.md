# yachiyo

Self-hosted [Authentik](https://goauthentik.io) identity provider, on its own
VPS. Replaces Dex as the OIDC provider for the stack (Headscale, Lore CLI, Lore
web), adding self-service registration, email verification, password reset, and
social login (GitHub) — things Dex does not do.

Authentik runs as server + worker + PostgreSQL + Redis; Caddy terminates TLS for
`ID_HOST` and proxies to it. Only OIDC is used (no proxy/LDAP outposts), so the
Docker socket is not mounted.

## Requirements

- A VPS with a public IP; ports 80/443 open; ~2GB RAM (4GB comfortable), Docker + Compose
- A CNAME for `ID_HOST` pointing at this VPS, DNS-only (grey cloud)
- `openssl` and `python3` for `setup.sh`
- For email (verification/reset): a Resend account + its SMTP key, with
  SPF/DKIM/DMARC records added in DNS (see below)

## Quick start

    cp .env.example .env
    $EDITOR .env          # ID_HOST (and SMTP once ready)
    ./setup.sh            # generates secrets, renders caddy/Caddyfile
    docker compose up -d  # first boot runs DB migrations — give it a minute

Then open `https://<ID_HOST>/if/flow/initial-setup/` to create the admin
account.

## Email (Resend)

Fill the `AUTHENTIK_EMAIL__*` values in `.env` (host `smtp.resend.com`, port 587,
username `resend`, password = the Resend API key, single-quoted), then
`docker compose up -d` to apply. Add the SPF/DKIM/DMARC records Resend shows for
your sending domain to DNS so mail is not marked as spam. Email features
(verification, password reset) stay inert until this is set.

## OIDC clients

Create an OIDC provider + application in Authentik for each: Headscale
(confidential, code flow), the Lore CLI (public, device code flow), and the Lore
web frontend (public, code + PKCE, redirect `https://<app host>/auth/callback`).
Each application's issuer is `https://<ID_HOST>/application/o/<app-slug>/`.
Ensure the `email` and `email_verified` claims are released (kaguya-auth keys
identity on the verified email). Enable a registration flow with an email-
verification stage and add GitHub as a federation source.

## Automated updates

Updates are pull-based: nothing outside this VPS can push to it.

- **Images:** [Renovate](https://github.com/apps/renovate) opens PRs that bump
  the image tags and digests pinned in `docker-compose.yml` (see `renovate.json`).
  Patch, minor and digest bumps merge automatically once CI passes. Major bumps,
  and Headscale/Authentik feature releases, wait for you and are marked
  `[manual-deploy]`.
- **Deploy:** a nightly `yachiyo-update` timer runs `ops/update.sh`. It
  fast-forwards to `origin/main`, pulls the images, backs up (`ops/stack.sh`),
  restarts, and health-checks. If the checks fail it rolls back to the previous
  commit and does not retry that commit. It does not deploy commits marked
  `[manual-deploy]`, or commits that change `*.tmpl`, `.env.example` or
  `setup.sh`; it sends a reminder each night instead.
- **OS:** unattended security upgrades, with a reboot at 05:40 if one is
  needed. Docker is held back, because upgrading the engine restarts every
  container.

Setup, once per VPS: install the Renovate GitHub app on this repo, add
`UPDATE_NOTIFY_URL` to `.env` (optional; an [ntfy](https://ntfy.sh) topic URL
works), then:

    sudo ops/install.sh               # timer at 04:00 + unattended-upgrades
    systemctl list-timers yachiyo-update  # next run
    journalctl -u yachiyo-update          # past runs

For a `[manual-deploy]` change: read the upstream notes, do any manual steps,
then run `ops/update.sh --force`. For Authentik, read the release's upgrade
notes first.

A change to `*.tmpl`, `.env.example` or `setup.sh` is always deployed by hand,
because `update.sh` never re-renders configs: `git pull`, `./setup.sh`, then
`docker compose pull && docker compose up -d`.

Backups go to `/var/backups/yachiyo/<time>-<previous commit>/` (newest 5 kept;
local only, so copy them off the host yourself). Rollback never restores data.
If a one-way migration ran and the old version cannot start, restore by hand
from that directory:

    docker compose stop server worker
    docker compose exec -T postgresql sh -c \
        'pg_restore --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < authentik.pgdump
    docker compose up -d

## Notes

- The Authentik release is pinned in `docker-compose.yml` (both `server` and
  `worker`). Renovate proposes bumps; review the upgrade notes before merging one.
- `AUTHENTIK_SECRET_KEY` and `PG_PASS` are generated once into `.env`; back them
  up (losing the secret key invalidates sessions/tokens). The Postgres volume
  holds all users and config — include it in backups.
