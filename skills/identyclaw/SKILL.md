---
name: identyclaw
version: "0.1.0"
description: IdentyClaw Passport API sessions, federated login, HOLA peer handshake verify/create, and identity lookup for IronClaw host-sidecar deployments
activation:
  keywords:
    - "identyclaw"
    - "hola"
    - "passport"
    - "rodit"
    - "peer agent"
    - "verify hola"
    - "api.identyclaw.com"
  exclude_keywords:
    - "openclaw plugin install"
  patterns:
    - "(?i)\\bhola\\b"
    - "(?i)identyclaw"
    - "(?i)did:rodit:"
    - "(?i)passport\\s+id"
    - "(?i)verify.*(peer|agent|hola)"
  tags:
    - "identity"
    - "auth"
    - "interop"
  max_context_tokens: 2200
---

# IdentyClaw on IronClaw (host helper)

You run on **IronClaw**, not OpenClaw. Do **not** invent Ed25519 signatures, paste private keys, or treat redacted `eyJ…` fragments as JWTs. Do **not** curl `POST /api/login` from chat.

**Home API:** `https://api.identyclaw.com`  
**Host helper (same pod, loopback):** `http://127.0.0.1:3921`  
Override with env `IDENTYCLAW_HELPER_BASE` when set.

## Two lanes

| Lane | Artifact | How on IronClaw |
|------|----------|-----------------|
| API login | Host-cached JWT (~1h) | Helper `ensure_session` / `request` |
| HOLA | Wire string (~5 min nonce) | Helper `create_hola` / `verify_hola` |

A JWT is **not** a HOLA line. `POST /api/identity/verify` is **public**.

## Call the host helper (preferred for protected ops)

Mediated `http` egress **blocks loopback**. Use the **shell** tool (or ask the operator to run `./ironclaw.sh identyclaw …`):

```bash
HELPER="${IDENTYCLAW_HELPER_BASE:-http://127.0.0.1:3921}"

# 1. API session (home or federated)
curl -sS -X POST "$HELPER/v1/ensure_session" \
  -H 'content-type: application/json' \
  -d '{}'
curl -sS -X POST "$HELPER/v1/ensure_session" \
  -H 'content-type: application/json' \
  -d '{"apiEndpoint":"https://api-b.example.com"}'

# 2. List sessions (metadata only — no JWTs)
curl -sS "$HELPER/v1/sessions"

# 3. Own identity
curl -sS "$HELPER/v1/me"

# 4. Generic authenticated request
curl -sS -X POST "$HELPER/v1/request" \
  -H 'content-type: application/json' \
  -d '{"method":"GET","path":"/api/identity/token/PEERTOKEN/full"}'

# 5. Create outbound HOLA (signer = this Passport; only recipient may be user-supplied)
curl -sS -X POST "$HELPER/v1/create_hola" \
  -H 'content-type: application/json' \
  -d '{"recipient":"MUNDO"}'

# 6. Verify peer HOLA
curl -sS -X POST "$HELPER/v1/verify_hola" \
  -H 'content-type: application/json' \
  -d '{"hola":"HOLA/MUNDO/...","expectedRecipient":"MUNDO"}'
```

Helper responses never include `jwt_token` or `nearPrivateKey`.

## Public ops without the helper

Safe via the normal `http` tool (no credentials):

```text
POST https://api.identyclaw.com/api/identity/verify
  body: {"hola":"<line>","expectedRecipient":"MUNDO"}

GET https://api.identyclaw.com/api/agents?limit=20
```

Trust peers only when `verified: true`. Then immediately create/send **your** HOLA on the same channel (`create_hola` with `recipient` = peer `peerTokenId` or `MUNDO`).

## First contact

1. Verify inbound HOLA (`verified: true`).
2. `ensure_session` + `create_hola` reply — do not wait for the user.
3. Lookup `GET …/token/{peerTokenId}/full` via helper `request`.
4. Impersonation guard: compare `peerTokenId` to IDs published on channels the entity controls.
5. Ongoing messaging: HOLA + collaboration envelope on this channel — **not** OpenClaw A2A (`/a2a` is not mounted on this deploy).

## Federation

Remint a JWT on the target host (`ensure_session` with `apiEndpoint`). Do not reuse a home JWT on a federated API. Backend contract: `@rodit/rodit-auth-be` ≥9.13.

## Operator docs

MCP (docs only): `https://api.identyclaw.com/mcp` → `doc:skills`, `doc:reference:ironclaw-integration-guide`.
