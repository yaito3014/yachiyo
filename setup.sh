#!/bin/sh
# Generate Authentik secrets into .env (once) and render caddy/Caddyfile.
# Idempotent: safe to re-run.
set -eu
cd "$(dirname "$0")"

[ -f .env ] || { echo "error: copy .env.example to .env and edit it first" >&2; exit 1; }

# Read .env literally (values may contain $, =, + from base64 secrets). Strip one
# layer of surrounding single quotes (used for the SMTP key).
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    case $val in
        \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    export "$key=$val"
done < .env

for v in ID_HOST AUTHENTIK_TAG; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { echo "error: $v is not set in .env" >&2; exit 1; }
done

# Generate a persistent secret into .env if empty. Uses '|' as the sed delimiter
# since base64 secrets contain '/' and '+' but never '|'.
gen_secret() {
    # $1: env var name, $2: value to store
    name=$1; value=$2
    if grep -q "^${name}=" .env; then
        sed -i.bak "s|^${name}=.*|${name}=${value}|" .env && rm -f .env.bak
    else
        printf '%s=%s\n' "$name" "$value" >> .env
    fi
    eval "$name=\$value"
    echo "generated $name (stored in .env)"
}

[ -n "${AUTHENTIK_SECRET_KEY:-}" ] || gen_secret AUTHENTIK_SECRET_KEY "$(openssl rand -base64 60 | tr -d '\n')"
[ -n "${PG_PASS:-}" ] || gen_secret PG_PASS "$(openssl rand -hex 32)"

mkdir -p caddy
python3 - caddy/Caddyfile.tmpl caddy/Caddyfile <<'PYEOF'
import os, sys
tmpl, out = sys.argv[1], sys.argv[2]
text = open(tmpl).read()
for k in ["ID_HOST"]:
    text = text.replace("{{%s}}" % k, os.environ.get(k, ""))
if "{{" in text:
    sys.exit(f"error: unrendered placeholder remains in {out}")
open(out, "w").write(text)
print(f"rendered {out}")
PYEOF

echo "done. next: docker compose up -d  (first boot runs DB migrations — give it a minute)"
