#!/usr/bin/env bash
# Shared helpers for IronClaw Podman HTTPS deploy (ironclaw-agents).
# shellcheck shell=bash

ironclaw_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s' "$here"
}

ironclaw_app_dir() {
  local root sibling
  if [[ -n "${IRONCLAW_APP_DIR:-}" ]]; then
    printf '%s' "${IRONCLAW_APP_DIR/#\~/$HOME}"
    return 0
  fi
  if [[ -n "${APP_DIR:-}" ]]; then
    printf '%s' "${APP_DIR/#\~/$HOME}"
    return 0
  fi
  root="$(ironclaw_repo_root)"
  sibling="$(cd "$root/.." && pwd)/ironclaw-agents-app"
  printf '%s' "$sibling"
}

ironclaw_load_secrets() {
  local secrets
  secrets="$(ironclaw_app_dir)/secrets/secrets.env"
  if [[ ! -f "$secrets" ]]; then
    echo "Missing secrets file: $secrets (run ./ironclaw.sh init)" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$secrets"
  set +a
}

ironclaw_deploy_tier() {
  local tier
  tier="${TARGET:-${IRONCLAW_DEPLOY_TIER:-development}}"
  case "$tier" in
    development|main) printf '%s' "$tier" ;;
    *)
      echo "Deploy tier must be development or main (got: $tier)" >&2
      return 1
      ;;
  esac
}

ironclaw_tier_port() {
  # Telegram webhooks only accept 443, 80, 88, or 8443. Default both tiers to
  # 8443 so the public HTTPS URL can be registered with Bot API.
  printf '%s' "${IRONCLAW_APP_PORT:-8443}"
}

ironclaw_tier_domain() {
  case "$(ironclaw_deploy_tier)" in
    development) printf '%s' "${IRONCLAW_PUBLIC_HOST:-ironclaw.dihola.io}" ;;
    main) printf '%s' "${IRONCLAW_PUBLIC_HOST:-ironclaw.discernible.io}" ;;
  esac
}

ironclaw_nginx_build_env() {
  case "$(ironclaw_deploy_tier)" in
    development) printf '%s' development ;;
    main) printf '%s' main ;;
  esac
}

ironclaw_selinux_mount_suffix() {
  # Rootless Podman on SELinux hosts needs :Z on bind mounts.
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" != "Disabled" ]]; then
    printf '%s' ",Z"
  elif [[ -d /sys/fs/selinux ]]; then
    printf '%s' ",Z"
  else
    printf '%s' ""
  fi
}

ironclaw_ensure_app_layout() {
  local app_dir
  app_dir="$(ironclaw_app_dir)"
  mkdir -p "${app_dir}/"{certs,logs/nginx,data/ironclaw-reborn,data/identyclaw/sessions,nginx,secrets,secrets/near-credentials,secrets/himalaya,config/himalaya}
  chmod 711 "${app_dir}/certs" 2>/dev/null || true
  chmod 750 "${app_dir}/secrets" 2>/dev/null || true
  chmod 700 "${app_dir}/secrets/near-credentials" 2>/dev/null || true
  chmod 700 "${app_dir}/secrets/himalaya" 2>/dev/null || true
  chmod 700 "${app_dir}/data/identyclaw" 2>/dev/null || true
  chmod 700 "${app_dir}/data/identyclaw/sessions" 2>/dev/null || true
  chmod 0775 "${app_dir}/logs/nginx" 2>/dev/null || true
}

# Himalaya/Migadu mounts for the Reborn container (uid 1000 / ironclaw).
#
# Rootless Podman maps container uid 1000 → a subordinate host uid, so a host
# `test -x secrets/himalaya/print-password.sh` often fails even when the file is
# correctly mode 700 for the container user. Probe and chmod via `podman unshare`
# so redeploys keep mounting mail config.
ironclaw_himalaya_config_file() {
  printf '%s' "$(ironclaw_app_dir)/config/himalaya/config.container.toml"
}

ironclaw_himalaya_secrets_dir() {
  printf '%s' "$(ironclaw_app_dir)/secrets/himalaya"
}

