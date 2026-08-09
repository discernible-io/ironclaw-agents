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
IDENTYCLAW_CONTAINER_NAME="${IDENTYCLAW_CONTAINER_NAME:-ironclaw-identyclaw}"
SECRETS_FILE="${APP_DIR}/secrets/secrets.env"
IDENTYCLAW_IMAGE="${IDENTYCLAW_IMAGE:-localhost/ironclaw-identyclaw:local}"

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
ironclaw_prepare_identyclaw_dirs
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
# Mount idcp CLI for agent shell (Hermes-shaped surface → private helper sidecar).
IDCP_SRC="${REPO_ROOT}/deploy/identyclaw"
DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
REBORN_VOLUMES=(
  -v "${APP_DIR}/data/ironclaw-reborn:/data/ironclaw-reborn:rw${z}"
  -v "${APP_DIR}/logs:/workspace/logs:rw${z}"
  -v "${IDCP_SRC}:/opt/idcp:ro${z}"
)
# Optional Migadu/Himalaya mail config from ironclaw-app (password via auth.cmd).
if [[ -f "${APP_DIR}/config/himalaya/config.container.toml" && -x "${APP_DIR}/secrets/himalaya/print-password.sh" ]]; then
  REBORN_VOLUMES+=(
    -v "${APP_DIR}/config/himalaya/config.container.toml:/home/ironclaw/.config/himalaya/config.toml:ro${z}"
    -v "${APP_DIR}/secrets/himalaya:/secrets/himalaya:ro${z}"
  )
fi
podman run -d \
  --log-driver=k8s-file \
  --pod "$POD_NAME" \
  --name "$APP_CONTAINER_NAME" \
  --restart=unless-stopped \
  --env-file "$SECRETS_FILE" \
  -e "IRONCLAW_REBORN_HOME=/data/ironclaw-reborn" \
  -e "IRONCLAW_REBORN_SERVE_HOST=127.0.0.1" \
  -e "IRONCLAW_REBORN_SERVE_PORT=3000" \
  -e "IDENTYCLAW_HELPER_BASE=${IDENTYCLAW_HELPER_BASE:-http://127.0.0.1:3921}" \
  -e "PATH=/opt/idcp/bin:${DEFAULT_PATH}" \
  -e "XDG_CONFIG_HOME=/home/ironclaw/.config" \
  "${REBORN_VOLUMES[@]}" \
  "$REBORN_IMAGE"

podman container exists "$APP_CONTAINER_NAME"

# IdentyClaw host helper (loopback). Starts when near-credentials exist or
# IRONCLAW_IDENTYCLAW_HELPER=1/true. Skip with IRONCLAW_IDENTYCLAW_HELPER=0.
want_identyclaw_helper() {
  local flag="${IRONCLAW_IDENTYCLAW_HELPER:-auto}"
  case "$flag" in
    0|false|FALSE|no|NO) return 1 ;;
    1|true|TRUE|yes|YES) return 0 ;;
    *)
      ironclaw_resolve_near_credentials >/dev/null 2>&1
      ;;
  esac
}

if want_identyclaw_helper; then
  if ! podman image exists "$IDENTYCLAW_IMAGE"; then
    echo "WARNING: IdentyClaw helper image missing ($IDENTYCLAW_IMAGE). Run: ./ironclaw.sh build-image" >&2
  else
    cred_file=""
    cred_file="$(ironclaw_resolve_near_credentials 2>/dev/null || true)"
    ironclaw_prepare_identyclaw_dirs
    helper_env=(
      -e "IDENTYCLAW_HELPER_HOST=${IDENTYCLAW_HELPER_HOST:-127.0.0.1}"
      -e "IDENTYCLAW_HELPER_PORT=${IDENTYCLAW_HELPER_PORT:-3921}"
      -e "IDENTYCLAW_BASE_URL=${IDENTYCLAW_BASE_URL:-https://api.identyclaw.com}"
      -e "IDENTYCLAW_NEAR_CREDENTIALS_DIR=/secrets/near-credentials"
      -e "IDENTYCLAW_SESSION_DIR=/data/identyclaw/sessions"
      -e "NEAR_CONTRACT_ID=${NEAR_CONTRACT_ID:-${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}}"
      -e "LOG_LEVEL=error"
      -e "SUPPRESS_NO_CONFIG_WARNING=true"
      -e "SUPPRESS_STRICTNESS_CHECK=true"
    )
    if [[ -n "$cred_file" ]]; then
      helper_env+=(-e "NEAR_CREDENTIALS_FILE_PATH=/secrets/near-credentials/$(basename "$cred_file")")
    fi
    echo "==> Starting IdentyClaw helper (${IDENTYCLAW_CONTAINER_NAME})"
    # --user 0:0: rootless host uid maps to container root; USER node cannot
    # read host-owned near-credentials / sessions (EACCES).
    podman run -d \
      --log-driver=k8s-file \
      --pod "$POD_NAME" \
      --name "$IDENTYCLAW_CONTAINER_NAME" \
      --user 0:0 \
      --restart=unless-stopped \
      "${helper_env[@]}" \
      -v "$(ironclaw_near_credentials_dir):/secrets/near-credentials:ro${z}" \
      -v "$(ironclaw_identyclaw_session_dir):/data/identyclaw/sessions:rw${z}" \
      "$IDENTYCLAW_IMAGE"
  fi
else
  echo "==> Skipping IdentyClaw helper (no near-credentials / IRONCLAW_IDENTYCLAW_HELPER=0)"
fi

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
