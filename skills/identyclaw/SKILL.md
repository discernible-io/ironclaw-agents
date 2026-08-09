---
name: identyclaw
version: "0.3.2"
description: IdentyClaw Passport API sessions, federated login to peer apiEndpoints, HOLA peer handshake verify/create, and identity lookup for IronClaw deployments
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
    - "federated"
    - "federated login"
    - "apiEndpoint"
  exclude_keywords:
    - "openclaw plugin install"
  patterns:
    - "(?i)\\bhola\\b"
    - "(?i)identyclaw"
    - "(?i)\\bidcp\\b"
    - "(?i)did:rodit:"
    - "(?i)passport\\s+id"
    - "(?i)verify.*(peer|agent|hola)"
    - "(?i)federat"
    - "(?i)apiEndpoint"
    - "(?i)ensure[_ ]session"
  tags:
    - "identity"
    - "auth"
    - "interop"
  max_context_tokens: 2200
---

# IdentyClaw (IronClaw)

**Home API:** `https://api.identyclaw.com`  
**Docs MCP:** `https://api.identyclaw.com/mcp` (`doc:skills`, `doc:reference:ironclaw-integration-guide`)

Prefer **`builtin.idcp`**. Do not invent Ed25519 login, paste JWTs/private keys, or
use `builtin.http` for authenticated IdentyClaw calls.

## Critical: two different “bases”

| Name | Meaning | Who sets it |
|------|---------|-------------|
| Helper loopback | `http://127.0.0.1:3921` — private host sidecar | Operator / deploy (`IDENTYCLAW_HELPER_BASE`) — **never** pass this as `base` |
| `base` / peer `apiEndpoint` | Public IdentyClaw or federated peer HTTPS API | **You** pass this on `builtin.idcp` when not using home |

Omit `base` → home (`https://api.identyclaw.com`).  
Set `base` → **federated login** to that peer (re-mint a JWT for that host).

## Federated login (exact recipe)

Federation is **not** “send the home JWT to another site.” It is: same Passport
keys on the host, **re-login** against the peer URL, cache a **per-host** JWT.

When the user names a peer API (e.g. `https://slc.discernible.io:8443` or any
`https://…` IdentyClaw-compatible host):

1. Call **only** `builtin.idcp` — do **not** open MCP docs, `builtin.http`, or
   hand-rolled `/api/login` (those burn approvals and often fail with
   “input could not be encoded”).
2. `{ "op": "ensure_session", "base": "<peer-https-url>" }`
3. Confirm `ok: true` (and usually `federated: true`). Never ask the user for a JWT.
4. Peer routes with the **same** `base`:
   `{ "op": "request", "method": "GET", "path": "/api/…", "base": "<peer-https-url>" }`
5. Optional: `{ "op": "list_sessions" }` to see cached home vs federated hosts.
6. Passport / HOLA / DID on **home** → omit `base`.

Home-only identity:

```json
{ "op": "ensure_session" }
{ "op": "me" }
```

Federated peer:

```json
{ "op": "ensure_session", "base": "https://peer.example.com" }
{ "op": "request", "method": "GET", "path": "/api/health", "base": "https://peer.example.com" }
```

If `ensure_session` fails for a peer, report the helper error and stop — do not
fall back to pasting tokens or MCP “login guide” fetches.
## `builtin.idcp` ops

| Op | Input | Notes |
|----|-------|-------|
| ensure_session | `{ "op": "ensure_session", "base"? }` | Mint/cache JWT for home or peer — never returns JWT |
| me | `{ "op": "me", "base"? }` | Passport identity (usually home) |
| request | `{ "op": "request", "method", "path", "body"?, "base"? }` | Host injects Bearer for that host |
| create_hola | `{ "op": "create_hola", "recipient"?, "base"? }` | HOLA string |
| verify_hola | `{ "op": "verify_hola", "hola", "expected"?, "base"? }` | verify JSON |
| agents / info / list_sessions | `{ "op": "…" }` | discovery / helper info |

**Processless profiles** (`hosted-single-tenant-volume`): always use `builtin.idcp`
(shell/`idcp` CLI may be unavailable).

## Rules

- Prefer **`builtin.idcp`** over inventing signatures or pasting JWTs into chat.
- **One JWT per API host** — always pass the peer URL as `base` for federated work.
- After inbound `verify_hola` → `verified: true`, immediately `create_hola` and reply on the **same channel**.
- Verify before execute on delegated work.
- Public unauthenticated reads only: `GET /api/agents`, `POST /api/identity/verify` (via `builtin.idcp` `agents`/`request` without needing a session when the API allows).
- A JWT is **not** a HOLA line. Ongoing messaging uses HOLA — not OpenClaw A2A.

## Layout (operator)

| Path | Role |
|------|------|
| `deploy/identyclaw/` | Helper + optional `idcp` CLI |
| `ironclaw-app/secrets/near-credentials/` | Passport NEAR key (host-only) |
| `ironclaw-app/data/identyclaw/sessions/` | Cached JWT **per API host** (host-only) |

## Enrollment (operator, once)

```bash
./ironclaw.sh idcp-init
./ironclaw.sh idcp enroll
# Human: https://purchase.identyclaw.com with account_id
./ironclaw.sh build-image && ./ironclaw.sh start
./ironclaw.sh idcp ensure_session && ./ironclaw.sh idcp me
```
