---
name: identyclaw
version: "0.3.0"
description: IdentyClaw Passport API sessions, federated login, HOLA peer handshake verify/create, and identity lookup for IronClaw deployments
activation:
  keywords:
    - "identyclaw"
    - "hola"
    - "passport"
    - "rodit"
    - "peer agent"
    - "verify hola"
    - "api.identyclaw.com"
    - "idcp"
  exclude_keywords:
    - "openclaw plugin install"
  patterns:
    - "(?i)\\bhola\\b"
    - "(?i)identyclaw"
    - "(?i)\\bidcp\\b"
    - "(?i)did:rodit:"
    - "(?i)passport\\s+id"
    - "(?i)verify.*(peer|agent|hola)"
  tags:
    - "identity"
    - "auth"
    - "interop"
  max_context_tokens: 1800
---

# IdentyClaw (IronClaw)

**Base URL:** `https://api.identyclaw.com`  
**Docs MCP:** `https://api.identyclaw.com/mcp` (`doc:skills`, `doc:reference:ironclaw-integration-guide`)

IronClaw uses the **host login** path (not OpenClaw plugins). Prefer the
**`builtin.idcp`** capability (processless; works under
`hosted-single-tenant-volume`). When `builtin.shell` is also available you may
run the `idcp` CLI — do not hand-roll Ed25519 login in prompts, invent
signatures, or paste JWTs/private keys.

### `builtin.idcp` ops

| Op | Input | Notes |
|----|-------|-------|
| ensure_session | `{ "op": "ensure_session", "base"? }` | metadata only — never full JWT |
| me | `{ "op": "me", "base"? }` | Passport identity |
| request | `{ "op": "request", "method", "path", "body"? }` | host injects Bearer |
| create_hola | `{ "op": "create_hola", "recipient"? }` | HOLA string |
| verify_hola | `{ "op": "verify_hola", "hola", "expected"? }` | verify JSON |
| agents / info / list_sessions | `{ "op": "…" }` | discovery / helper info |

**Processless profiles** (`hosted-single-tenant-volume`): use `builtin.idcp`.
Do **not** forge authenticated IdentyClaw calls via `builtin.http`. Public
endpoints only via HTTP (`GET /api/agents`, `POST /api/identity/verify`) when
the helper is down — otherwise report `identyclaw_helper_unreachable` to the operator.

## Layout (this host)

| Path | Role |
|------|------|
| `deploy/identyclaw/` (repo) | Helper + `idcp` on agent PATH at `/opt/idcp` |
| `ironclaw-app/secrets/near-credentials/*.json` | NEAR Passport key |
| `ironclaw-app/data/identyclaw/sessions/` | Cached JWT per API host (host-only) |
| `skills/identyclaw/` | This skill |

Inside the Reborn container, prefer **`builtin.idcp`**. The `idcp` CLI is also on
`PATH` at `/opt/idcp` when the pod was started with the deploy kit, but only when
`builtin.shell` is visible.

## Agent-facing ops (`idcp` CLI, shell profiles)

| Op | Command | Returns |
|----|---------|---------|
| ensure_session | `idcp ensure_session [--base URL]` | metadata only (`ok`, `tokenId`, `jwt_length`) — **never** full JWT |
| me | `idcp me` | Passport identity |
| request | `idcp request METHOD /api/path [--body JSON]` | host injects Bearer |
| create_hola | `idcp create_hola [--recipient MUNDO\|peerTokenId]` | HOLA string |
| verify_hola | `idcp verify_hola --hola '…' [--expected MUNDO]` | verify JSON |
| list_sessions | `idcp list_sessions` | cached hosts; no JWTs |

## Rules

- Prefer **`builtin.idcp`** (or the `idcp` CLI when shell is available) over inventing signatures or pasting JWTs into chat.
- One JWT **per API host** (home vs federated): `ensure_session` with optional `base`.
- After inbound `verify_hola` → `verified: true`, immediately `create_hola` and reply on the **same channel**.
- Verify before execute on delegated work.
- Public (no credentials): `POST /api/identity/verify` and `GET /api/agents` via `builtin.idcp` `request`/`agents` or normal egress HTTP.
- A JWT is **not** a HOLA line. Ongoing messaging uses HOLA — not OpenClaw A2A (`/a2a` is not mounted).

## Enrollment (operator, once)

```bash
./ironclaw.sh idcp-init
./ironclaw.sh idcp enroll
# Human: https://purchase.identyclaw.com with account_id
./ironclaw.sh idcp ensure_session
./ironclaw.sh idcp me
./ironclaw.sh start   # recreates pod with helper + idcp on PATH
```

## Day-to-day (in chat / shell)

```bash
idcp ensure_session
idcp verify_hola --hola 'HOLA/…'
idcp create_hola --recipient MUNDO
idcp request GET /api/agents
idcp request GET /api/identity/token/<peerTokenId>/full
```
