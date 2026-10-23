#!/bin/sh
# One-time host setup for automated updates. Run on the VPS, as root:
#   sudo ops/install.sh
# - installs a <stack>-update systemd timer that runs ops/update.sh nightly
#   as the repo owner (who must be in the docker group);
# - enables unattended OS security upgrades with a nightly reboot window.
# Schedules come from ops/stack.sh, staggered so the VPSes never go down together.
# Idempotent: re-run after changing the schedule.
set -eu
cd "$(dirname "$0")/.."

[ "$(id -u)" = 0 ] || { echo "error: run as root: sudo $0" >&2; exit 1; }
for cmd in git docker curl flock systemctl; do
    command -v "$cmd" >/dev/null || { echo "error: $cmd not found" >&2; exit 1; }
done

. ./ops/stack.sh    # STACK, UPDATE_ON_CALENDAR, REBOOT_TIME
repo=$(pwd -P)
user=$(stat -c %U "$repo")

id -nG "$user" | tr ' ' '\n' | grep -qx docker \
    || echo "warning: $user is not in the docker group; the update service runs as $user" >&2

# Default UPDATE_BACKUP_DIR; if you override it in .env, make it writable by $user.
install -d -m 700 -o "$user" "/var/backups/$STACK"

cat > "/etc/systemd/system/$STACK-update.service" <<EOF
[Unit]
Description=Auto-update the $STACK stack (git + images, with backup and rollback)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$user
ExecStart=$repo/ops/update.sh
TimeoutStartSec=1h
EOF

cat > "/etc/systemd/system/$STACK-update.timer" <<EOF
[Unit]
Description=Nightly auto-update of the $STACK stack

[Timer]
OnCalendar=$UPDATE_ON_CALENDAR
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$STACK-update.timer"
echo "installed $STACK-update.timer ($UPDATE_ON_CALENDAR, as $user)"

if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades >/dev/null
    [ -f /etc/apt/apt.conf.d/20auto-upgrades ] || cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    # Distro defaults already limit upgrades to security origins. Docker is held
    # back explicitly (Docker's own packages and the distro's): upgrading the
    # engine restarts every container.
    cat > /etc/apt/apt.conf.d/52vps-auto-update <<EOF
// Written by $repo/ops/install.sh
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker-compose-plugin";
    "docker-buildx-plugin";
    "docker.io";
    "containerd";
    "runc";
};
EOF
    echo "enabled unattended security upgrades (reboot window $REBOOT_TIME)"
else
    echo "warning: not a Debian/Ubuntu host; set up OS updates yourself" >&2
fi
