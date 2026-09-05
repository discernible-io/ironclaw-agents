#!/usr/bin/env bash
# IronClaw Reborn HTTPS operator CLI (Podman pod + nginx TLS sidecar).
#
# Repo (code): this checkout (ironclaw-agents fork)
# App dir (secrets/state): ../ironclaw-agents-app  (override: IRONCLAW_APP_DIR)
#
# Commands:
#   init                 Create ironclaw-agents-app layout + seed secrets.env from template
#   setup                IdentyClaw Passport path (enroll → purchase → home session)
#   generate-certs       Self-signed TLS PEMs into ironclaw-agents-app/certs/
#   build-image          Build ironclaw-reborn + nginx (+ identyclaw helper) images
#   start [--build]      Recreate pod (always rebuild nginx; reuse Reborn unless --build)
#   stop                 Stop/remove pod
#   restart              stop + start (always rebuild nginx; reuse Reborn unless --build)
#   status               Podman ps + health probe
#   logs [reborn|nginx|identyclaw]  Follow container logs (default: reborn)
#   token                Print IRONCLAW_REBORN_WEBUI_TOKEN from secrets.env
#   telegram-setup       Install Telegram + apply TELEGRAM_* from secrets.env
#   chat | url           Print WebUI HTTPS URL + token (browser chat; not Identyclaw TUI)
#   env                  Print rebuild-safe app-dir env summary (no secret values)
#   exec <cmd…>          Run a host command with secrets.env loaded + host Reborn home
#   idcp-init | identyclaw-init   Layout near-credentials + install helper npm deps
#   idcp-setup | identyclaw-setup  Passport only: install → enroll → purchase → session
#   idcp <cmd> | identyclaw <cmd> Host CLI: enroll|ensure_session|me|create_hola|…
#   create-github-fork   Create discernible-io/ironclaw-agents fork via gh (once)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-podman.sh
source "$ROOT/scripts/lib-podman.sh"

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
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
  ironclaw_ensure_telegram_env_template
  echo "Next: edit secrets (LLM key, host/port), then:"
  echo "  ./ironclaw.sh setup          # IdentyClaw Passport (enroll → purchase → session)"
  echo "  ./ironclaw.sh generate-certs && ./ironclaw.sh build-image && ./ironclaw.sh start"
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
  # Stable local tag by default so `start` / `restart` reuse images across git
  # commits. Override with IRONCLAW_IMAGE_TAG or LOCAL_TAG (e.g. a SHA for CI).
  if [[ -n "${IRONCLAW_IMAGE_TAG:-}" ]]; then
    printf '%s' "$IRONCLAW_IMAGE_TAG"
    return 0
  fi
  if [[ -n "${LOCAL_TAG:-}" ]]; then
    printf '%s' "$LOCAL_TAG"
    return 0
  fi
  printf '%s' local
}

reborn_image_ref() {
  echo "localhost/ironclaw-reborn:$(image_tag)"
}

nginx_image_ref() {
  echo "localhost/ironclaw-nginx:$(image_tag)"
}

identyclaw_image_ref() {
  echo "localhost/ironclaw-identyclaw:$(image_tag)"
}

# Nginx listen port is baked from IRONCLAW_APP_PORT at image build time.
# Always rebuild on start so ironclaw-agents-app port overrides (e.g. 9443) stick.
build_nginx_image() {
  local tag nginx_env port
  tag="$(image_tag)"
  nginx_env="$(ironclaw_nginx_build_env)"
  port="$(ironclaw_tier_port)"
  echo "==> Building localhost/ironclaw-nginx:${tag} (NODE_ENV=${nginx_env}, port=${port})"
  podman build --layers \
    -f "$ROOT/nginx.Dockerfile" \
    --build-arg "NODE_ENV=${nginx_env}" \
    --build-arg "INGRESS_PORT=${port}" \
    -t "localhost/ironclaw-nginx:${tag}" \
    "$ROOT"
}

