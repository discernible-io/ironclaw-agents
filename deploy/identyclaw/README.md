# Host-side IdentyClaw helper for IronClaw Podman deploy

Implements the IronClaw path from IdentyClaw `doc:skills` /
`doc:reference:ironclaw-integration-guide`: Passport keys stay on the host (or in
the sidecar volume), JWTs are cached on disk, and the agent never sees private
keys or full JWTs.

**Agent interface:** `idcp` (Hermes-shaped CLI on PATH inside the Reborn
container). The loopback HTTP sidecar is private — do not teach the model to
curl it.

**Rootless note:** the helper runs as container uid 0. Host-owned
`secrets/near-credentials` and `data/identyclaw/sessions` appear as root inside
the container; `USER node` cannot read them. Do not chown those dirs to
container uid 1000 — that maps to a subordinate host uid and breaks
`./ironclaw.sh idcp` on the host.

## Ops

```bash
./ironclaw.sh idcp-init
./ironclaw.sh idcp enroll                 # NEAR key → secrets/near-credentials
# Human: https://purchase.identyclaw.com with account_id
./ironclaw.sh build-image && ./ironclaw.sh start
./ironclaw.sh idcp ensure_session
./ironclaw.sh idcp me
./ironclaw.sh idcp create_hola --recipient MUNDO
```

`identyclaw` / `identyclaw-init` remain aliases of `idcp` / `idcp-init`.

## Agent (same pod)

```bash
idcp ensure_session
idcp me
idcp create_hola --recipient MUNDO
idcp verify_hola --hola 'HOLA/…'
idcp request GET /api/agents
```

Requires `builtin.shell`. Prefer **`builtin.idcp`** on processless profiles
(`hosted-single-tenant-volume`).

## Processless path (`builtin.idcp`)

Reborn exposes **`builtin.idcp`**: a first-party capability that calls the
loopback helper (`IDENTYCLAW_HELPER_BASE`, default `http://127.0.0.1:3921`)
without `builtin.shell`. Effects are `DispatchCapability` only, so it stays
visible under `hosted-single-tenant-volume` (`process_backend=none`).

```text
WebUI / agent turn
  → CapabilityHost invoke(builtin.idcp)
  → host-runtime idcp handler
  → HTTP to IDENTYCLAW_HELPER_BASE (loopback only)
  → helper (NEAR key + JWT on disk) → api.identyclaw.com
  → redacted JSON back to model (never Authorization / private key / JWT)
```

| Piece | Choice |
|-------|--------|
| Capability id | `builtin.idcp` |
| Ops | `ensure_session`, `me`, `request`, `create_hola`, `verify_hola`, `agents`, `info`, `list_sessions` |
| Effects | `DispatchCapability` only |
| Helper base | Host env; must be `http://127.0.0.1` / `localhost` / `::1` |
| Redaction | JWT-shaped strings + sensitive key names stripped |
| Enroll | Host-only: `./ironclaw.sh idcp enroll` |