ironclaw_himalaya_password_helper() {
  printf '%s' "$(ironclaw_himalaya_secrets_dir)/print-password.sh"
}

ironclaw_prepare_himalaya() {
  local secrets_dir helper
  secrets_dir="$(ironclaw_himalaya_secrets_dir)"
  helper="$(ironclaw_himalaya_password_helper)"
  mkdir -p "$(ironclaw_app_dir)/config/himalaya" "$secrets_dir"
  # Match the Reborn image USER (uid 1000) so auth.cmd is executable in-pod.
  podman unshare chown -R 1000:1000 "$secrets_dir" 2>/dev/null || true
  podman unshare chmod 700 "$secrets_dir" 2>/dev/null || true
  if podman unshare test -e "$helper" 2>/dev/null; then
    podman unshare chmod 700 "$helper" 2>/dev/null || true
  fi
  if podman unshare test -e "${secrets_dir}/mailbox.password" 2>/dev/null; then
    podman unshare chmod 600 "${secrets_dir}/mailbox.password" 2>/dev/null || true
  fi
}

# True when container config + password helper are ready to bind-mount.
ironclaw_himalaya_mounts_ready() {
  local cfg helper
  cfg="$(ironclaw_himalaya_config_file)"
  helper="$(ironclaw_himalaya_password_helper)"
  [[ -f "$cfg" ]] || return 1
  podman unshare test -x "$helper" 2>/dev/null
}

# When operators switch PROFILE from hosted-single-tenant-volume → local-dev
# (needed for builtin.shell / himalaya on Podman hosts without Docker), keep the
# existing durable libSQL tree instead of starting an empty local-dev root.
ironclaw_migrate_volume_state_for_local_dev() {
  local home old new
  home="$(ironclaw_app_dir)/data/ironclaw-reborn"
  old="${home}/hosted-single-tenant-volume"
  new="${home}/local-dev"
  case "${IRONCLAW_REBORN_PROFILE:-}" in
    local-dev|local-dev-yolo) ;;
    *) return 0 ;;
  esac
  if [[ -d "$old" && ! -e "$new" ]]; then
    echo "==> Migrating durable state: hosted-single-tenant-volume → local-dev"
    # Tree is usually owned by mapped container uid 1000; move in the user NS.
    if ! mv "$old" "$new" 2>/dev/null; then
      podman unshare mv "$old" "$new"
    fi
  fi
}

# Keep $IRONCLAW_REBORN_HOME/config.toml [boot].profile aligned with secrets.env
# so a missing env still boots the intended composition profile.
ironclaw_sync_boot_profile_in_config() {
  local cfg profile tmp current
  cfg="$(ironclaw_app_dir)/data/ironclaw-reborn/config.toml"
  profile="${IRONCLAW_REBORN_PROFILE:-}"
  [[ -n "$profile" && -f "$cfg" ]] || return 0
  grep -qE '^[[:space:]]*profile[[:space:]]*=' "$cfg" || return 0
  current="$(sed -nE 's/^[[:space:]]*profile[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -1)"
  [[ "$current" == "$profile" ]] && return 0
  tmp="$(mktemp)"
  sed -E "s|^[[:space:]]*profile[[:space:]]*=.*|profile = \"${profile}\"|" "$cfg" >"$tmp"
  if ! cp "$tmp" "$cfg" 2>/dev/null; then
    # Volume file owned by mapped container uid — copy as that user.
    podman unshare cp "$tmp" "$cfg"
  fi
  rm -f "$tmp"
}

ironclaw_near_credentials_dir() {
  printf '%s' "$(ironclaw_app_dir)/secrets/near-credentials"
}

ironclaw_identyclaw_session_dir() {
  printf '%s' "$(ironclaw_app_dir)/data/identyclaw/sessions"
}

