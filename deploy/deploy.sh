#!/usr/bin/env bash
#
# Deploys the codeseeker release to the VPS over Tailscale SSH.
# Usage: deploy/deploy.sh <vps-host> [release-tarball]
#
# Example:
#   MIX_ENV=prod mix release codeseeker
#   deploy/deploy.sh codeseeker-vps
#
set -euo pipefail

VPS_HOST="${1:?usage: deploy.sh <vps-host> [release-tarball]}"
TARBALL="${2:-_build/prod/codeseeker-*.tar.gz}"
REMOTE_DIR="/opt/codeseeker"

# Resolve the tarball (glob)
TARBALL_PATH="$(echo $TARBALL)"
if [ ! -f "$TARBALL_PATH" ]; then
  echo "Release tarball not found: $TARBALL_PATH (run: MIX_ENV=prod mix release codeseeker)"
  exit 1
fi

echo "==> Copying $TARBALL_PATH to $VPS_HOST"
scp "$TARBALL_PATH" "root@$VPS_HOST:/tmp/codeseeker.tar.gz"

echo "==> Extracting and restarting on $VPS_HOST"
ssh "root@$VPS_HOST" bash -s <<'REMOTE'
set -euo pipefail
mkdir -p /opt/codeseeker
tar -xzf /tmp/codeseeker.tar.gz -C /opt/codeseeker
rm -f /tmp/codeseeker.tar.gz

# Run migrations if the release has an eval hook; otherwise nothing to do.
# (No database in this project, so no migrations are needed.)

systemctl restart codeseeker
sleep 3
systemctl --no-pager -l status codeseeker --no-pager || true
curl -fsS http://localhost:4000/healthz && echo " -> healthz OK"
REMOTE

echo "==> Deploy finished"
