#!/bin/sh
# Pull-based auto-deploy: fast-forward to origin/<branch>, pull images, back up,
# restart, health-check, and roll back on failure. Run nightly by the
# <stack>-update systemd timer (see ops/install.sh); safe to run by hand.
#
#   ops/update.sh           deploy new commits if they are safe to auto-deploy
#   ops/update.sh --force   also deploy commits marked [manual-deploy] (after
#                           doing the manual steps the release needs)
#
# Identical in every stack repo. Stack-specific parts (what to back up, how to
# tell the stack is healthy) live in ops/stack.sh. Optional UPDATE_* settings
# come from .env.
set -eu
cd "$(dirname "$0")/.."

force=0
case "${1:-}" in
    --force) force=1 ;;
    '') ;;
    *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

[ -f .env ] || { echo "error: .env missing; run setup first" >&2; exit 1; }

# Read .env literally, same rules as setup.sh. Do NOT source it.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    case $val in
        \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    export "$key=$val"
done < .env

# Pinned so the backup helper never pulls a moving tag; Renovate keeps it current.
BACKUP_IMAGE=busybox:1.38@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4

log() { echo "[${STACK:-update}] $*"; }

notify() {
    # $1: title, $2: body. Best effort: a failed notification never fails the run.
    log "$1: $2"
    [ -n "${UPDATE_NOTIFY_URL:-}" ] || return 0
    curl -fsS -m 10 -H "Title: $STACK: $1" -d "$2" "$UPDATE_NOTIFY_URL" >/dev/null \
        || log "warning: notification failed"
}

# probe <host> <path>: HTTPS GET through the local Caddy, bypassing DNS, so the
# check covers TLS + proxy + app without depending on hairpin routing.
probe() {
    curl -fsS -o /dev/null -m 5 --resolve "$1:443:127.0.0.1" "https://$1$2"
}

# backup_volume <service> <path in its container> <out file>: tar a volume via
# the service's (possibly stopped) container, streamed so the file is ours.
backup_volume() {
    cid=$(docker compose ps -aq "$1")
    [ -n "$cid" ] || { log "error: no container for service $1"; return 1; }
    docker run --rm --volumes-from "$cid:ro" "$BACKUP_IMAGE" \
        tar czf - -C "$2" . > "$3"
}

. ./ops/stack.sh    # STACK, HEALTH_TIMEOUT, CONFIG_FILES, stack_backup, stack_health

branch=${UPDATE_BRANCH:-main}
backup_root=${UPDATE_BACKUP_DIR:-/var/backups/$STACK}
keep=${UPDATE_BACKUP_KEEP:-5}
failed_file=.update-failed      # commit that failed health; not retried until superseded

exec 9>.update.lock
flock -n 9 || { log "another update is running"; exit 0; }

git fetch --quiet origin "$branch"
head=$(git rev-parse HEAD)
target=$(git rev-parse FETCH_HEAD)
[ "$head" != "$target" ] || exit 0

from=$(git rev-parse --short "$head")
to=$(git rev-parse --short "$target")

if ! git diff --quiet HEAD --; then
    notify "update blocked" "tracked files have local edits; commit or discard them (git status)"
    exit 1
fi
if ! git merge-base --is-ancestor "$head" "$target"; then
    notify "update blocked" "local HEAD $from is not an ancestor of origin/$branch $to"
    exit 1
fi
if [ "$force" = 0 ] && [ -f "$failed_file" ] && [ "$(cat "$failed_file")" = "$target" ]; then
    log "$to failed to deploy before; waiting for a newer commit or --force"
    exit 0
fi

# Gates: some changes need a human on the box. Template/env/setup changes mean
# configs must be re-rendered (for iroha, re-merged), which this script never
# does, so those are deployed by hand even with --force. Renovate marks risky
# image bumps [manual-deploy]; --force deploys those once you are ready.
changed=$(git diff --name-only "$head" "$target" -- '*.tmpl' .env.example setup.sh)
if [ -n "$changed" ]; then
    notify "manual deploy pending" "$from..$to changes setup inputs ($(echo $changed)); deploy by hand: git pull, ./setup.sh, then docker compose pull && docker compose up -d. See README."
    exit 0
fi
if [ "$force" = 0 ] && git log --format=%B "$head..$target" | grep -qF '[manual-deploy]'; then
    notify "manual deploy pending" "$from..$to has a commit marked [manual-deploy]. Do the manual steps, then run ops/update.sh --force."
    exit 0
fi

log "deploying $from..$to"
git merge --ff-only --quiet "$target"
. ./ops/stack.sh    # the target's hooks: its backup set and health check

# Pull before touching anything: a missing image (e.g. CI still building) costs
# no downtime, and the next run retries.
if ! docker compose pull --quiet; then
    git reset --hard --quiet "$head"
    notify "update failed" "image pull for $to failed; nothing changed, will retry next run"
    exit 1
fi

backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-$from"
if ! (
    umask 077
    mkdir -p "$backup_dir" &&
    tar czf "$backup_dir/config.tgz" .env $CONFIG_FILES &&
    stack_backup "$backup_dir"
); then
    git reset --hard --quiet "$head"
    docker compose up -d || true    # stack_backup may have stopped services
    notify "update failed" "backup to $backup_dir failed; stayed on $from"
    exit 1
fi
# Keep the newest $keep backups.
ls -1d "$backup_root"/*/ 2>/dev/null | sort | head -n "-$keep" | xargs -r rm -rf

services_ok() {
    # Every service running, and healthy where it defines a healthcheck.
    out=$(docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}') || return 1
    [ -n "$out" ] || return 1
    echo "$out" | awk '$2 != "running" || ($3 != "" && $3 != "healthy") { bad = 1 } END { exit bad }'
}

wait_healthy() {
    # Three consecutive passes, so a crash-looping container cannot slip through.
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    streak=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if services_ok && stack_health; then
            streak=$((streak + 1))
            [ "$streak" -lt 3 ] || return 0
        else
            streak=0
        fi
        sleep 5
    done
    return 1
}

if docker compose up -d && wait_healthy; then
    rm -f "$failed_file"
    docker image prune -f >/dev/null || true
    notify "updated" "$from..$to deployed; backup in $backup_dir"
    exit 0
fi

echo "$target" > "$failed_file"
log "$to failed to start or is unhealthy; state and logs follow, then rollback"
docker compose ps -a || true
docker compose logs --tail 50 || true

git reset --hard --quiet "$head"
. ./ops/stack.sh
if docker compose up -d && wait_healthy; then
    notify "update rolled back" "$to failed to start or failed health checks; back on $from. See: journalctl -u $STACK-update"
else
    notify "UPDATE FAILED, ROLLBACK UNHEALTHY" "$to failed and $from did not recover (a one-way migration may have run). Restore from $backup_dir; see README."
fi
exit 1
