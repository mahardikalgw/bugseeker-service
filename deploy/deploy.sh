#!/usr/bin/env bash
#
# Deploys the codeseeker release to the VPS over Tailscale SSH.
# Usage: deploy/deploy.sh <vps-host>
#
# Example:
#   MIX_ENV=prod mix release
#   deploy/deploy.sh codeseeker-vps
#
set -euo pipefail

VPS_HOST="${1:?usage: deploy.sh <vps-host>}"
REMOTE_DIR="/opt/codeseeker"
REL_DIR="_build/prod/rel/codeseeker"

if [ ! -x "$REL_DIR/bin/codeseeker" ]; then
  echo "Release not found at $REL_DIR. Run: MIX_ENV=prod mix release"
  exit 1
fi

echo "==> Building tarball"
TARBALL_PATH="/tmp/codeseeker-$(date +%s).tar.gz"
tar -czf "$TARBALL_PATH" -C "$(dirname "$REL_DIR")" "$(basename "$REL_DIR")"

echo "==> Copying to $VPS_HOST"
scp "$TARBALL_PATH" "root@$VPS_HOST:/tmp/codeseeker.tar.gz"
rm -f "$TARBALL_PATH"

echo "==> Extracting and restarting on $VPS_HOST"
ssh "root@$VPS_HOST" bash -s <<'REMOTE'
set -euo pipefail
mkdir -p /opt/codeseeker
tar -xzf /tmp/codeseeker.tar.gz -C /opt/codeseeker
rm -f /tmp/codeseeker.tar.gz

systemctl restart codeseeker
sleep 3
systemctl --no-pager -l status codeseeker || true
curl -fsS http://localhost:4000/healthz && echo " -> healthz OK"
REMOTE

echo "==> Deploy finished"
