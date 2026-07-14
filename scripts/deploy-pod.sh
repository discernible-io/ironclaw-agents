#!/usr/bin/env bash
# Recreate the IronClaw Podman pod: ironclaw-reborn + nginx TLS sidecar.
#
# Required:
#   APP_DIR or IRONCLAW_APP_DIR — host app root (default: ../ironclaw-app)
#   REBORN_IMAGE — full image ref
#   NGINX_IMAGE — full image ref
#
# Optional:
#   TARGET / IRONCLAW_DEPLOY_TIER — development|main
#   POD_NAME, APP_CONTAINER_NAME, NGINX_CONTAINER_NAME
#   SKIP_PULL=1

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=lib-podman.sh
source "$SCRIPT_DIR/lib-podman.sh"

APP_DIR="$(ironclaw_app_dir)"
export APP_DIR IRONCLAW_APP_DIR="$APP_DIR"

REBORN_IMAGE="${REBORN_IMAGE:?REBORN_IMAGE is required}"
NGINX_IMAGE="${NGINX_IMAGE:?NGINX_IMAGE is required}"

POD_NAME="${POD_NAME:-ironclaw-pod}"
APP_CONTAINER_NAME="${APP_CONTAINER_NAME:-ironclaw-reborn}"
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-ironclaw-nginx}"
SECRETS_FILE="${APP_DIR}/secrets/secrets.env"

require_podman() {
  command -v podman >/dev/null 2>&1 || { echo "podman not found" >&2; exit 1; }
}

require_podman
ironclaw_load_secrets
DEPLOY_TIER="$(ironclaw_deploy_tier)"
APP_PORT="$(ironclaw_tier_port)"
DOMAIN="$(ironclaw_tier_domain)"
z="$(ironclaw_selinux_mount_suffix)"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing ${SECRETS_FILE} — run ./ironclaw.sh init" >&2
  exit 1
fi
if [[ ! -f "${APP_DIR}/certs/fullchain.pem" || ! -f "${APP_DIR}/certs/privkey.pem" ]]; then
  echo "Missing TLS material under ${APP_DIR}/certs/ — run ./ironclaw.sh generate-certs" >&2
  exit 1
fi

ironclaw_ensure_app_layout
ironclaw_prepare_data_dir
ironclaw_normalize_tls_certs

if [[ "${SKIP_PULL:-0}" != 1 ]]; then
  podman pull "$REBORN_IMAGE" || true
  podman pull "$NGINX_IMAGE" || true
fi

podman image exists "$REBORN_IMAGE" || { echo "Missing image: $REBORN_IMAGE" >&2; exit 1; }
podman image exists "$NGINX_IMAGE" || { echo "Missing image: $NGINX_IMAGE" >&2; exit 1; }

echo "==> Recreating pod ${POD_NAME} (tier=${DEPLOY_TIER}, port=${APP_PORT}, domain=${DOMAIN})"
podman pod exists "$POD_NAME" && podman pod rm -f "$POD_NAME" || true
podman pod create --name "$POD_NAME" -p "${APP_PORT}:${APP_PORT}"

mkdir -p "${APP_DIR}/logs"
chmod 755 "${APP_DIR}/logs" || true

# Drop deploy-only keys that are not needed inside the Reborn process.
# Podman --env-file still injects IRONCLAW_* serve vars from secrets.env.
podman run -d \
  --log-driver=k8s-file \
  --pod "$POD_NAME" \
  --name "$APP_CONTAINER_NAME" \
  --restart=unless-stopped \
  --env-file "$SECRETS_FILE" \
  -e "IRONCLAW_REBORN_HOME=/data/ironclaw-reborn" \
  -e "IRONCLAW_REBORN_SERVE_HOST=127.0.0.1" \
  -e "IRONCLAW_REBORN_SERVE_PORT=3000" \
  -v "${APP_DIR}/data/ironclaw-reborn:/data/ironclaw-reborn:rw${z}" \
  -v "${APP_DIR}/logs:/workspace/logs:rw${z}" \
  "$REBORN_IMAGE"

podman container exists "$APP_CONTAINER_NAME"

mkdir -p "${APP_DIR}/logs/nginx"
chmod 0775 "${APP_DIR}/logs/nginx" || true
podman unshare chown -R 101:101 "${APP_DIR}/logs/nginx" || true
ironclaw_normalize_tls_certs

podman run -d \
  --log-driver=k8s-file \
  --pod "$POD_NAME" \
  --name "$NGINX_CONTAINER_NAME" \
  --restart=unless-stopped \
  -v "${APP_DIR}/certs:/app/certs:ro${z}" \
  -v "${APP_DIR}/logs/nginx:/var/log/nginx:rw${z}" \
  "$NGINX_IMAGE"

echo "==> Pod containers:"
podman ps --pod
echo "==> Health URL: https://${DOMAIN}:${APP_PORT}/api/health"