# Resolve active Passport JSON under secrets/near-credentials/.
ironclaw_resolve_near_credentials() {
  local dir active name hit
  dir="$(ironclaw_near_credentials_dir)"
  if [[ -f "${dir}/.active" ]]; then
    name="$(tr -d '[:space:]' <"${dir}/.active")"
    if [[ -n "$name" ]]; then
      if [[ "$name" == /* && -f "$name" ]]; then
        printf '%s' "$name"
        return 0
      fi
      if [[ -f "${dir}/${name}" ]]; then
        printf '%s' "${dir}/${name}"
        return 0
      fi
      if [[ -f "${dir}/${name}.json" ]]; then
        printf '%s' "${dir}/${name}.json"
        return 0
      fi
    fi
  fi
  hit="$(find "$dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | head -1 || true)"
  if [[ -n "$hit" ]]; then
    printf '%s' "$hit"
    return 0
  fi
  return 1
}

ironclaw_normalize_tls_certs() {
  local cert_dir f
  cert_dir="$(ironclaw_app_dir)/certs"
  chmod 711 "$cert_dir" || true
  for f in privkey.pem tls.key; do
    if [[ -f "${cert_dir}/${f}" ]]; then
      podman unshare chown 101:101 "${cert_dir}/${f}" || true
      podman unshare chmod 600 "${cert_dir}/${f}" || true
    fi
  done
  for f in fullchain.pem chain.pem cert.pem tls.crt; do
    if [[ -f "${cert_dir}/${f}" ]]; then
      podman unshare chown 101:101 "${cert_dir}/${f}" || true
      podman unshare chmod 644 "${cert_dir}/${f}" || true
    fi
  done
}

ironclaw_prepare_data_dir() {
  local data_dir
  data_dir="$(ironclaw_app_dir)/data/ironclaw-reborn"
  mkdir -p "$data_dir"
  # Dockerfile runs as uid 1000 (ironclaw). After first start the
  # tree may be owned by the mapped container uid; ignore chown/chmod errors.
  podman unshare chown -R 1000:1000 "$data_dir" 2>/dev/null || true
  chmod 755 "$data_dir" 2>/dev/null || true
}

# Append the Telegram secrets.env template if the keys are not already present.
ironclaw_ensure_telegram_env_template() {
  local secrets
  secrets="$(ironclaw_app_dir)/secrets/secrets.env"
  [[ -f "$secrets" ]] || return 0
  if grep -qE '^[[:space:]]*#?[[:space:]]*TELEGRAM_BOT_TOKEN=' "$secrets" 2>/dev/null; then
    return 0
  fi
  {
    echo ""
    echo "# --- Telegram (operator admin configuration; not config.toml) ---"
    echo "# Fill TELEGRAM_BOT_TOKEN + TELEGRAM_BOT_USERNAME, then:"
    echo "#   ./ironclaw.sh telegram-setup"
    echo "# TELEGRAM_BOT_TOKEN="
    echo "# TELEGRAM_BOT_USERNAME=YourBot"
    echo "# TELEGRAM_WEBHOOK_SECRET="
    echo "# TELEGRAM_WEBHOOK_URL=                  # if APP_PORT is not 443/80/88/8443, telegram-setup uses :88"
    echo "# TELEGRAM_ALLOWED_CHANNELS="
    echo "# TELEGRAM_API_ID=                       # my.telegram.org — optional, only for personal Telegram tools"
    echo "# TELEGRAM_API_HASH="
  } >>"$secrets"
  chmod 600 "$secrets" 2>/dev/null || true
  echo "Appended Telegram placeholders to secrets.env"
}

# IdentyClaw helper mounts (Passport JSON + cached JWTs).
# Keep host-user ownership + mode 700. Do not podman-unshare-chown to 1000:
# under rootless Podman that maps to a subordinate uid and breaks host
# `./ironclaw.sh idcp`. The helper container must run as uid 0 so it can
# read/write these host-owned paths (host uid ↔ container root).
ironclaw_prepare_identyclaw_dirs() {
  local cred_dir session_dir session_parent
  cred_dir="$(ironclaw_near_credentials_dir)"
  session_dir="$(ironclaw_identyclaw_session_dir)"
  session_parent="$(dirname "$session_dir")"
  mkdir -p "$cred_dir" "$session_dir"
  chmod 700 "$cred_dir" "$session_dir" "$session_parent" 2>/dev/null || true
}

identyclaw_format_contact_uri() {
  local explicit="${1:-}" tg="${2:-}" email="${3:-}" domain
  explicit="${explicit//[[:space:]]/}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  tg="${tg#@}"
  tg="${tg//[[:space:]]/}"
  if [[ -n "$tg" ]]; then
    printf 'telegram:telegram.com:@%s' "$tg"
    return 0
  fi
  email="${email//[[:space:]]/}"
  if [[ -n "$email" && "$email" == *@* ]]; then
    domain="${email#*@}"
    printf 'email:%s:%s' "$domain" "$email"
    return 0
  fi
}

print_passport_field() {
  local name="$1" value="${2:-}" collect_hint="${3:-enter on purchase.identyclaw.com}"
  if [[ -n "$value" ]]; then
    printf '  %-22s [selected]  %s\n' "$name" "$value"
  else
    printf '  %-22s [collect]   %s\n' "$name" "$collect_hint"
  fi
}

print_passport_webhook_field() {
  local name="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    print_passport_field "$name" "" "public HTTPS A2A / webhook URL"
    return 0
  fi
  if [[ "$value" == *127.0.0.1* || "$value" == *localhost* ]]; then
    printf '  %-22s [collect]   %s  (loopback — paste a public HTTPS URL on the portal)\n' "$name" "$value"
    return 0
  fi
  print_passport_field "$name" "$value" ""
}

identyclaw_prompt_with_default() {
  local prompt="$1" default="${2:-}" var=""
  if [[ ! -t 0 ]] || [[ "${SKIP_SETUP_PROMPTS:-0}" == "1" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var || true
  else
    read -r -p "${prompt}: " var || true
  fi
  printf '%s' "${var:-$default}"
}

ironclaw_passport_webhook_url() {
  local host port
  if [[ -n "${IRONCLAW_REBORN_WEBUI_BASE_URL:-}" ]]; then
    printf '%s' "${IRONCLAW_REBORN_WEBUI_BASE_URL%/}"
    return 0
  fi
  host="$(ironclaw_tier_domain 2>/dev/null || true)"
  port="$(ironclaw_tier_port 2>/dev/null || true)"
  if [[ -n "$host" && -n "$port" ]]; then
    printf 'https://%s:%s' "$host" "$port"
  fi
}

ironclaw_passport_contact_uri() {
  identyclaw_format_contact_uri \
    "${IDENTYCLAW_CONTACT_URI:-}" \
    "${TELEGRAM_BOT_USERNAME:-${IRONCLAW_REBORN_TELEGRAM_BOT_USERNAME:-}}" \
    "${IRONCLAW_CONTACT_EMAIL:-}"
}

print_passport_purchase_guide() {
  local account_id="${1:?}" webhook_url="${2:-}" avatar_url="${3:-}" contact_uri="${4:-}" label="${5:-}"
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  if [[ -n "$label" ]]; then
    echo "Craft your Passport for ${label} at https://purchase.identyclaw.com"
  else
    echo "Craft your Passport at https://purchase.identyclaw.com"
  fi
  echo "──────────────────────────────────────────────────────────────"
  echo "1. Fund a SEPARATE checkout wallet with NEAR (e.g. HOT Wallet)."
  echo "   Do not paste the agent key file into chat or the portal."
  echo "2. Open: https://purchase.identyclaw.com"
  echo "3. Paste this 64-char hex as the NEAR recipient account:"
  echo ""
  echo "   ${account_id}"
  echo ""
  echo "4. Fill the Passport form. Values already collected by setup are [selected]:"
  print_passport_webhook_field "A2A / webhook URL" "$webhook_url"
  print_passport_field "Avatar image URL" "$avatar_url" "https://identyclaw.com/avatar.png (portal default) or any https image"
  print_passport_field "ContactURI" "$contact_uri" "scheme:authority:identifier  e.g. telegram:telegram.com:@YourBot  or  email:domain:you@domain"
  echo ""
  echo "   Also collect on the portal: name, creature/role, traits, longevity."
  echo "5. Connect the paying wallet, mint, wait for confirmation."
  echo "   Docs: https://www.discernible.io/  ·  https://api.identyclaw.com/.well-known/enrollment"
  echo "──────────────────────────────────────────────────────────────"
}
