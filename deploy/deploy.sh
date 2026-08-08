#!/usr/bin/env bash
#
# Deploys the bugseeker release to the VPS over Tailscale SSH.
# Usage: deploy/deploy.sh <vps-host>
#
# Example:
#   MIX_ENV=prod mix release
#   deploy/deploy.sh bugseeker-vps
#
set -euo pipefail

VPS_HOST="${1:?usage: deploy.sh <vps-host>}"
REMOTE_DIR="/opt/bugseeker"
REL_DIR="_build/prod/rel/bugseeker"

if [ ! -x "$REL_DIR/bin/bugseeker" ]; then
  echo "Release not found at $REL_DIR. Run: MIX_ENV=prod mix release"
  exit 1
fi

echo "==> Building tarball"
TARBALL_PATH="/tmp/bugseeker-$(date +%s).tar.gz"
tar -czf "$TARBALL_PATH" -C "$(dirname "$REL_DIR")" "$(basename "$REL_DIR")"

echo "==> Copying to $VPS_HOST"
scp "$TARBALL_PATH" "root@$VPS_HOST:/tmp/bugseeker.tar.gz"
rm -f "$TARBALL_PATH"

echo "==> Extracting and restarting on $VPS_HOST"
ssh "root@$VPS_HOST" bash -s <<'REMOTE'
set -euo pipefail
mkdir -p /opt/bugseeker
tar -xzf /tmp/bugseeker.tar.gz -C /opt/bugseeker
rm -f /tmp/bugseeker.tar.gz

# Run pending migrations (requires env vars from /etc/bugseeker.env).
cd /opt/bugseeker
set -a; . /etc/bugseeker.env; set +a
bin/bugseeker eval "Bugseeker.Release.migrate()"

systemctl restart bugseeker
sleep 3
systemctl --no-pager -l status bugseeker || true
curl -fsS http://localhost:4000/healthz && echo " -> healthz OK"
REMOTE

echo "==> Deploy finished"
