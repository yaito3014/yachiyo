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
    $EDITOR .env          # ID_HOST, AUTHENTIK_TAG (and SMTP once ready)
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

## Notes

- Pin `AUTHENTIK_TAG` to a specific release; review the upgrade notes before bumping.
- `AUTHENTIK_SECRET_KEY` and `PG_PASS` are generated once into `.env`; back them
  up (losing the secret key invalidates sessions/tokens). The Postgres volume
  holds all users and config — include it in backups.
