# IronClaw HTTPS deploy (Podman + nginx sidecar)

This fork (`ironclaw-idc`) adds a SignPortal-style **Podman pod** for **IronClaw Reborn**:
`ironclaw-reborn` behind an **nginx TLS sidecar**. Runtime secrets and durable state
live in a sibling app directory — never in git.

## Repository vs app directory

| Path | Role |
|------|------|
| `ironclaw-idc/` (this repo) | Code, `Dockerfile`, nginx, `./ironclaw.sh` |
| `../ironclaw-app/secrets/secrets.env` | Runtime secrets (`chmod 600`) |
| `../ironclaw-app/secrets/near-credentials/` | IdentyClaw Passport NEAR JSON (`chmod 700`, host-user owned) |
| `../ironclaw-app/data/identyclaw/sessions/` | Host-cached JWTs (helper + host `idcp`; keep host-user owned) |
| `../ironclaw-app/certs/` | TLS PEMs for nginx |
| `../ironclaw-app/data/ironclaw-reborn/` | Durable Reborn home (volume mount) |
| `../ironclaw-app/logs/` | Container / nginx logs |

Override app root: `export IRONCLAW_APP_DIR=/custom/path`.

Matches the shared host layout in [`../docs/docs/cicd-deployment-standard.md`](../docs/docs/cicd-deployment-standard.md).

## Defaults

| Tier | Hostname | Port |
|------|----------|------|
| `development` | `ironclaw.dihola.io` | `5443` |
| `main` | `ironclaw.discernible.io` | `9443` |

Profile: `local-dev` (LocalHost shell in the Reborn container — required for
`himalaya` / `idcp` CLI skills). Reborn listens on `127.0.0.1:3000` inside the
pod; only nginx publishes the host port. `hosted-single-tenant-volume` remains
available for processless deploys, but it omits `builtin.shell`.

## TLS certificates

Prefer Let's Encrypt via `~/infra` (same as SignPortal), not self-signed:

```bash
cd ~/infra
sudo ./generate-cert-letsencrypt.sh ironclaw.dihola.io
sudo ./install-certs-to-apps.sh
cd ~/ironclaw-idc && ./ironclaw.sh restart
```

`./ironclaw.sh generate-certs` is only a bootstrap when no LE cert exists yet
(browsers will warn on that self-signed leaf).

## Quick start

```bash
cd ~/ironclaw-idc
chmod +x ironclaw.sh scripts/*.sh
./ironclaw.sh init
# Edit ../ironclaw-app/secrets/secrets.env — set NEARAI_API_KEY, confirm host/port/BASE_URL
./ironclaw.sh generate-certs
./ironclaw.sh build-image    # first Reborn image build is long
./ironclaw.sh start
./ironclaw.sh status
```

Health (from this host):

```bash
curl -sk --resolve ironclaw.dihola.io:5443:127.0.0.1 \
  https://ironclaw.dihola.io:5443/api/health
```

WebUI: open the HTTPS URL and authenticate with the bearer token from
`./ironclaw.sh token`.

## Operator commands

| Command | Purpose |
|---------|---------|
| `./ironclaw.sh init` | Create `ironclaw-app` + seed `secrets.env` |
| `./ironclaw.sh generate-certs` | Self-signed `fullchain.pem` / `privkey.pem` |
| `./ironclaw.sh build-image` | Build Reborn + nginx images |
| `./ironclaw.sh start` | Recreate pod (reuse images; `--build` to rebuild first) |
| `./ironclaw.sh stop` / `restart` | Teardown / recreate (reuse images) |
| `./ironclaw.sh status` | Podman + health probe |
| `./ironclaw.sh logs [reborn\|nginx]` | Follow logs |
| `./ironclaw.sh token` | Print WebUI token |
| `./ironclaw.sh idcp-init` | NEAR creds layout + host helper npm deps |
| `./ironclaw.sh idcp …` | enroll / ensure_session / me / create_hola / verify_hola / … |
| `./ironclaw.sh create-github-fork` | Create `discernible-io/ironclaw-idc` via `gh` |

