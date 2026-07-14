#!/usr/bin/env bash
# IronClaw Reborn HTTPS operator CLI (Podman pod + nginx TLS sidecar).
#
# Repo (code): this checkout (ironclaw-idc fork)
# App dir (secrets/state): ../ironclaw-app  (override: IRONCLAW_APP_DIR)
#
# Commands:
#   init                 Create ironclaw-app layout + seed secrets.env from template
#   generate-certs       Self-signed TLS PEMs into ironclaw-app/certs/
#   build-image          Build ironclaw-reborn + nginx images
#   start                Recreate pod (builds if images missing unless --skip-build)
#   stop                 Stop/remove pod
#   restart              stop + start
#   status               Podman ps + health probe
#   logs [reborn|nginx]  Follow container logs (default: reborn)
#   token                Print IRONCLAW_REBORN_WEBUI_TOKEN from secrets.env
#   create-github-fork   Create discernible-io/ironclaw-idc fork via gh (once)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-podman.sh
source "$ROOT/scripts/lib-podman.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

require_podman() {
  command -v podman >/dev/null 2>&1 || {
    echo "podman not found. Install podman first." >&2
    exit 1
  }
}

cmd_init() {
  local app_dir secrets template token
  app_dir="$(ironclaw_app_dir)"
  secrets="${app_dir}/secrets/secrets.env"
  template="$ROOT/deploy/podman/env.example"

  ironclaw_ensure_app_layout
  echo "==> App dir: $app_dir"

  if [[ -f "$secrets" ]]; then
    echo "Secrets already exist: $secrets (leaving unchanged)"
  else
    cp "$template" "$secrets"
    token="$(openssl rand -hex 32)"
    if grep -q 'IRONCLAW_REBORN_WEBUI_TOKEN=CHANGE_ME' "$secrets"; then
      sed -i "s|^IRONCLAW_REBORN_WEBUI_TOKEN=.*|IRONCLAW_REBORN_WEBUI_TOKEN=${token}|" "$secrets"
    fi
    chmod 600 "$secrets"
    echo "Seeded $secrets (WebUI token generated). Edit NEARAI_API_KEY and IRONCLAW_PUBLIC_HOST before start."
  fi

  chmod 600 "$secrets" 2>/dev/null || true
  echo "Next: edit secrets, then ./ironclaw.sh generate-certs && ./ironclaw.sh build-image && ./ironclaw.sh start"
}

cmd_generate_certs() {
  local app_dir domain
  app_dir="$(ironclaw_app_dir)"
  ironclaw_ensure_app_layout
  if [[ -f "${app_dir}/secrets/secrets.env" ]]; then
    ironclaw_load_secrets || true
  fi
  domain="$(ironclaw_tier_domain 2>/dev/null || echo ironclaw.dihola.io)"
  TLS_CN="${TLS_CN:-$domain}" \
    bash "$ROOT/scripts/generate-self-signed-certs.sh" "${app_dir}/certs" "$@"
}

image_tag() {
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$ROOT" rev-parse --short HEAD
  else
    echo local
  fi
}

reborn_image_ref() {
  echo "localhost/ironclaw-reborn:$(image_tag)"
}

nginx_image_ref() {
  echo "localhost/ironclaw-nginx:$(image_tag)"
}

cmd_build_image() {
  require_podman
  ironclaw_load_secrets
  local tag tier port nginx_env
  tag="$(image_tag)"
  tier="$(ironclaw_deploy_tier)"
  port="$(ironclaw_tier_port)"
  nginx_env="$(ironclaw_nginx_build_env)"
  echo "==> Building localhost/ironclaw-reborn:${tag}"
  podman build -f "$ROOT/Dockerfile.reborn" -t "localhost/ironclaw-reborn:${tag}" "$ROOT"
  echo "==> Building localhost/ironclaw-nginx:${tag} (NODE_ENV=${nginx_env}, port=${port})"
  podman build -f "$ROOT/nginx.Dockerfile" \
    --build-arg "NODE_ENV=${nginx_env}" \
    --build-arg "INGRESS_PORT=${port}" \
    -t "localhost/ironclaw-nginx:${tag}" \
    "$ROOT"
}