cmd_build_image() {
  require_podman
  ironclaw_load_secrets
  local tag
  tag="$(image_tag)"
  # --layers keeps intermediate stages (chef cook) reusable. Do not pass
  # --no-cache unless deliberately busting. Dockerfile also uses
  # Buildah cache mounts for cargo registry/target + pnpm so source-only
  # rebuilds stay incremental across builds.
  echo "==> Building localhost/ironclaw-reborn:${tag} (layered + cargo/pnpm cache mounts)"
  podman build --layers \
    -f "$ROOT/Dockerfile" \
    -t "localhost/ironclaw-reborn:${tag}" \
    "$ROOT"
  build_nginx_image
  echo "==> Building localhost/ironclaw-identyclaw:${tag}"
  podman build --layers \
    -f "$ROOT/deploy/identyclaw/Containerfile" \
    -t "localhost/ironclaw-identyclaw:${tag}" \
    "$ROOT/deploy/identyclaw"
}

cmd_identyclaw_init() {
  local app_dir cred_dir
  app_dir="$(ironclaw_app_dir)"
  ironclaw_ensure_app_layout
  cred_dir="$(ironclaw_near_credentials_dir)"
  echo "==> App dir: $app_dir"
  echo "==> NEAR credentials dir: $cred_dir (chmod 700)"
  if ! ironclaw_resolve_near_credentials >/dev/null 2>&1; then
    echo "No credentials yet — run: ./ironclaw.sh idcp enroll"
    echo "Then mint Passport at https://purchase.identyclaw.com with account_id"
    echo "Optional: echo '<accountid>.json' > ${cred_dir}/.active"
  else
    echo "Found credentials: $(ironclaw_resolve_near_credentials)"
  fi
  if command -v npm >/dev/null 2>&1; then
    echo "==> Installing host helper npm deps (deploy/identyclaw)"
    (cd "$ROOT/deploy/identyclaw" && npm install --omit=dev)
    (cd "$ROOT/deploy/identyclaw/vendor/hola-client" && npm install --omit=dev) || true
    # Optional MITM-hardened SDK (npm registry, or IRONCLAW_RODIT_AUTH_BE_PATH / sibling sdk/)
    local rodit_src="${IRONCLAW_RODIT_AUTH_BE_PATH:-}"
    if [[ -z "$rodit_src" && -d "$ROOT/../sdk/rodit-auth-be" ]]; then
      rodit_src="$ROOT/../sdk/rodit-auth-be"
    fi
    if [[ -n "$rodit_src" && -d "$rodit_src" ]]; then
      (cd "$rodit_src" && npm install --omit=dev) || true
      (cd "$ROOT/deploy/identyclaw" && npm install --omit=dev --install-links "$rodit_src") || true
    else
      (cd "$ROOT/deploy/identyclaw" && npm install --omit=dev "@rodit/rodit-auth-be@9.15.0") || true
    fi
    # Ensure wire-login deps remain after optional SDK install
    (cd "$ROOT/deploy/identyclaw" && npm install --omit=dev) || true
  else
    echo "npm not found on host — helper still builds via ./ironclaw.sh build-image"
  fi
  if [[ -f "${app_dir}/secrets/secrets.env" ]]; then
    if ! grep -q '^IDENTYCLAW_BASE_URL=' "${app_dir}/secrets/secrets.env" 2>/dev/null; then
      {
        echo ""
        echo "# IdentyClaw Passport (host helper sidecar is private; agents use idcp)"
        echo "IDENTYCLAW_BASE_URL=https://api.identyclaw.com"
        echo "IDENTYCLAW_NEAR_CONTRACT_ID=genaaaa-identyclaw-com.near"
        echo "NEAR_CONTRACT_ID=genaaaa-identyclaw-com.near"
      } >>"${app_dir}/secrets/secrets.env"
      echo "Appended IDENTYCLAW_* defaults to secrets.env"
    fi
  fi
  echo "Next: ./ironclaw.sh setup   # enroll → purchase → ensure_session (or idcp-setup to resume)"
  echo "Agent skill: skills/identyclaw (idcp on PATH after start)"
}