Lower-level: `./scripts/deploy-local-podman.sh`, `./scripts/deploy-pod.sh`.

## Git remotes (fork)

`discernible-io` is a **user** account (not a GitHub org). The fork is created with
`gh repo fork nearai/ironclaw --fork-name ironclaw-idc` (no `--org`).

```text
origin    git@github.com:discernible-io/ironclaw-idc.git
upstream  git@github.com:nearai/ironclaw.git
```

If the GitHub fork does not exist yet (requires `gh auth login`):

```bash
./ironclaw.sh create-github-fork
git push -u origin ops/podman-https-deploy
```

Keep ops/deploy commits on this fork; do not push the deploy kit to `nearai/ironclaw`
unless deliberately upstreaming a thin slice.

## A2A (phase 2)

HTTPS + a stable public URL are prerequisites for agent-to-agent traffic. Full
OpenClaw A2A (`identyclaw-a2a` / `POST /a2a`) is **not** mounted yet.

**IdentyClaw API + HOLA (phase 1, shipped here):** host helper sidecar (private)
plus Hermes-shaped `idcp` CLI on the agent PATH. Passport NEAR credentials +
`@rodit/rodit-auth-be` (when available) / wire login, matching IdentyClaw
`doc:skills` IronClaw path:

```bash
./ironclaw.sh idcp-init
./ironclaw.sh idcp enroll
# Mint Passport at https://purchase.identyclaw.com
./ironclaw.sh build-image && ./ironclaw.sh start   # starts helper when creds exist
./ironclaw.sh idcp ensure_session
./ironclaw.sh idcp me
./ironclaw.sh idcp create_hola --recipient MUNDO
```

Agent calls (same pod): `idcp …` via **shell** when `builtin.shell` is visible
(`local-dev`). Bundled skill: `skills/identyclaw`. (`identyclaw` remains an
alias of `idcp`.)

On processless `hosted-single-tenant-volume`, shell is disabled
(`process_backend=none`); the model should use **`builtin.idcp`** instead of
the `idcp` CLI.

## Secrets checklist

Edit `~/ironclaw-app/secrets/secrets.env` before first start:

- `NEARAI_API_KEY` / `OPENROUTER_API_KEY` — LLM
- `IRONCLAW_REBORN_WEBUI_TOKEN` — auto-generated by `init`
- `IRONCLAW_PUBLIC_HOST` / `IRONCLAW_APP_PORT` / `IRONCLAW_REBORN_WEBUI_BASE_URL` — must match the HTTPS URL clients use
- `IRONCLAW_REBORN_PROFILE=local-dev` — enables `builtin.shell` for himalaya/idcp
- Optional SSO / Slack vars — see template comments
- IdentyClaw: `IDENTYCLAW_BASE_URL`, Passport JSON under `secrets/near-credentials/`

## Himalaya / Migadu mail

Optional. When both files exist, `deploy-pod.sh` bind-mounts them into Reborn
(survives rebuild/restart):

| Host path | Container path |
|-----------|----------------|
| `config/himalaya/config.container.toml` | `/home/ironclaw/.config/himalaya/config.toml` |
| `secrets/himalaya/` (`print-password.sh` + `mailbox.password`) | `/secrets/himalaya/` |

Ownership is normalized to container uid `1000` via `podman unshare` on every
deploy. The agent runs `himalaya` through `builtin.shell` (requires
`IRONCLAW_REBORN_PROFILE=local-dev`).

After the mailbox works, put the From address in the agent's identity
`SYSTEM.md` Contact section (seeded under the standalone storage root as
`system/prompts/default-system.md`, or the equivalent `SYSTEM.md` the runtime
loads). Fresh seeds ship `Email: unset`; replace `unset` with the real address
(for example `ron@agenthood.me`) so the agent can share contact info without a
tool round-trip. If Contact stays unset, the agent is instructed to discover
the account via `himalaya account list`.
