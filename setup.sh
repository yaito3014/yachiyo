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

for v in ID_HOST; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { echo "error: $v is not set in .env" >&2; exit 1; }
done

# Optional: space-separated hostnames, IPs or CIDRs whose X-Forwarded-*
# headers Authentik should trust. Hostnames are resolved below, at render time
# (re-run setup.sh and reload Caddy if one's IP changes). Empty means
# private_ranges, which no internet client is in, so nothing outside this host
# is trusted.
ID_TRUSTED_PROXIES=${ID_TRUSTED_PROXIES:-private_ranges}
case "$ID_TRUSTED_PROXIES" in
    *[!0-9A-Za-z.:/_\ -]*)
        echo "error: ID_TRUSTED_PROXIES must be space-separated hostnames, IPs or CIDRs" >&2; exit 1 ;;
esac
export ID_TRUSTED_PROXIES

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
import ipaddress, os, socket, sys
tmpl, out = sys.argv[1], sys.argv[2]

def trusted_proxies(value):
    # Caddy's trusted_proxies takes only IPs/CIDRs, so resolve hostnames here.
    ranges = []
    for tok in value.split():
        if tok == "private_ranges":
            ranges.append(tok)
            continue
        try:
            ranges.append(str(ipaddress.ip_network(tok, strict=False)))
            continue
        except ValueError:
            pass
        try:
            ips = sorted({ai[4][0] for ai in socket.getaddrinfo(tok, None)})
        except socket.gaierror as e:
            sys.exit(f"error: cannot resolve {tok} in ID_TRUSTED_PROXIES: {e}")
        print(f"resolved {tok} -> {' '.join(ips)}")
        ranges += [str(ipaddress.ip_network(ip)) for ip in ips]
    return " ".join(ranges)

text = open(tmpl).read()
text = text.replace("{{ID_HOST}}", os.environ.get("ID_HOST", ""))
text = text.replace("{{ID_TRUSTED_PROXIES}}", trusted_proxies(os.environ["ID_TRUSTED_PROXIES"]))
if "{{" in text:
    sys.exit(f"error: unrendered placeholder remains in {out}")
open(out, "w").write(text)
print(f"rendered {out}")
PYEOF

echo "done. next: docker compose up -d  (first boot runs DB migrations — give it a minute)"