# Host-side idcp (Passport setup runs before the pod is up).
_idcp_host() {
  local app_dir cred
  app_dir="$(ironclaw_app_dir)"
  ironclaw_ensure_app_layout
  if [[ -f "${app_dir}/secrets/secrets.env" ]]; then
    ironclaw_load_secrets || true
  fi
  export IRONCLAW_APP_DIR="$app_dir"
  export IDENTYCLAW_SESSION_DIR="$(ironclaw_identyclaw_session_dir)"
  export IDENTYCLAW_NEAR_CREDENTIALS_DIR="$(ironclaw_near_credentials_dir)"
  export IDENTYCLAW_BASE_URL="${IDENTYCLAW_BASE_URL:-https://api.identyclaw.com}"
  export NEAR_CONTRACT_ID="${NEAR_CONTRACT_ID:-${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}}"
  if cred="$(ironclaw_resolve_near_credentials 2>/dev/null)"; then
    export NEAR_CREDENTIALS_FILE_PATH="$cred"
  fi
  if [[ ! -d "$ROOT/deploy/identyclaw/node_modules" ]]; then
    cmd_identyclaw_init
  fi
  node "$ROOT/deploy/identyclaw/src/cli.mjs" "$@"
}

_idcp_account_id() {
  local dir
  dir="$(ironclaw_near_credentials_dir)"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
if not d.is_dir():
    sys.exit(0)
files = sorted(d.glob("*.json"))
if not files:
    sys.exit(0)
try:
    raw = json.loads(files[0].read_text())
except Exception:
    sys.exit(0)
aid = raw.get("account_id") or raw.get("implicit_account_id") or ""
if aid:
    print(aid)
PY
  fi
}

# Natural IdentyClaw path: install → enroll → purchase guide → ensure_session → me.
# Invoked from setup (required) or standalone to resume after mint.
cmd_idcp_setup() {
  ironclaw_ensure_app_layout
  cmd_identyclaw_init

  echo ""
  echo "Enrolling NEAR implicit account (agent key file — not the paying wallet) ..."
  local enroll_json account_id
  enroll_json="$(_idcp_host enroll)"
  echo "$enroll_json"
  account_id="$(
    printf '%s' "$enroll_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
print(d.get("account_id") or "")
' 2>/dev/null || true
  )"
  if [[ -z "$account_id" ]]; then
    account_id="$(_idcp_account_id)"
  fi
  if [[ -z "$account_id" ]]; then
    echo "Could not determine implicit_account_id after enroll." >&2
    exit 1
  fi

  # Already bound? Skip purchase pause.
  local tmp_sess tmp_me
  tmp_sess="$(mktemp)"
  tmp_me="$(mktemp)"
  if _idcp_host ensure_session >"$tmp_sess" 2>/dev/null \
    && _idcp_host me >"$tmp_me" 2>/dev/null; then
    echo ""
    echo "Passport already active on home (api.identyclaw.com):"
    cat "$tmp_me"
    rm -f "$tmp_sess" "$tmp_me"
    return 0
  fi
  rm -f "$tmp_sess" "$tmp_me"

  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "Craft your Passport (required)"
  echo "──────────────────────────────────────────────────────────────"
  echo "1. Fund a SEPARATE checkout wallet with NEAR (e.g. HOT Wallet)."
  echo "   Do not paste the agent key file into chat or the portal."
  echo "2. Open: https://purchase.identyclaw.com"
  echo "3. Paste this 64-char hex as the NEAR recipient account:"
  echo ""
  echo "   ${account_id}"
  echo ""
  echo "4. Connect the paying wallet, mint, wait for confirmation."
  echo "   Docs: https://www.discernible.io/  ·  https://api.identyclaw.com/.well-known/enrollment"
  echo "──────────────────────────────────────────────────────────────"

  if [[ ! -t 0 ]]; then
    echo "Non-interactive TTY: after minting, re-run: ./ironclaw.sh idcp-setup" >&2
    echo "Account id saved under $(ironclaw_app_dir)/secrets/near-credentials/" >&2
    return 0
  fi

  # shellcheck disable=SC2162
  read -r -p "Press Enter after the Passport mint confirms (Ctrl-C to pause; resume with ./ironclaw.sh idcp-setup) ... "

  local attempt=1 max_attempts=8
  while (( attempt <= max_attempts )); do
    echo "Activating home session (attempt ${attempt}/${max_attempts}) ..."
    if _idcp_host ensure_session && _idcp_host me; then
      echo ""
      echo "IdentyClaw home session ready."
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    echo "Login failed — Passport may still be indexing, or mint not finished."
    # shellcheck disable=SC2162
    read -r -p "Press Enter to retry (or Ctrl-C and later: ./ironclaw.sh idcp-setup) ... "
    (( ++attempt ))
  done

  echo "Could not activate session yet. After mint confirms:" >&2
  echo "  ./ironclaw.sh idcp-setup" >&2
  echo "  # or: ./ironclaw.sh idcp ensure_session && ./ironclaw.sh idcp me" >&2
  exit 1
}

