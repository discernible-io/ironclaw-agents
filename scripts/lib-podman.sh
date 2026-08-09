#!/usr/bin/env bash
# Shared helpers for IronClaw Podman HTTPS deploy (ironclaw-idc).
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
  sibling="$(cd "$root/.." && pwd)/ironclaw-app"
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
  case "$(ironclaw_deploy_tier)" in
    development) printf '%s' "${IRONCLAW_APP_PORT:-5443}" ;;
    main) printf '%s' "${IRONCLAW_APP_PORT:-9443}" ;;
  esac
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
