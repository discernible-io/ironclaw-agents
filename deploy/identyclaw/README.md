# Host-side IdentyClaw helper for IronClaw Podman deploy

Implements the IronClaw path from IdentyClaw `doc:skills` /
`doc:reference:ironclaw-integration-guide`: Passport keys stay on the host (or in
the sidecar volume), JWTs are cached on disk, and the agent never sees private
keys or full JWTs.

**Agent interface:** `idcp` (Hermes-shaped CLI on PATH inside the Reborn
container). The loopback HTTP sidecar is private — do not teach the model to
curl it.

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
