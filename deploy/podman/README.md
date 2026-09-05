# IronClaw HTTPS deploy (Podman + nginx sidecar)

This fork (`ironclaw-agents`) adds a SignPortal-style **Podman pod** for **IronClaw Reborn**:
`ironclaw-reborn` behind an **nginx TLS sidecar**. Runtime secrets and durable state
live in a sibling app directory — never in git.

## Repository vs app directory

| Path | Role |
|------|------|
| `ironclaw-agents/` (this repo) | Code, `Dockerfile`, nginx, `./ironclaw.sh` |
| `../ironclaw-agents-app/secrets/secrets.env` | Runtime secrets (`chmod 600`) |
| `../ironclaw-agents-app/secrets/near-credentials/` | IdentyClaw Passport NEAR JSON (`chmod 700`, host-user owned) |
| `../ironclaw-agents-app/data/identyclaw/sessions/` | Host-cached JWTs (helper + host `idcp`; keep host-user owned) |
| `../ironclaw-agents-app/certs/` | TLS PEMs for nginx |
| `../ironclaw-agents-app/data/ironclaw-reborn/` | Durable Reborn home (volume mount) |
| `../ironclaw-agents-app/logs/` | Container / nginx logs |

Override app root: `export IRONCLAW_APP_DIR=/custom/path`.

Matches the shared host layout in [`../docs/docs/cicd-deployment-standard.md`](../docs/docs/cicd-deployment-standard.md).

## Defaults

| Tier | Hostname | Port |
|------|----------|------|
| `development` | `ironclaw.dihola.io` | `8443` |
| `main` | `ironclaw.discernible.io` | `8443` |