# Initial interactive install step after init: IdentyClaw Passport (Hermes-shaped).
cmd_setup() {
  local app_dir secrets
  app_dir="$(ironclaw_app_dir)"
  secrets="${app_dir}/secrets/secrets.env"
  if [[ ! -f "$secrets" ]]; then
    echo "No secrets yet — running init first ..."
    cmd_init
  else
    ironclaw_ensure_app_layout
  fi
  echo ""
  echo "=== IdentyClaw Passport (this fork) ==="
  cmd_idcp_setup
  echo ""
  echo "Setup finished. Next:"
  echo "  # Confirm LLM key / host in ${secrets}"
  echo "  ./ironclaw.sh generate-certs && ./ironclaw.sh build-image && ./ironclaw.sh start"
}

cmd_identyclaw() {
  _idcp_host "$@"
}

cmd_start() {
  require_podman
  local do_build=0 tag
  tag="$(image_tag)"
  for arg in "$@"; do
    case "$arg" in
      --build) do_build=1 ;;
      --skip-build)
        # Deprecated no-op: start always rebuilds nginx; Reborn is still reused.
        ;;
      -h|--help)
        echo "Usage: ./ironclaw.sh start [--build]"
        echo "  Recreate the pod. Always rebuilds the nginx sidecar (listen port"
        echo "  is baked from IRONCLAW_APP_PORT). Reuses the Reborn image unless --build."
        echo "  --build   Rebuild all images first (same as build-image + start)."
        return 0
        ;;
      *)
        echo "Unknown start option: $arg" >&2
        echo "Usage: ./ironclaw.sh start [--build]" >&2
        exit 1
        ;;
    esac
  done
  ironclaw_load_secrets
  if [[ "$do_build" -eq 1 ]]; then
    cmd_build_image
  else
    if ! podman image exists "localhost/ironclaw-reborn:${tag}"; then
      echo "Missing image: localhost/ironclaw-reborn:${tag}" >&2
      echo "Run: ./ironclaw.sh build-image   # or: ./ironclaw.sh start --build" >&2
      echo "Or retag an existing build: podman tag localhost/ironclaw-reborn:<old> localhost/ironclaw-reborn:${tag}" >&2
      exit 1
    fi
    build_nginx_image
  fi
  LOCAL_TAG="$tag" TARGET="${TARGET:-}" APP_DIR="$(ironclaw_app_dir)" \
    IDENTYCLAW_IMAGE="$(identyclaw_image_ref)" \
    bash "$ROOT/scripts/deploy-local-podman.sh" --skip-build
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
  cmd_start
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
    identyclaw|helper|idc) podman logs -f ironclaw-identyclaw ;;
    *)
      echo "Usage: $0 logs [reborn|nginx|identyclaw]" >&2
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

_ironclaw_upsert_secrets_var() {
  local secrets="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$secrets"; then
    sed -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" "$secrets" >"$tmp"
  else
    cat "$secrets" >"$tmp"
    printf '\n%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$secrets"
  chmod 600 "$secrets"
}

