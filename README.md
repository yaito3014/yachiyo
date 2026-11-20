# yachiyo

Self-hosted [Authentik](https://goauthentik.io) identity provider, on its own
VPS. Replaces Dex as the OIDC provider for the stack (Headscale, Lore CLI, Lore
web), adding self-service registration, email verification, password reset, and
social login (GitHub) — things Dex does not do.

Authentik runs as server + worker + PostgreSQL + Redis; Caddy terminates TLS for
`ID_HOST` and proxies to it. Apps log in over OIDC. Sites that need a login
but don't speak OIDC (iroha's `live` site) use forward auth against the
**embedded** outpost, which runs inside the server, so the Docker socket is not
mounted.

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
`docker compose up -d` to apply. `AUTHENTIK_EMAIL__FROM` must be an address on a
domain that is verified in Resend and that the API key may send from; Resend
rejects other senders ("This API key is not authorized to send emails from
..."). Add the SPF/DKIM/DMARC records Resend shows for your
sending domain to DNS so mail is not marked as spam. Email features
(verification, password reset) stay inert until this is set.

## OIDC clients

Create an OIDC provider + application in Authentik for each: Headscale
(confidential, code flow), the Lore CLI (public, device code flow), and the Lore
web frontend (public, code + PKCE, redirect `https://<app host>/auth/callback`).
Each application's issuer is `https://<ID_HOST>/application/o/<app-slug>/`.
Give each provider the scope mapping `fleet: email (verified)` (from
[the sign-up blueprint](#sign-up)) for its `email` claim: kaguya-auth keys
identity on the verified email, and Headscale admits users by it.

## Sign-up

`authentik/blueprints/fleet-signup.yaml` sets up self-service sign-up. Authentik
applies it by itself (the directory is mounted at `/blueprints/custom`) and
again whenever the file changes.

- **Email + password:** "Sign up" on the login page. The account stays
  inactive until the link in the verification email is opened, so it needs the
  SMTP settings above.
- **GitHub:** a "GitHub" button on the login page, once the OAuth app is set
  (below). A GitHub login that matches no linked account creates a new one;
  existing users link GitHub under User settings -> Connected services.
- **Verified email.** `email_verified` is true only while a user's email equals
  their `verified_email` attribute. The verification email sets it, GitHub
  sets it for a primary address GitHub verified, and an admin can set it by
  hand (for accounts created in the admin UI). Users cannot change their
  email unless that is turned on in Authentik's system settings; if it is, a
  changed email is unverified.
- **No app access by default.** New accounts can sign in to Authentik only.
  Add them to `tailnet` for Headscale (whose email allowlist still applies)
  or `lore` for Lore; iroha's `live` needs `streamers`.

GitHub OAuth app: at GitHub -> Settings -> Developer settings -> OAuth Apps ->
New OAuth App, set the homepage to `https://<ID_HOST>` and the callback URL to
`https://<ID_HOST>/source/oauth/callback/github/`, generate a client secret,
put both in `.env` (`GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`), then
`docker compose up -d`. Remove them and run it again to turn GitHub off;
the source is then left in place, so also disable it in the admin UI.

## Forward auth (embedded outpost)

A site on another host can require an Authentik login through that host's
Caddy, using `forward_auth https://<ID_HOST>` and
`uri /outpost.goauthentik.io/auth/caddy` (iroha's `live` does this). For that:

- In Authentik, create a Proxy provider in forward-auth (single application)
  mode for the site's host, plus an application for it, and bind it to the
  embedded outpost.
- Put the other host's hostname in `ID_TRUSTED_PROXIES` in `.env` (e.g.
  `iroha.example.com`; space-separate several; IPs and CIDRs also work), then
  run `./setup.sh` and `docker compose exec -w /etc/caddy caddy caddy reload`.
  Without this, this Caddy replaces the `X-Forwarded-Host/Proto` headers that
  host sends, and the outpost cannot tell which application the request is for.
- Caddy only accepts IPs here, so setup.sh resolves the hostnames when it
  renders. If that host's IP changes, run the same two commands again. The
  nightly update never re-renders configs.

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
- A Postgres major upgrade (a Renovate `[manual-deploy]` bump) is a dump and
  restore. Since 18 the image keeps each major version's data in its own
  `/var/lib/postgresql/<major>/docker` inside the volume, so the new version
  starts empty next to the old data, which stays there for rollback:

      docker compose stop server worker
      docker compose exec -T postgresql sh -c \
          'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > authentik.pgdump
      git pull                        # the new Postgres version
      docker compose up -d postgresql
      docker compose exec -T postgresql sh -c \
          'pg_restore --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < authentik.pgdump
      docker compose up -d

  Remove the old version's directory once the new one has run for a while.