cmd_start() {
  require_podman
  local skip=0
  for arg in "$@"; do
    case "$arg" in
      --skip-build) skip=1 ;;
    esac
  done
  if [[ "$skip" -eq 1 ]]; then
    TARGET="${TARGET:-}" APP_DIR="$(ironclaw_app_dir)" \
      bash "$ROOT/scripts/deploy-local-podman.sh" --skip-build
  else
    local tag
    tag="$(image_tag)"
    if ! podman image exists "localhost/ironclaw-reborn:${tag}" \
      || ! podman image exists "localhost/ironclaw-nginx:${tag}"; then
      cmd_build_image
    fi
    TARGET="${TARGET:-}" APP_DIR="$(ironclaw_app_dir)" \
      bash "$ROOT/scripts/deploy-local-podman.sh" --skip-build
  fi
}

cmd_stop() {
  require_podman
  local pod="${POD_NAME:-ironclaw-pod}"
  if podman pod exists "$pod"; then
    podman pod stop "$pod" || true
    podman pod rm -f "$pod" || true
    echo "Stopped and removed $pod"
  else
    echo "Pod $pod not found"
  fi
}

cmd_restart() {
  cmd_stop
  cmd_start --skip-build
}

cmd_status() {
  require_podman
  local domain port
  podman pod ps || true
  podman ps --pod || true
  if [[ -f "$(ironclaw_app_dir)/secrets/secrets.env" ]]; then
    ironclaw_load_secrets
    domain="$(ironclaw_tier_domain)"
    port="$(ironclaw_tier_port)"
    echo "==> Health: https://${domain}:${port}/api/health"
    curl -sk -m 5 --resolve "${domain}:${port}:127.0.0.1" \
      "https://${domain}:${port}/api/health" || true
    echo
  fi
}

cmd_logs() {
  require_podman
  local which="${1:-reborn}"
  case "$which" in
    reborn|app) podman logs -f ironclaw-reborn ;;
    nginx) podman logs -f ironclaw-nginx ;;
    *)
      echo "Usage: $0 logs [reborn|nginx]" >&2
      exit 1
      ;;
  esac
}

cmd_token() {
  local secrets
  secrets="$(ironclaw_app_dir)/secrets/secrets.env"
  [[ -f "$secrets" ]] || { echo "Missing $secrets" >&2; exit 1; }
  # shellcheck disable=SC1090
  set -a; source "$secrets"; set +a
  printf '%s\n' "${IRONCLAW_REBORN_WEBUI_TOKEN:-}"
}

cmd_create_github_fork() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI required" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Run: gh auth login" >&2
    echo "Then re-run: ./ironclaw.sh create-github-fork" >&2
    exit 1
  fi
  if gh repo view discernible-io/ironclaw-idc >/dev/null 2>&1; then
    echo "discernible-io/ironclaw-idc already exists"
  else
    # discernible-io is a user account (not an org); --org would 422.
    # Do not pass --remote/--clone: when REPO is given, --remote is rejected by gh,
    # and we already manage origin/upstream ourselves below.
    echo "==> Forking nearai/ironclaw → discernible-io/ironclaw-idc"
    gh repo fork nearai/ironclaw --fork-name ironclaw-idc
  fi
  git -C "$ROOT" remote set-url origin git@github.com:discernible-io/ironclaw-idc.git
  if git -C "$ROOT" remote get-url upstream >/dev/null 2>&1; then
    git -C "$ROOT" remote set-url upstream git@github.com:nearai/ironclaw.git
  else
    git -C "$ROOT" remote add upstream git@github.com:nearai/ironclaw.git
  fi
  echo "Remotes configured. Push with: git push -u origin HEAD"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    build-image|build) cmd_build_image "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    token) cmd_token "$@" ;;
    create-github-fork) cmd_create_github_fork "$@" ;;
    -h|--help|help|"") usage 0 ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
