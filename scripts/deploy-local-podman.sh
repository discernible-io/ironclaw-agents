#!/usr/bin/env bash
# Local Podman build + deploy for IronClaw Reborn HTTPS (SignPortal-style pod).
#
# Usage (repo root):
#   ./scripts/deploy-local-podman.sh
#   TARGET=main ./scripts/deploy-local-podman.sh
#   ./scripts/deploy-local-podman.sh --skip-build
#
# Env:
#   APP_DIR / IRONCLAW_APP_DIR   Default: ../ironclaw-agents-app
#   TARGET                       development|main
#   LOCAL_TAG                    Image tag (default: short git SHA)
#   USE_LOCAL_RESOLVE=1          curl --resolve to 127.0.0.1 for health

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=lib-podman.sh
source "$SCRIPT_DIR/lib-podman.sh"

APP_DIR="$(ironclaw_app_dir)"
export APP_DIR IRONCLAW_APP_DIR="$APP_DIR"

# Prefer an explicit tag (ironclaw.sh passes LOCAL_TAG=local). Fall back to
# git SHA only when invoked standalone without LOCAL_TAG / IRONCLAW_IMAGE_TAG.
if [[ -n "${IRONCLAW_IMAGE_TAG:-}" ]]; then
  LOCAL_TAG="$IRONCLAW_IMAGE_TAG"
elif [[ -z "${LOCAL_TAG:-}" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    LOCAL_TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  else
    LOCAL_TAG=local
  fi
fi

ironclaw_load_secrets
DEPLOY_TIER="$(ironclaw_deploy_tier)"
export TARGET="$DEPLOY_TIER"
APP_PORT="$(ironclaw_tier_port)"
DOMAIN="$(ironclaw_tier_domain)"
NGINX_BUILD_ENV="$(ironclaw_nginx_build_env)"
USE_LOCAL_RESOLVE="${USE_LOCAL_RESOLVE:-1}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-300}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-5}"

REBORN_IMAGE="localhost/ironclaw-reborn:${LOCAL_TAG}"
NGINX_IMAGE="localhost/ironclaw-nginx:${LOCAL_TAG}"
IDENTYCLAW_IMAGE="${IDENTYCLAW_IMAGE:-localhost/ironclaw-identyclaw:${LOCAL_TAG}}"
SECRETS_FILE="${APP_DIR}/secrets/secrets.env"

cd "$REPO_ROOT"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing secrets file: $SECRETS_FILE (run ./ironclaw.sh init)" >&2
  exit 1
fi

build_images() {
  # Prefer layered builds + Dockerfile cache mounts (cargo/pnpm).
  # Avoid --no-cache unless intentionally forcing a cold rebuild.
  echo "==> Building ${REBORN_IMAGE} (Dockerfile, layered)"
  podman build --layers -f "$REPO_ROOT/Dockerfile" -t "$REBORN_IMAGE" "$REPO_ROOT"
  echo "==> Building ${NGINX_IMAGE} (NODE_ENV=${NGINX_BUILD_ENV}, INGRESS_PORT=${APP_PORT})"
  podman build --layers -f "$REPO_ROOT/nginx.Dockerfile" \
    --build-arg "NODE_ENV=${NGINX_BUILD_ENV}" \
    --build-arg "INGRESS_PORT=${APP_PORT}" \
    -t "$NGINX_IMAGE" \
    "$REPO_ROOT"
  echo "==> Building ${IDENTYCLAW_IMAGE} (deploy/identyclaw/Containerfile)"
  podman build --layers -f "$REPO_ROOT/deploy/identyclaw/Containerfile" \
    -t "$IDENTYCLAW_IMAGE" \
    "$REPO_ROOT/deploy/identyclaw"
}

echo "==> Repo:      $REPO_ROOT"
echo "==> APP_DIR:   $APP_DIR"
echo "==> TARGET:    $DEPLOY_TIER"
echo "==> DOMAIN:    $DOMAIN"
echo "==> APP_PORT:  $APP_PORT"
echo "==> Image tag: $LOCAL_TAG"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_images
else
  echo "==> Skipping build (--skip-build)"
fi

ironclaw_ensure_app_layout

APP_DIR="$APP_DIR" \
REBORN_IMAGE="$REBORN_IMAGE" \
NGINX_IMAGE="$NGINX_IMAGE" \
IDENTYCLAW_IMAGE="$IDENTYCLAW_IMAGE" \
TARGET="$DEPLOY_TIER" \
REPO_ROOT="$REPO_ROOT" \
SKIP_PULL=1 \
bash "$REPO_ROOT/scripts/deploy-pod.sh"

health_check() {
  local HEALTH_URL="https://${DOMAIN}:${APP_PORT}/api/health"
  echo "==> Health check: ${HEALTH_URL}"
  local elapsed=0
  local max_attempts=$((HEALTH_CHECK_TIMEOUT / HEALTH_CHECK_INTERVAL))
  while [[ $elapsed -lt $HEALTH_CHECK_TIMEOUT ]]; do
    local body
    if [[ "$USE_LOCAL_RESOLVE" == 1 ]]; then
      body="$(curl -sk -m 5 --resolve "${DOMAIN}:${APP_PORT}:127.0.0.1" "$HEALTH_URL" 2>/dev/null || true)"
    else
      body="$(curl -sk -m 5 "$HEALTH_URL" 2>/dev/null || true)"
    fi
    if printf '%s' "$body" | grep -q healthy; then
      echo "healthy"
      printf '%s\n' "$body"
      return 0
    fi
    echo "Health check attempt $((elapsed / HEALTH_CHECK_INTERVAL + 1))/${max_attempts}"
    sleep "$HEALTH_CHECK_INTERVAL"
    elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
  done
  echo "Health check failed" >&2
  podman logs ironclaw-reborn 2>&1 | tail -80 || true
  podman logs ironclaw-nginx 2>&1 | tail -40 || true
  return 1
}

if health_check; then
  echo "==> Local deploy finished successfully"
  exit 0
fi

echo "Verify manually: curl -sk --resolve \"${DOMAIN}:${APP_PORT}:127.0.0.1\" \"https://${DOMAIN}:${APP_PORT}/api/health\"" >&2
exit 1