Both tiers publish **8443** because Telegram Bot API webhooks only accept
`443`, `80`, `88`, or `8443`. Override with `IRONCLAW_APP_PORT` only if you
do not need Telegram inbound.

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
cd ~/ironclaw-agents && ./ironclaw.sh restart
```

`./ironclaw.sh generate-certs` is only a bootstrap when no LE cert exists yet
(browsers will warn on that self-signed leaf).

## Quick start

```bash
cd ~/ironclaw-agents
chmod +x ironclaw.sh scripts/*.sh
./ironclaw.sh init
# Edit ../ironclaw-agents-app/secrets/secrets.env — set NEARAI_API_KEY, confirm host/port/BASE_URL
./ironclaw.sh setup          # populate -app; auto NEAR account; mint Passport
./ironclaw.sh generate-certs
./ironclaw.sh build-image    # first Reborn image build is long
./ironclaw.sh start
./ironclaw.sh status
```

Run **setup and start as separate commands** (do not chain them). Setup
populates the app dir, **automatically** creates a NEAR implicit account (no
operator input), pauses for mint at
[purchase.identyclaw.com](https://purchase.identyclaw.com) with collected
Passport fields marked **[selected]**, then activates the home session.
Resume a paused Passport step with `./ironclaw.sh idcp-setup`. After mint,
chat with `./ironclaw.sh chat` (WebUI) or Telegram.

Health (from this host):

```bash
curl -sk --resolve ironclaw.dihola.io:8443:127.0.0.1 \
  https://ironclaw.dihola.io:8443/api/health
```

WebUI: open the HTTPS URL and authenticate with the bearer token from
`./ironclaw.sh token`.

## Operator commands

| Command | Purpose |
|---------|---------|
| `./ironclaw.sh init` | Create `ironclaw-agents-app` + seed `secrets.env` |
| `./ironclaw.sh setup` | Populate -app; last: auto NEAR enroll + Passport mint guide |
| `./ironclaw.sh generate-certs` | Self-signed `fullchain.pem` / `privkey.pem` |
| `./ironclaw.sh build-image` | Build Reborn + nginx images |
| `./ironclaw.sh start` | Recreate pod (always rebuilds nginx; `--build` also rebuilds Reborn) |
| `./ironclaw.sh stop` / `restart` | Teardown / recreate (always rebuilds nginx; reuses Reborn) |
| `./ironclaw.sh status` | Podman + health probe |
| `./ironclaw.sh logs [reborn\|nginx]` | Follow logs |
| `./ironclaw.sh token` | Print WebUI token |
| `./ironclaw.sh telegram-setup` | Install Telegram and apply `TELEGRAM_*` from `secrets.env` |
| `./ironclaw.sh idcp-init` | NEAR creds layout + host helper npm deps |
| `./ironclaw.sh idcp-setup` | Passport only: install → enroll → purchase → session |
| `./ironclaw.sh idcp …` | enroll / ensure_session / me / create_hola / verify_hola / … |
| `./ironclaw.sh create-github-fork` | Create `discernible-io/ironclaw-agents` via `gh` |

Lower-level: `./scripts/deploy-local-podman.sh`, `./scripts/deploy-pod.sh`.

## Git remotes (fork)

`discernible-io` is a **user** account (not a GitHub org). The fork is created with
`gh repo fork nearai/ironclaw --fork-name ironclaw-agents` (no `--org`).

```text
origin    git@github.com:discernible-io/ironclaw-agents.git
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
./ironclaw.sh setup                   # includes Passport end-to-end
# or resume Passport only:
./ironclaw.sh idcp-setup
./ironclaw.sh build-image && ./ironclaw.sh start   # starts helper when creds exist
./ironclaw.sh idcp create_hola --recipient MUNDO
```

Agent calls (same pod): `idcp …` via **shell** when `builtin.shell` is visible
(`local-dev`). Bundled skill: `skills/identyclaw`. (`identyclaw` remains an
alias of `idcp`.)

On processless `hosted-single-tenant-volume`, shell is disabled
(`process_backend=none`); the model should use **`builtin.idcp`** instead of
the `idcp` CLI.

## Secrets checklist

Edit `~/ironclaw-agents-app/secrets/secrets.env` before first start:

- `NEARAI_API_KEY` / `OPENROUTER_API_KEY` — LLM
- `IRONCLAW_REBORN_WEBUI_TOKEN` — auto-generated by `init`
- `IRONCLAW_PUBLIC_HOST` / `IRONCLAW_APP_PORT` / `IRONCLAW_REBORN_WEBUI_BASE_URL` — must match the HTTPS URL clients use
- `IRONCLAW_REBORN_PROFILE=local-dev` — enables `builtin.shell` for himalaya/idcp
- Optional SSO / Slack vars — see template comments
- Telegram: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_BOT_USERNAME` in `secrets.env`, then `./ironclaw.sh telegram-setup` (do **not** use `[telegram]` in `config.toml` — that section is retired)
- IdentyClaw: `IDENTYCLAW_BASE_URL`, Passport JSON under `secrets/near-credentials/`

## Telegram

Bot credentials live in `secrets.env`, not `config.toml`. After the pod is healthy:

1. Set `TELEGRAM_BOT_TOKEN` (from BotFather) and `TELEGRAM_BOT_USERNAME` in `~/ironclaw-agents-app/secrets/secrets.env`.
2. Run `./ironclaw.sh telegram-setup`. That installs the Telegram extension, writes operator admin configuration, and registers the webhook. A webhook secret is generated into `secrets.env` if you leave it blank. Telegram only accepts `443`, `80`, `88`, or `8443`. If `IRONCLAW_APP_PORT` is something else (this host uses `9443`), setup registers `https://<host>:88/webhooks/extensions/telegram/updates` and you must DNAT/proxy host `:88` onto the app port — an HTTP 301/302 redirect is not enough, because Telegram will not follow it for webhook POSTs.
3. To actually talk to the bot, each person still has to **pair** in WebUI → Extensions → Telegram: open the link, scan the QR, or send `/start` followed by the displayed code to the bot. Bot token is enough for DMs. `TELEGRAM_API_ID` + `TELEGRAM_API_HASH` from [my.telegram.org](https://my.telegram.org) are only needed if you want the optional personal Telegram tools.

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
