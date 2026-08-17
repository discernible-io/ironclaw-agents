#!/usr/bin/env python3
"""Apply Telegram admin configuration from env to a running Reborn WebUI.

Reads TELEGRAM_* and IRONCLAW_REBORN_WEBUI_* from the environment (typically
via ./ironclaw.sh telegram-setup, which sources ironclaw-app/secrets/secrets.env).
Does not print secret values.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
import uuid
from typing import Any


GROUP_ID = "extension.telegram"
PACKAGE_ID = "telegram"
WEBHOOK_PATH = "/webhooks/extensions/telegram/updates"


class SetupError(RuntimeError):
    pass


def _env(*names: str) -> str:
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def _require(name: str, value: str) -> str:
    if not value:
        raise SetupError(f"missing {name}")
    return value


def _host_port() -> tuple[str, str, str]:
    host = _require(
        "IRONCLAW_PUBLIC_HOST",
        _env("IRONCLAW_PUBLIC_HOST"),
    )
    port = _require("IRONCLAW_APP_PORT", _env("IRONCLAW_APP_PORT"))
    token = _require(
        "IRONCLAW_REBORN_WEBUI_TOKEN",
        _env("IRONCLAW_REBORN_WEBUI_TOKEN"),
    )
    return host, port, token


def _api(method: str, path: str, payload: dict[str, Any] | None = None) -> tuple[int, Any]:
    host, port, token = _host_port()
    url = f"https://127.0.0.1:{port}{path}"
    data = None
    headers = {
        "Host": host,
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    context = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            raw = response.read().decode("utf-8") or "null"
            body: Any = json.loads(raw) if raw.strip() else None
            return int(response.status), body
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(raw) if raw.strip() else None
        except json.JSONDecodeError:
            body = {"error": "non_json_response"}
        return int(error.code), body


def _fail_http(operation: str, status: int) -> None:
    raise SetupError(f"{operation} returned HTTP {status} (response body omitted)")


def _extension_listed(body: Any) -> bool:
    if not isinstance(body, dict):
        return False
    extensions = body.get("extensions")
    if not isinstance(extensions, list):
        return False
    for extension in extensions:
        if not isinstance(extension, dict):
            continue
        package_ref = extension.get("package_ref")
        if isinstance(package_ref, dict) and package_ref.get("id") == PACKAGE_ID:
            return True
        if extension.get("id") == PACKAGE_ID:
            return True
    return False


def _installation_state(body: Any) -> str | None:
    if not isinstance(body, dict):
        return None
    extensions = body.get("extensions")
    if not isinstance(extensions, list):
        return None
    for extension in extensions:
        if not isinstance(extension, dict):
            continue
        package_ref = extension.get("package_ref")
        if isinstance(package_ref, dict) and package_ref.get("id") == PACKAGE_ID:
            state = extension.get("installation_state")
            return str(state) if state is not None else None
    return None


def _catalog_group(body: Any) -> dict[str, Any]:
    if not isinstance(body, dict):
        raise SetupError("operator catalog returned non-object JSON")
    groups = body.get("groups")
    if not isinstance(groups, list):
        raise SetupError("operator catalog omitted groups")
    for entry in groups:
        if isinstance(entry, dict) and entry.get("group_id") == GROUP_ID:
            return entry
    raise SetupError(f"operator catalog does not declare {GROUP_ID}; install Telegram first")


def apply() -> None:
    bot_token = _require(
        "TELEGRAM_BOT_TOKEN",
        _env("TELEGRAM_BOT_TOKEN", "IRONCLAW_REBORN_TELEGRAM_BOT_TOKEN"),
    )
    username = _require(
        "TELEGRAM_BOT_USERNAME",
        _env("TELEGRAM_BOT_USERNAME", "IRONCLAW_REBORN_TELEGRAM_BOT_USERNAME"),
    ).lstrip("@")
    webhook_secret = _require(
        "TELEGRAM_WEBHOOK_SECRET",
        _env("TELEGRAM_WEBHOOK_SECRET", "IRONCLAW_REBORN_TELEGRAM_WEBHOOK_SECRET"),
    )
    webhook_url = _env("TELEGRAM_WEBHOOK_URL", "IRONCLAW_REBORN_TELEGRAM_WEBHOOK_URL")
    if not webhook_url:
        host, port, _token = _host_port()
        telegram_ports = {"443", "80", "88", "8443"}
        if port in telegram_ports:
            base_url = _env("IRONCLAW_REBORN_WEBUI_BASE_URL").rstrip("/")
            if not base_url:
                base_url = f"https://{host}:{port}"
            webhook_url = f"{base_url}{WEBHOOK_PATH}"
        else:
            webhook_port = _env("TELEGRAM_WEBHOOK_PORT") or "88"
            webhook_url = f"https://{host}:{webhook_port}{WEBHOOK_PATH}"
    allowed = _env("TELEGRAM_ALLOWED_CHANNELS", "IRONCLAW_REBORN_TELEGRAM_ALLOWED_CHANNELS")
    api_id = _env("TELEGRAM_API_ID", "IRONCLAW_REBORN_TELEGRAM_API_ID")
    api_hash = _env("TELEGRAM_API_HASH", "IRONCLAW_REBORN_TELEGRAM_API_HASH")

    values = {
        "telegram_bot_token": bot_token,
        "telegram_webhook_secret": webhook_secret,
        "telegram_webhook_url": webhook_url,
        "bot_username": username,
    }
    if allowed:
        values["telegram_allowed_channels"] = allowed
    if api_id:
        values["telegram_api_id"] = api_id
    if api_hash:
        values["telegram_api_hash"] = api_hash

    status, listed = _api("GET", "/api/webchat/v2/extensions")
    if status < 200 or status >= 300:
        _fail_http("list extensions", status)
    if not _extension_listed(listed):
        status, install_body = _api(
            "POST",
            "/api/webchat/v2/extensions/install",
            {
                "package_ref": {"kind": "extension", "id": PACKAGE_ID},
                "client_action_id": f"telegram-setup-{uuid.uuid4()}",
            },
        )
        if status < 200 or status >= 300:
            _fail_http("install telegram", status)
        if isinstance(install_body, dict) and install_body.get("success") is False:
            raise SetupError("install telegram did not report success")
        print("installed telegram extension", file=sys.stderr)

    status, catalog = _api("GET", "/api/webchat/v2/operator/extension-configuration")
    if status < 200 or status >= 300:
        _fail_http("operator catalog", status)
    group = _catalog_group(catalog)
    revision = group.get("revision")
    if revision is None:
        raise SetupError(f"{GROUP_ID} catalog entry omitted revision")
    declared: set[str] = set()
    for descriptor in group.get("fields") or []:
        if isinstance(descriptor, dict) and isinstance(descriptor.get("handle"), str):
            declared.add(descriptor["handle"])
    missing_handles = [handle for handle in values if handle not in declared]
    if missing_handles:
        raise SetupError(
            f"{GROUP_ID} does not declare handles {missing_handles}; "
            f"declared={sorted(declared)}"
        )

    status, _saved = _api(
        "PUT",
        f"/api/webchat/v2/operator/extension-configuration/{GROUP_ID}",
        {
            "values": [{"handle": handle, "value": value} for handle, value in values.items()],
            "expected_revision": int(revision),
            "idempotency_key": f"telegram-setup-{uuid.uuid4()}",
        },
    )
    if status != 200:
        _fail_http("save telegram admin configuration", status)
    print(
        f"saved {GROUP_ID} ({len(values)} fields; webhook {webhook_url})",
        file=sys.stderr,
    )

    status, setup = _api("GET", f"/api/webchat/v2/extensions/{PACKAGE_ID}/setup")
    if status < 200 or status >= 300:
        _fail_http("telegram setup view", status)
    secrets: dict[str, str] = {}
    if isinstance(setup, dict) and isinstance(setup.get("secrets"), list):
        for descriptor in setup["secrets"]:
            if not isinstance(descriptor, dict):
                continue
            name = descriptor.get("name")
            if isinstance(name, str) and name in values:
                secrets[name] = values[name]
    if secrets:
        status, _submit = _api(
            "POST",
            f"/api/webchat/v2/extensions/{PACKAGE_ID}/setup",
            {
                "action": "submit",
                "payload": {"secrets": secrets},
                "client_action_id": f"telegram-setup-{uuid.uuid4()}",
            },
        )
        if status < 200 or status >= 300:
            _fail_http("telegram setup submit", status)
        print("submitted telegram setup secrets", file=sys.stderr)

    status, listed = _api("GET", "/api/webchat/v2/extensions")
    if status < 200 or status >= 300:
        _fail_http("telegram active read-back", status)
    state = _installation_state(listed)
    print(f"telegram installation_state={state or 'unknown'}", file=sys.stderr)
    if state not in {"active", "setup_needed"}:
        raise SetupError(
            "telegram did not reach a usable installation state "
            f"(got {state!r}; expected active or setup_needed for per-user pairing)"
        )


def main() -> int:
    try:
        apply()
    except SetupError as error:
        print(f"telegram-setup: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