cmd_telegram_setup() {
  local secrets bot_token username webhook_secret webhook_url
  secrets="$(ironclaw_app_dir)/secrets/secrets.env"
  [[ -f "$secrets" ]] || { echo "Missing $secrets — run ./ironclaw.sh init first" >&2; exit 1; }
  ironclaw_load_secrets
  ironclaw_ensure_telegram_env_template
  # Re-load in case the template was just appended (placeholders only).
  ironclaw_load_secrets

  bot_token="${TELEGRAM_BOT_TOKEN:-${IRONCLAW_REBORN_TELEGRAM_BOT_TOKEN:-}}"
  username="${TELEGRAM_BOT_USERNAME:-${IRONCLAW_REBORN_TELEGRAM_BOT_USERNAME:-}}"
  username="${username#@}"
  if [[ -z "$bot_token" || -z "$username" ]]; then
    echo "Set TELEGRAM_BOT_TOKEN and TELEGRAM_BOT_USERNAME in $secrets" >&2
    if grep -qE '^[[:space:]]*#[[:space:]]*TELEGRAM_BOT_(TOKEN|USERNAME)=.+' "$secrets"; then
      echo "Those keys look filled in but still commented out — remove the leading #." >&2
    fi
    echo "Then re-run: ./ironclaw.sh telegram-setup" >&2
    echo "Do not put the bot token in config.toml — [telegram] is retired." >&2
    exit 1
  fi

  webhook_secret="${TELEGRAM_WEBHOOK_SECRET:-${IRONCLAW_REBORN_TELEGRAM_WEBHOOK_SECRET:-}}"
  if [[ -z "$webhook_secret" ]]; then
    webhook_secret="$(openssl rand -hex 32)"
    _ironclaw_upsert_secrets_var "$secrets" TELEGRAM_WEBHOOK_SECRET "$webhook_secret"
    export TELEGRAM_WEBHOOK_SECRET="$webhook_secret"
    echo "Generated TELEGRAM_WEBHOOK_SECRET and wrote it to secrets.env"
  fi

  webhook_url="${TELEGRAM_WEBHOOK_URL:-${IRONCLAW_REBORN_TELEGRAM_WEBHOOK_URL:-}}"
  if [[ -z "$webhook_url" ]]; then
    local public_host app_port webhook_port allowed
    public_host="$(ironclaw_tier_domain)"
    app_port="$(ironclaw_tier_port)"
    allowed=" 443 80 88 8443 "
    if [[ "$allowed" == *" ${app_port} "* ]]; then
      webhook_url="${IRONCLAW_REBORN_WEBUI_BASE_URL%/}/webhooks/extensions/telegram/updates"
      if [[ -z "${IRONCLAW_REBORN_WEBUI_BASE_URL:-}" ]]; then
        webhook_url="https://${public_host}:${app_port}/webhooks/extensions/telegram/updates"
      fi
    else
      webhook_port="${TELEGRAM_WEBHOOK_PORT:-88}"
      webhook_url="https://${public_host}:${webhook_port}/webhooks/extensions/telegram/updates"
      echo "IRONCLAW_APP_PORT=${app_port} is not a Telegram-allowed webhook port (443, 80, 88, 8443)."
      echo "Registering webhook on :${webhook_port} instead. Host must DNAT/proxy that port to ${app_port}."
    fi
    _ironclaw_upsert_secrets_var "$secrets" TELEGRAM_WEBHOOK_URL "$webhook_url"
    export TELEGRAM_WEBHOOK_URL="$webhook_url"
    echo "Wrote TELEGRAM_WEBHOOK_URL=${webhook_url} to secrets.env"
  fi

  command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required for telegram-setup" >&2
    exit 1
  }
  echo "==> Applying Telegram admin configuration via WebUI operator API"
  python3 "$ROOT/scripts/apply-telegram-admin-config.py"
  echo "Telegram bot is configured. Pair your account from WebUI → Extensions → Telegram"
  echo "(open the link, scan the QR, or send /start followed by the displayed code to the bot)."
  echo "TELEGRAM_API_ID / TELEGRAM_API_HASH are only needed for optional personal Telegram tools."
}

cmd_chat() {
  local domain port url token
  [[ -f "$(ironclaw_app_dir)/secrets/secrets.env" ]] || {
    echo "Missing secrets — run ./ironclaw.sh init first" >&2
    exit 1
  }
  ironclaw_load_secrets
  domain="$(ironclaw_tier_domain)"
  port="$(ironclaw_tier_port)"
  url="${IRONCLAW_REBORN_WEBUI_BASE_URL:-https://${domain}:${port}}"
  # Strip trailing slash; WebUI SPA is under /v2
  url="${url%/}"
  token="${IRONCLAW_REBORN_WEBUI_TOKEN:-}"

  cat <<EOF
IronClaw chat is the Reborn WebUI (browser), not an in-container TUI.

  URL:   ${url}/
  Token: ${token}

On this host, confirm health with:
  curl -sk https://${domain}:${port}/api/health

Paste the token into the WebUI login / bearer prompt when asked.
Print token only: ./ironclaw.sh token
EOF
}

