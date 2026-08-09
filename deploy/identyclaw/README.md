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

Requires `builtin.shell`. The default deploy profile
(`hosted-single-tenant-volume`) sets `process_backend=none`, so shell — and
therefore `idcp` — is not model-visible until a mediated capability exists.

## Processless path (sketch)

Goal: Passport / HOLA / authenticated API without exposing `builtin.shell` or
JWTs/keys to the model.

```text
WebUI / agent turn
  → CapabilityHost invoke(builtin.idcp | extension.idcp)
  → host-runtime handler (no ProcessBackend)
  → HTTP to IDENTYCLAW_HELPER_BASE (loopback 127.0.0.1:3921)
  → helper (NEAR key + JWT on disk) → api.identyclaw.com
  → redacted JSON back to model (never Authorization / private key)
```

Suggested shape:

| Piece | Choice |
|-------|--------|
| Capability id | `builtin.idcp` (first-party) or installable extension |
| Ops | Mirror helper verbs: `ensure_session`, `me`, `request`, `create_hola`, `verify_hola`, `agents`, `info` |
| Effects | `Network` (+ maybe `DispatchCapability`); **not** `ExecuteProcess` |
| Policy | Allow when helper is configured; fail closed if `IDENTYCLAW_HELPER_BASE` unreachable |
| Profile | Visible under `hosted-single-tenant-volume` (processless) |
| Redaction | Strip JWT / `Authorization` / key material from model-visible output (same contract as `idcp` CLI) |
| Skill | Teach `builtin.idcp` first; keep CLI for operators and shell-enabled profiles |

Out of scope for v1 of that capability: enroll (stays host `./ironclaw.sh idcp enroll`).

Interim operator workaround while processless capability is unbuilt: run
`./ironclaw.sh idcp me` / `create_hola` on the host and paste non-secret results
into chat, or temporarily use a shell-enabled profile (`local-dev` / yolo).
