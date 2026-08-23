<p align="center">
  <img src="ironclaw.png?v=2" alt="IronClaw" width="200"/>
</p>

# IronClaw

**This is [Discernible](https://www.discernible.io/)'s fork of
[NEAR AI IronClaw](https://github.com/nearai/ironclaw).**
Upstream remains the Reborn agent runtime (CLI, WebUI, WASM sandbox, skills,
channels). This checkout adds a rootless **Podman** operator and **IdentyClaw
Passport** identity so the agent can onboard at
[api.identyclaw.com](https://api.identyclaw.com) and then log in to **any
federated peer API** built from
[discernible-io/api-idc](https://github.com/discernible-io/api-idc) — for
example [api.lastcradle.io](https://api.lastcradle.io) — **with no API key and
no extra credentials**. The Passport *is* the credential.

| | [nearai/ironclaw](https://github.com/nearai/ironclaw) (upstream) | This fork ([discernible-io/ironclaw-agents](https://github.com/discernible-io/ironclaw-agents)) |
|---|---|---|
| Agent runtime | `ironclaw` from source / releases | Same Reborn core — we do not fork the agent loop |
| Host install | `cargo run`, manual config | Rootless **Podman** via [`./ironclaw.sh`](deploy/podman/README.md) |
| Runtime state | `$IRONCLAW_REBORN_HOME` | Sibling `../ironclaw-agents-app/` (`./ironclaw.sh init`) |
| Agent identity | Not included | IdentyClaw Passport + `idcp` / `builtin.idcp` |
| Calling peer APIs | Vendor API keys in env | Prove Passport key possession; peer mints a JWT. No API keys. |
| TLS ingress | Bring your own | nginx sidecar + optional Let's Encrypt |

Operator reference: [`deploy/podman/README.md`](deploy/podman/README.md). Product overview:
[discernible.io](https://www.discernible.io/). Enrollment contract:
[guide:enrollment](https://api.identyclaw.com/.well-known/enrollment). Purchase:
[purchase.identyclaw.com](https://purchase.identyclaw.com).

If you only want stock IronClaw, use
[upstream](https://github.com/nearai/ironclaw). The rest of this README still
describes the NEAR agent; skip to
[IdentyClaw Passport](#identyclaw-passport-discernible) for the fork-specific
path.

<p align="center">
  <strong>Your secure personal AI assistant, always on your side</strong>
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache%202.0-blue.svg" alt="License: MIT OR Apache-2.0" /></a>
  <a href="https://t.me/ironclawAI"><img src="https://img.shields.io/badge/Telegram-%40ironclawAI-26A5E4?style=flat&logo=telegram&logoColor=white" alt="Telegram: @ironclawAI" /></a>
  <a href="https://www.reddit.com/r/ironclawAI/"><img src="https://img.shields.io/badge/Reddit-r%2FironclawAI-FF4500?style=flat&logo=reddit&logoColor=white" alt="Reddit: r/ironclawAI" /></a>
  <a href="https://gitcgr.com/nearai/ironclaw">
    <img src="https://gitcgr.com/badge/nearai/ironclaw.svg" alt="gitcgr" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a> |
  <a href="README.ru.md">Русский</a> |
  <a href="README.ja.md">日本語</a> |
  <a href="README.ko.md">한국어</a>
</p>

IronClaw is built on a simple principle: **your AI assistant should work for you, not against you**. Data stays local and encrypted; tools run in a WASM sandbox; capabilities expand without waiting on a vendor.

<table>
<tr><td><b>Security first</b></td><td>WASM sandbox with capability permissions, credential injection at the host boundary, prompt-injection defense, and endpoint allowlisting.</td></tr>
<tr><td><b>Always available</b></td><td>REPL, WebUI, Telegram/Slack and other channels, routines, heartbeats, and parallel jobs from one runtime.</td></tr>
<tr><td><b>Self-expanding</b></td><td>Describe a tool and IronClaw builds it as WASM; connect MCP servers; drop in plugins without restarting.</td></tr>
<tr><td><b>Persistent memory</b></td><td>Hybrid full-text + vector search, workspace filesystem, and identity files that survive across sessions.</td></tr>
<tr><td><b>Runs where you deploy</b></td><td>Local <code>cargo run</code>, production PostgreSQL, or this fork’s rootless Podman operator with TLS.</td></tr>
</table>

---

## IdentyClaw Passport (Discernible)

This fork wires IronClaw to [IdentyClaw](https://www.discernible.io/) — portable,
cryptographically verifiable agent identity on NEAR (RODiT / HOLA).

You mint a Passport **once** at IdentyClaw home. Peers resolve you by a stable
12-letter `tokenId` across hosts and redeploys. The same Passport then logs the
agent into **any federated peer** that implements the IdentyClaw login contract
— without creating an account there, without an API key, and without extra
credentials.

| Role | Host | What it does |
|------|------|----------------|
| **Home** | [api.identyclaw.com](https://api.identyclaw.com) | Issues Passport / HOLA identity. Does **not** authorize third-party APIs. |
| **Peer** | e.g. [api.lastcradle.io](https://api.lastcradle.io), or any API from [api-idc](https://github.com/discernible-io/api-idc) | Same login challenge (`GET /api/login/timestamp` → `POST /api/login`). Mints a JWT valid **only** for that peer. |

Clients remint a JWT **per peer**. A home JWT is not accepted at lastcradle (or
any other peer), and peer tokens are not portable across peers. `idcp` caches each
host's JWT under `../ironclaw-agents-app/data/identyclaw/sessions/` and never prints it
to the model.

```text
┌─────────────────────┐         ┌──────────────────────────┐
│ IdentyClaw home     │         │ Federated peer           │
│ api.identyclaw.com  │         │ e.g. api.lastcradle.io   │
│ mint Passport once  │         │ POST /api/login → JWT    │
└─────────┬───────────┘         └────────────┬─────────────┘
          │ Passport keys                    │
          └──────────────┬───────────────────┘
                         ▼
              idcp ensure_session --base <peer>
              (prove key possession; no API key)
```

| Piece | Role |
| --- | --- |
| **`builtin.idcp`** | First-party capability (same class as `builtin.http`) compiled into `ironclaw` |
| **`skills/identyclaw/`** | Runtime skill that steers the model to prefer that capability |
| **Helper sidecar** | Loopback-only Node service that holds NEAR Passport keys and JWTs (`deploy/identyclaw/`) |
| **`./ironclaw.sh idcp`** | Host operator CLI (aliases: `identyclaw`) |

```text
Agent turn → builtin.idcp → http://127.0.0.1:3921 (helper) → api.identyclaw.com
```

Passport private keys and full JWTs never reach the model. The helper injects
Bearer tokens; `builtin.idcp` returns redacted JSON only. On processless profiles
such as `hosted-single-tenant-volume`, prefer **`builtin.idcp`** — it stays
visible when `builtin.shell` does not.

Checkout is a **human** step. Keep NEAR private keys on disk only — never paste
them into chat. LLM providers (OpenAI, OpenRouter, NEAR AI, …) are a separate
concern; Passport replaces **service API keys** for federated peers, not model
keys.

Enrollment contract: [guide:enrollment](https://api.identyclaw.com/.well-known/enrollment) · purchase: [purchase.identyclaw.com](https://purchase.identyclaw.com).

### 1. Install this repo (Podman)

Requires rootless [Podman](https://podman.io/). Full operator reference:
[`deploy/podman/README.md`](deploy/podman/README.md).

```bash
git clone https://github.com/discernible-io/ironclaw-agents.git ~/ironclaw-agents
cd ~/ironclaw-agents
chmod +x ironclaw.sh scripts/*.sh
./ironclaw.sh init
# Edit ../ironclaw-agents-app/secrets/secrets.env — LLM key, host/port/BASE_URL
./ironclaw.sh idcp-init
```

`init` creates the sibling `../ironclaw-agents-app/` layout (secrets, certs, data).
Runtime state lives in `../ironclaw-agents-app/` (override with `IRONCLAW_APP_DIR`).

### 2. Create a NEAR implicit account

IronClaw uses the host-login path (`idcp`), not OpenClaw plugins. Enrollment
writes credentials under `../ironclaw-agents-app/secrets/near-credentials/`.

```bash
./ironclaw.sh idcp enroll
```

That runs [gennearaccount](https://github.com/discernible-io/gennearaccount)
when available (or a compatible fallback) and prints a **64-character hex**
`implicit_account_id`. Save that id — it is the Passport recipient. Back up the
JSON key file (`chmod 0600`); do not commit it.

Optional standalone install of `gennearaccount`: see
[gennearaccount releases](https://github.com/discernible-io/gennearaccount/releases)
or build from source. Losing the private key loses the Passport permanently.

### 3. Get NEAR (HOT Wallet buy or swap)

Minting costs NEAR on mainnet (gas + Passport fee).
[guide:enrollment](https://api.identyclaw.com/api/mcp/resource/guide:enrollment)
expects a funded checkout wallet. A practical path is
**[HOT Wallet](https://hot-labs.org/telegram/)** (Telegram mini-app / browser
extension — NEAR-native, built-in swap):

1. Open [HOT Wallet](https://hot-labs.org/telegram/) in Telegram (or install the
   browser extension).
2. Create or import a wallet you control. This is your **paying** wallet for
   checkout — separate from the agent's implicit account key file.
3. Obtain NEAR:
   - Buy NEAR in-app if available in your region, **or**
   - Deposit another supported asset and **swap** it to NEAR inside HOT Wallet,
     **or**
   - Withdraw NEAR from an exchange into HOT.
4. Keep enough NEAR for the tier you want plus a small buffer for gas. Personal
   tier starts around **~0.066 Ⓝ** for short longevity; Collectible /
   Enterprise are higher — live quotes are on the purchase portal.

You can also fund or swap via other NEAR wallets / DEX. What matters at mint
time is: a wallet with NEAR that can connect to the purchase portal, and the
agent's `implicit_account_id` as the Passport recipient.

### 4. Craft the Passport at purchase.identyclaw.com

1. Open **[https://purchase.identyclaw.com](https://purchase.identyclaw.com)**.
2. Fill the Passport form (name, creature/role, ContactURI, traits, longevity,
   optional webhook/avatar — see the
   [enrollment guide](https://api.identyclaw.com/api/mcp/resource/doc:reference:enrollment)).
3. Paste the agent's **64-char hex** `implicit_account_id` as the NEAR account
   that will **receive** the Passport (implicit hex account, not a named
   `.near` account).
4. **Connect NEAR Wallet** — choose HOT Wallet (or another Wallet Selector
   option) and approve the mint transaction with the funded wallet from step 3.
5. Wait for confirmation (~seconds). The Passport is minted on-chain to that
   implicit account.

Pricing tiers and fields change over time; trust the portal for current fees.

### 5. Activate on IronClaw (home session)

This logs into **IdentyClaw home** (`https://api.identyclaw.com`) — identity,
HOLA, discovery. It does not log you into other APIs.

```bash
./ironclaw.sh build-image && ./ironclaw.sh start
./ironclaw.sh idcp ensure_session   # JWT login against home (cached under data/identyclaw/sessions/)
./ironclaw.sh idcp me               # confirm Passport identity / tokenId
```

`ensure_session` signs the peer's login challenge with the Passport Ed25519 key
(`GET /api/login/timestamp` → `POST /api/login`). No password, no API key, no
extra account.

Any Reborn agent on that host then shares the same Passport via the sidecar. In
chat, ask for identity / HOLA / Passport work — the skill steers the model to
calls such as `{ "op": "me" }` or `{ "op": "ensure_session" }`.

Day-to-day on home: `idcp create_hola` / `idcp verify_hola` / `idcp request …`.
Optional docs MCP at `https://api.identyclaw.com/mcp`.

| Path | Role |
|------|------|
| `ironclaw-agents/deploy/` | Podman scripts + IdentyClaw helper |
| `../ironclaw-agents-app/secrets/near-credentials/` | NEAR key JSON |
| `../ironclaw-agents-app/data/identyclaw/sessions/` | JWT cache **per API host** |
| `skills/identyclaw/` | Agent skill |

### 6. Log in to any federated peer (no API key)

After the Passport exists, the same keypair logs into every peer that ships the
IdentyClaw challenge-response contract. Point `idcp` at that peer's
`apiEndpoint` with `--base`. The helper remints a JWT **for that host only** and
injects `Authorization: Bearer` on `request`. You do not register, you do not
collect a vendor key, and you must not send the home JWT to the peer.

Auth contract (same on home and every peer):

| Step | Endpoint | Notes |
|------|----------|--------|
| 1 | `GET /api/login/timestamp` | Fresh timestamp from **this** peer |
| 2 | Sign locally | UTF-8 `accountid + timestamp_iso` (Ed25519 → base64url) |
| 3 | `POST /api/login` | Signature → peer-minted `jwt_token` |
| 4 | Protected calls | `Authorization: Bearer <jwt_token>` |

`idcp` does those four steps for you.

#### Example: Synthetics' Last Cradle

[api.lastcradle.io](https://api.lastcradle.io) is a live federated peer (game +
sample CRUDA). A home JWT does **not** authorize `/api/game/*` there — remint
against lastcradle:

```bash
PEER=https://api.lastcradle.io
./ironclaw.sh idcp ensure_session --base "$PEER"
./ironclaw.sh idcp request GET /api/token/claims --base "$PEER"
./ironclaw.sh idcp list_sessions    # home + lastcradle, metadata only (no JWTs)
```

Do **not** call `me --base "$PEER"` to verify federated login — `/api/me/identity`
is a home-only route. `ensure_session` returning `ok: true` with
`federated: true` **is** the login success signal.

Public playbook (no JWT):
[skill.md](https://api.lastcradle.io/api/game/skill.md) ·
[peer-auth.md](https://api.lastcradle.io/api/game/peer-auth.md) ·
[OpenAPI](https://api.lastcradle.io/api-docs).

In chat (processless profiles), the agent uses the same flow via
`builtin.idcp`:

```json
{ "op": "ensure_session", "base": "https://api.lastcradle.io" }
```

Then, only if the user asks for a named product route on that peer:

```json
{ "op": "request", "method": "GET", "path": "/api/token/claims", "base": "https://api.lastcradle.io" }
```

#### Run your own peer

Fork or clone **[discernible-io/api-idc](https://github.com/discernible-io/api-idc)**
— keep the login spine (`authenticate` / `authorize`), replace the sample CRUDA
resource with your domain, set `SERVICE_NAME` and OpenAPI `servers` to your
hostname. Passport holders then log in the same way:

```bash
./ironclaw.sh idcp ensure_session --base https://your-peer.example
./ironclaw.sh idcp request GET /api/token/claims --base https://your-peer.example
```

Tell clients: login against **your** `apiEndpoint`; never send a home JWT there.

Supported `idcp` / `builtin.idcp` ops: `ensure_session`, `me`, `request`,
`create_hola`, `verify_hola`, `agents`, `info`, `list_sessions`. Enrollment stays
host-only (`./ironclaw.sh idcp enroll`).

Further reading:
[`deploy/identyclaw/README.md`](deploy/identyclaw/README.md),
[`skills/identyclaw/SKILL.md`](skills/identyclaw/SKILL.md),
IdentyClaw enrollment MCP `doc:reference:enrollment` /
`guide:enrollment` at `https://api.identyclaw.com/mcp`.

---

## Quick Start

> **This fork:** for HTTPS Podman deploy with IdentyClaw Passport, start with
> [IdentyClaw Passport (Discernible)](#identyclaw-passport-discernible) above
> (`./ironclaw.sh`). The section below is upstream-style `cargo run` development.

The shipping binary is **`ironclaw`** (package `ironclaw` in
`crates/app/ironclaw_cli`). Default state root:
`$HOME/.ironclaw/reborn` (`IRONCLAW_REBORN_HOME`).

### Build or run

```bash
cargo run -q -p ironclaw -- --help
```

Or build first:

```bash
cargo build -p ironclaw
./target/debug/ironclaw --help
```

Isolated state for local experiments:

```bash
export IRONCLAW_REBORN_HOME="$PWD/.reborn-home"
cargo run -q -p ironclaw -- config path
```

`config path` and `doctor` are safe diagnostics; they do not create state or
seed config files.

### Configure the model route

```bash
export IRONCLAW_REBORN_HOME="$PWD/.reborn-home"
cargo run -q -p ironclaw -- models set-provider openai --model gpt-5-mini
cargo run -q -p ironclaw -- models status
```

That writes `$IRONCLAW_REBORN_HOME/config.toml` with `[llm.default]` and the
provider's credential env-var name. Set the secret in the environment, then:

```bash
export OPENAI_API_KEY="sk-..."
cargo run -q -p ironclaw -- run --message "hello"
# or interactive:
cargo run -q -p ironclaw -- repl
```

`config init` writes starter `config.toml` and `providers.json`:

```bash
cargo run -q -p ironclaw -- config init
```

Minimal model route:

```toml
[llm.default]
provider_id = "openai"
model = "gpt-5-mini"
api_key_env = "OPENAI_API_KEY"
```

`api_key_env` is the **name** of an environment variable, not the secret.
IronClaw rejects inline secret-shaped values in `config.toml` and
`providers.json`.

Production storage uses the same env-only pattern:

```toml
[storage]
backend = "postgres"
url_env = "IRONCLAW_REBORN_POSTGRES_URL"
secret_master_key_env = "IRONCLAW_REBORN_SECRET_MASTER_KEY"
pool_max_size = 2

[policy]
deployment_mode = "hosted_multi_tenant"
default_profile = "secure_default"
```

Set `IRONCLAW_REBORN_POSTGRES_URL` (TLS required for managed remote Postgres,
e.g. `sslmode=require`) and an independent
`IRONCLAW_REBORN_SECRET_MASTER_KEY`. Production `run` requires an explicit
`[policy]` section.

Once `[llm.default]` exists, that config selects the provider. `LLM_BACKEND` is
only an env fallback when no default LLM slot is configured.

### Env-only model selection

If `$IRONCLAW_REBORN_HOME/config.toml` is absent or has no `[llm.default]`:

```bash
export IRONCLAW_REBORN_HOME="$PWD/.reborn-env-only"
export LLM_BACKEND=openai
export OPENAI_API_KEY="sk-..."
cargo run -q -p ironclaw -- run --message "hello"
```

| Provider | Selector | Required env |
| --- | --- | --- |
| OpenAI | `LLM_BACKEND=openai` | `OPENAI_API_KEY`; optional `OPENAI_MODEL`, `OPENAI_BASE_URL` |
| Anthropic | `LLM_BACKEND=anthropic` | `ANTHROPIC_API_KEY`; optional `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL` |
| OpenAI-compatible | `LLM_BACKEND=openai_compatible` | `LLM_BASE_URL`; optional `LLM_API_KEY`, `LLM_MODEL` |
| OpenRouter | `LLM_BACKEND=openrouter` | `OPENROUTER_API_KEY`; optional `OPENROUTER_MODEL` |
| Ollama | `LLM_BACKEND=ollama` | no key; optional `OLLAMA_BASE_URL`, `OLLAMA_MODEL` |
| Codex auth | `LLM_BACKEND=openai_codex` | `LLM_USE_CODEX_AUTH=true` or `CODEX_AUTH_PATH`; optional `OPENAI_CODEX_MODEL` |

Use `models list <provider>` for provider metadata compiled into the current
branch.

### Startup variables

| Variable | Purpose |
| --- | --- |
| `IRONCLAW_REBORN_HOME` | Absolute state root. Defaults to `$HOME/.ironclaw/reborn`. |
| `IRONCLAW_REBORN_PROFILE` | Boot profile: `local-dev`, `local-dev-yolo`, `hosted-single-tenant`, `hosted-single-tenant-volume`, `production`, `migration-dry-run`. |
| `IRONCLAW_REBORN_POSTGRES_URL` | Production PostgreSQL URL when `[storage].url_env` names this variable. Keep out of `config.toml`. |
| `IRONCLAW_REBORN_POSTGRES_POOL_MAX_SIZE` | Optional client pool size override for small managed session pools. |
| `IRONCLAW_RESOURCE_GOVERNOR_UNLIMITED_FAST_PATH` | Optional skip of durable resource-governor writes when no finite limits are configured. |
| `IRONCLAW_REBORN_SECRET_MASTER_KEY` | Production secret master key when named by `[storage].secret_master_key_env`. |
| `IRONCLAW_REBORN_LOG` | Tracing filter, e.g. `debug,ironclaw_runner=trace`. |

`run` and `repl` support `local-dev`, `local-dev-yolo`, and
`hosted-single-tenant-volume`. The volume profile uses libSQL under the home
directory, applies secure-default policy, and disables process-backed tools
such as shell — intended for single-tenant preview on a persistent volume, not
full PostgreSQL production.

Under `AskAlways` (volume / secure-default), `builtin.idcp` is on
`exempt_capabilities` so identity / federated login / HOLA do not stall on
“Approve reads” — keys and JWTs stay on the host helper either way.

`local-dev-yolo` grants trusted-laptop host access and must be confirmed:

```bash
export IRONCLAW_REBORN_PROFILE=local-dev-yolo
cargo run -q -p ironclaw -- repl --confirm-host-access
```

### WebUI (`serve`)

`ironclaw serve` is compiled into every build. WebUI builds need Node.js 22
with Corepack/pnpm so Cargo can generate and embed the SPA bundle.

```bash
export IRONCLAW_REBORN_HOME="$PWD/.reborn-home"
export OPENAI_API_KEY="sk-..."
export IRONCLAW_REBORN_WEBUI_TOKEN="$(openssl rand -hex 32)"
export IRONCLAW_REBORN_WEBUI_USER_ID="reborn-cli"

cargo run -q -p ironclaw -- serve
```

Default listener: `127.0.0.1:3000`. Equivalent `config.toml`:

```toml
[webui]
listen_host = "127.0.0.1"
listen_port = 3000
env_token_var = "IRONCLAW_REBORN_WEBUI_TOKEN"
env_user_id_var = "IRONCLAW_REBORN_WEBUI_USER_ID"
allowed_origins = ["http://127.0.0.1:3000", "http://localhost:3000"]
canonical_host = "127.0.0.1:3000"
```

| Variable | Purpose |
| --- | --- |
| `IRONCLAW_REBORN_WEBUI_TOKEN` | Bearer token for WebUI requests. If SSO is enabled, also signs sessions (≥ 32 bytes). |
| `IRONCLAW_REBORN_WEBUI_USER_ID` | Owner/user id for env-bearer requests. |

Optional OAuth / public deploy:

| Variable | Purpose |
| --- | --- |
| `IRONCLAW_REBORN_WEBUI_BASE_URL` | Public base URL for login and product-auth callbacks (`https://` required off-loopback). |
| `IRONCLAW_REBORN_WEBUI_GOOGLE_CLIENT_ID` / `_SECRET` | Google SSO |
| `IRONCLAW_REBORN_WEBUI_GITHUB_CLIENT_ID` / `_SECRET` | GitHub SSO |
| `IRONCLAW_REBORN_WEBUI_ALLOWED_EMAIL_DOMAINS` | Required when any SSO provider is enabled |
| `IRONCLAW_REBORN_WEBUI_GOOGLE_ALLOWED_HD` | Optional Google hosted-domain hint |

Google redirect URI:

```text
{IRONCLAW_REBORN_WEBUI_BASE_URL}/auth/callback/google
```

Use `serve --host <ip> --port <port>` to override the listener.
`local-dev-yolo` refuse non-loopback hosts and require `--confirm-host-access`.

### Slack

Enable Slack with `IRONCLAW_REBORN_SLACK_ENABLED=true` or `[slack] enabled = true`
in `config.toml`, then complete workspace setup from WebUI channel setup.
Details: [`docs/internal/reborn/setup-slack-for-reborn-binary.md`](docs/internal/reborn/setup-slack-for-reborn-binary.md).

---

## Philosophy

IronClaw is built on a simple principle: **your AI assistant should work for you, not against you**.

In a world where AI systems are increasingly opaque about data handling and aligned with corporate interests, IronClaw takes a different approach:

- **Your data stays yours** - All information is stored locally, encrypted, and never leaves your control
- **Transparency by design** - Open source, auditable, no hidden telemetry or data harvesting
- **Self-expanding capabilities** - Build new tools on the fly without waiting for vendor updates
- **Defense in depth** - Multiple security layers protect against prompt injection and data exfiltration

IronClaw is the AI assistant you can actually trust with your personal and professional life.

## Features

### Security First

- **WASM Sandbox** - Untrusted tools run in isolated WebAssembly containers with capability-based permissions
- **Credential Protection** - Secrets are never exposed to tools; injected at the host boundary with leak detection
- **Prompt Injection Defense** - Pattern detection, content sanitization, and policy enforcement
- **Endpoint Allowlisting** - HTTP requests only to explicitly approved hosts and paths

### Always Available

- **Multi-channel** - REPL, HTTP webhooks, WASM channels (Telegram, Slack), and web gateway
- **Docker Sandbox** - Isolated container execution with per-job tokens and orchestrator/worker pattern
- **Web Gateway** - Browser UI with real-time SSE/WebSocket streaming
- **Routines** - Cron schedules, event triggers, webhook handlers for background automation
- **Heartbeat System** - Proactive background execution for monitoring and maintenance tasks
- **Parallel Jobs** - Handle multiple requests concurrently with isolated contexts
- **Self-repair** - Automatic detection and recovery of stuck operations

### Self-Expanding

- **Dynamic Tool Building** - Describe what you need, and IronClaw builds it as a WASM tool
- **MCP Protocol** - Connect to Model Context Protocol servers for additional capabilities
- **Plugin Architecture** - Drop in new WASM tools and channels without restarting

### Persistent Memory

- **Hybrid Search** - Full-text + vector search using Reciprocal Rank Fusion
- **Workspace Filesystem** - Flexible path-based storage for notes, logs, and context
- **Identity Files** - Maintain consistent personality and preferences across sessions

## Installation

> **This fork:** prefer the Podman path in
> [IdentyClaw Passport § 1](#1-install-this-repo-podman) (`./ironclaw.sh init`),
> not the upstream release installers below. The curl/PowerShell installers are
> stock [NEAR IronClaw](https://github.com/nearai/ironclaw) and do **not**
> include `idcp`, Passport, or the sibling `ironclaw-agents-app/` layout.

### Prerequisites

- Rust 1.96+
- PostgreSQL 15+ with [pgvector](https://github.com/pgvector/pgvector) extension
- Node.js 22+ with Corepack/pnpm for source builds that embed the WebUI
- NEAR AI account (authentication handled via setup wizard)
- `libclang` and a working C toolchain if you build the WeChat voice/SILK path from source

## Download or Build

Visit [Releases page](https://github.com/nearai/ironclaw/releases/) to see the latest updates.

<details>
  <summary>Install via Windows Installer (Windows)</summary>

Download the [Windows Installer](https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-x86_64-pc-windows-msvc.msi) and run it.

</details>

<details>
  <summary>Install via powershell script (Windows)</summary>

```sh
irm https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-installer.ps1 | iex
```

</details>

<details>
  <summary>Install via shell script (macOS, Linux, Windows/WSL)</summary>

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-installer.sh | sh
```
</details>

<details>
  <summary>Install via Homebrew (macOS/Linux)</summary>

```sh
brew install ironclaw
```

</details>

<details>
  <summary>Compile the source code (Cargo on Windows, Linux, macOS)</summary>

Install it with `cargo`, just make sure you have [Rust](https://rustup.rs) installed on your computer.

```bash
# Clone the repository
git clone https://github.com/nearai/ironclaw.git
cd ironclaw

# Build
cargo build --release -p ironclaw

# Run tests
cargo test
```

For **full release** (after modifying channel sources), run `./scripts/build-all.sh` to rebuild channels first.

> **Optional:** WeChat voice notes (`audio/silk`) require the standalone
> `ironclaw-silk-decoder` helper to be transcribable. It's excluded from the
> default workspace build because `silk-codec` pulls in `bindgen`/`libclang`.
> Build it separately with `./tools/ironclaw_silk_decoder/build.sh` (needs
> libclang + a C toolchain) and put the resulting binary on `$PATH`, beside
> the `ironclaw` binary, or pointed at by `IRONCLAW_SILK_DECODER`. Without
> it, voice messages are still delivered — just as raw `audio/silk` blobs.

</details>

### Database Setup

```bash
# Create database
createdb ironclaw

# Enable pgvector
psql ironclaw -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

## Configuration

Run the setup wizard to configure IronClaw:

```bash
ironclaw onboard
```

The wizard handles database connection, NEAR AI authentication (via browser OAuth),
and secrets encryption (using your system keychain). Settings are persisted in the
connected database; bootstrap variables (e.g. `DATABASE_URL`, `LLM_BACKEND`) are
written to `~/.ironclaw/.env` so they are available before the database connects.

### Alternative LLM Providers

IronClaw defaults to NEAR AI but supports many LLM providers out of the box.
Built-in providers include **Anthropic**, **OpenAI**, **GitHub Copilot**, **Google Gemini**, **MiniMax**,
**Mistral**, and **Ollama** (local). OpenAI-compatible services like **OpenRouter**
(300+ models), **Together AI**, **Fireworks AI**, and self-hosted servers (**vLLM**,
**LiteLLM**) are also supported.

Select your provider in the wizard, or set environment variables directly:

```env
# Example: MiniMax (built-in, 204K context)
LLM_BACKEND=minimax
MINIMAX_API_KEY=...

# Example: OpenAI-compatible endpoint
LLM_BACKEND=openai_compatible
LLM_BASE_URL=https://openrouter.ai/api/v1
LLM_API_KEY=sk-or-...
LLM_MODEL=anthropic/claude-sonnet-4
```

See [docs/capabilities/llm-providers.md](docs/capabilities/llm-providers.md) for a full provider guide.

## Security

IronClaw implements defense in depth to protect your data and prevent misuse.

### WASM Sandbox

All untrusted tools run in isolated WebAssembly containers:

- **Capability-based permissions** - Explicit opt-in for HTTP, secrets, tool invocation
- **Endpoint allowlisting** - HTTP requests only to approved hosts/paths
- **Credential injection** - Secrets injected at host boundary, never exposed to WASM code
- **Leak detection** - Scans requests and responses for secret exfiltration attempts
- **Rate limiting** - Per-tool request limits to prevent abuse
- **Resource limits** - Memory, CPU, and execution time constraints

```
WASM ──► Allowlist ──► Leak Scan ──► Credential ──► Execute ──► Leak Scan ──► WASM
         Validator     (request)     Injector       Request     (response)
```

### Prompt Injection Defense

External content passes through multiple security layers:

- Pattern-based detection of injection attempts
- Content sanitization and escaping
- Policy rules with severity levels (Block/Warn/Review/Sanitize)
- Tool output wrapping for safe LLM context injection

### Data Protection

- All data stored locally in your PostgreSQL database
- Secrets encrypted with AES-256-GCM
- No telemetry, analytics, or data sharing
- Full audit log of all tool executions

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                          Channels                              │
│  ┌──────┐  ┌──────┐   ┌─────────────┐  ┌─────────────┐         │
│  │ REPL │  │ HTTP │   │WASM Channels│  │ Web Gateway │         │
│  └──┬───┘  └──┬───┘   └──────┬──────┘  │ (SSE + WS)  │         │
│     │         │              │         └──────┬────────┘         │
│     └─────────┴──────────────┴────────────────┘                │
│                              │                                 │
│                    ┌─────────▼─────────┐                       │
│                    │    Agent Loop     │  Intent routing       │
│                    └────┬──────────┬───┘                       │
│                         │          │                           │
│              ┌──────────▼────┐  ┌──▼───────────────┐           │
│              │  Scheduler    │  │ Routines Engine  │           │
│              │(parallel jobs)│  │(cron, event, wh) │           │
│              └──────┬────────┘  └────────┬─────────┘           │
│                     │                    │                     │
│       ┌─────────────┼────────────────────┘                     │
│       │             │                                          │
│   ┌───▼─────┐  ┌────▼────────────────┐                         │
│   │ Local   │  │    Orchestrator     │                         │
│   │Workers  │  │  ┌───────────────┐  │                         │
│   │(in-proc)│  │  │ Docker Sandbox│  │                         │
│   └───┬─────┘  │  │   Containers  │  │                         │
│       │        │  │ ┌───────────┐ │  │                         │
│       │        │  │ │Worker / CC│ │  │                         │
│       │        │  │ └───────────┘ │  │                         │
│       │        │  └───────────────┘  │                         │
│       │        └─────────┬───────────┘                         │
│       └──────────────────┤                                     │
│                          │                                     │
│              ┌───────────▼──────────┐                          │
│              │    Tool Registry     │                          │
│              │  Built-in, MCP, WASM │                          │
│              └──────────────────────┘                          │
└────────────────────────────────────────────────────────────────┘
```

### Core Components

| Component | Purpose |
|-----------|---------|
| **Agent Loop** | Main message handling and job coordination |
| **Router** | Classifies user intent (command, query, task) |
| **Scheduler** | Manages parallel job execution with priorities |
| **Worker** | Executes jobs with LLM reasoning and tool calls |
| **Orchestrator** | Container lifecycle, LLM proxying, per-job auth |
| **Web Gateway** | Browser UI with chat, memory, jobs, logs, extensions, routines |
| **Routines Engine** | Scheduled (cron) and reactive (event, webhook) background tasks |
| **Workspace** | Persistent memory with hybrid search |
| **Safety Layer** | Prompt injection defense and content sanitization |

## Usage

```bash
# First-time setup
ironclaw onboard

# Interactive REPL (from a source checkout)
cargo run -q -p ironclaw -- repl

# REPL with debug logging
RUST_LOG=ironclaw=debug cargo run -q -p ironclaw -- repl
```

On this fork, prefer `./ironclaw.sh chat` / `./ironclaw.sh exec -- …` against
`../ironclaw-agents-app/`.

## Development

```bash
# Format code
cargo fmt

# Lint
cargo clippy --all --benches --tests --examples --all-features -- -D warnings

# Run tests
createdb ironclaw_test
cargo test

# Run specific test
cargo test test_name
```

- **Channels**: See [docs/channels/overview.mdx](docs/channels/overview.mdx) for setup of Telegram, Discord, and other channels.
- **Changing channel sources**: Run `./channels-src/telegram/build.sh` before `cargo build` so the updated WASM is bundled.

## OpenClaw Heritage

IronClaw is a Rust reimplementation inspired by [OpenClaw](https://github.com/openclaw/openclaw). See [FEATURE_PARITY.md](FEATURE_PARITY.md) for the complete tracking matrix.

Key differences:

- **Rust vs TypeScript** - Native performance, memory safety, single binary
- **WASM sandbox vs Docker** - Lightweight, capability-based security
- **PostgreSQL vs SQLite** - Production-ready persistence
- **Security-first design** - Multiple defense layers, credential protection

## Community

**This fork (Discernible)**

- 🌐 [discernible.io](https://www.discernible.io/)
- 🪪 [IdentyClaw home](https://api.identyclaw.com) · [purchase](https://purchase.identyclaw.com)
- 🧩 Federated peer template: [discernible-io/api-idc](https://github.com/discernible-io/api-idc)
- 🎮 Example peer: [api.lastcradle.io](https://api.lastcradle.io)
- 🐛 Fork issues: [discernible-io/ironclaw-agents](https://github.com/discernible-io/ironclaw-agents/issues)

**Upstream IronClaw**

- 💬 [Telegram @ironclawAI](https://t.me/ironclawAI)
- 📖 [Reddit r/ironclawAI](https://www.reddit.com/r/ironclawAI/)
- 🐛 [Issues](https://github.com/nearai/ironclaw/issues)

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.

IronClaw is built by [NEAR AI](https://near.ai). This fork's Podman operator
and IdentyClaw Passport path are maintained by
[Discernible](https://www.discernible.io/).