# Host-side Reborn home (volume on disk). secrets.env uses the in-container path
# (/data/ironclaw-reborn); override when running cargo/CLI on the host.
ironclaw_host_reborn_home() {
  printf '%s' "$(ironclaw_app_dir)/data/ironclaw-reborn"
}

cmd_env() {
  local app_dir secrets home
  app_dir="$(ironclaw_app_dir)"
  secrets="${app_dir}/secrets/secrets.env"
  home="$(ironclaw_host_reborn_home)"
  [[ -f "$secrets" ]] || {
    echo "Missing $secrets — run ./ironclaw.sh init first" >&2
    exit 1
  }
  ironclaw_load_secrets
  cat <<EOF
Rebuild-safe IronClaw app env (lives outside the image / git checkout)

  APP_DIR:              ${app_dir}
  secrets:              ${secrets}
  host IRONCLAW_REBORN_HOME: ${home}
  container home:       /data/ironclaw-reborn  (pod volume mount)
  profile:              ${IRONCLAW_REBORN_PROFILE:-unset}
  OPENROUTER_API_KEY:   $([[ -n "${OPENROUTER_API_KEY:-}" ]] && echo "set (len=${#OPENROUTER_API_KEY})" || echo "missing")
  OPENROUTER_MODEL:     ${OPENROUTER_MODEL:-unset (config.toml model used)}
  config.toml provider: $(grep -E '^provider_id\s*=' "${home}/config.toml" 2>/dev/null | head -1 || echo missing)
  config.toml model:    $(grep -E '^model\s*=' "${home}/config.toml" 2>/dev/null | head -1 || echo missing)

Host CLI (survives rebuild — loads secrets.env, points at app data):
  ./ironclaw.sh exec -- cargo run -q -p ironclaw_reborn_cli --bin ironclaw-reborn -- repl
EOF
}

cmd_exec() {
  local home
  [[ -f "$(ironclaw_app_dir)/secrets/secrets.env" ]] || {
    echo "Missing secrets — run ./ironclaw.sh init first" >&2
    exit 1
  }
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 exec [--] <command> [args…]" >&2
    echo "Loads ../ironclaw-agents-app/secrets/secrets.env and sets host IRONCLAW_REBORN_HOME." >&2
    exit 1
  fi
  [[ "$1" == "--" ]] && shift
  [[ $# -gt 0 ]] || {
    echo "Usage: $0 exec [--] <command> [args…]" >&2
    exit 1
  }
  ironclaw_load_secrets
  home="$(ironclaw_host_reborn_home)"
  export IRONCLAW_REBORN_HOME="$home"
  export IRONCLAW_APP_DIR="$(ironclaw_app_dir)"
  exec "$@"
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
  if gh repo view discernible-io/ironclaw-agents >/dev/null 2>&1; then
    echo "discernible-io/ironclaw-agents already exists"
  else
    # discernible-io is a user account (not an org); --org would 422.
    # Do not pass --remote/--clone: when REPO is given, --remote is rejected by gh,
    # and we already manage origin/upstream ourselves below.
    echo "==> Forking nearai/ironclaw → discernible-io/ironclaw-agents"
    gh repo fork nearai/ironclaw --fork-name ironclaw-agents
  fi
  git -C "$ROOT" remote set-url origin git@github.com:discernible-io/ironclaw-agents.git
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
    setup) cmd_setup "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    build-image|build) cmd_build_image "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    token) cmd_token "$@" ;;
    telegram-setup) cmd_telegram_setup "$@" ;;
    chat|url) cmd_chat "$@" ;;
    env) cmd_env "$@" ;;
    exec) cmd_exec "$@" ;;
    idcp-init|identyclaw-init) cmd_identyclaw_init "$@" ;;
    idcp-setup|identyclaw-setup) cmd_idcp_setup "$@" ;;
    idcp|identyclaw) cmd_identyclaw "$@" ;;
    create-github-fork) cmd_create_github_fork "$@" ;;
    -h|--help|help|"") usage 0 ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
