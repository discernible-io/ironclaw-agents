# telegram — channel and linked-account extension

Telegram support under one extension identity: the workspace Bot API channel
and an optional personal account linked as a Telegram device over MTProto. The
package remains first-party and native; there is no WASM module or companion
linked-account extension id. Extension id: `telegram`.

- **Surfaces:** channel (`messages`: webhook `ChannelIngress`, message
  `ChannelReply`, message `ChannelDelivery`) plus 15 tools for the linked
  account: send/edit/delete, add/remove reaction, open/list/inspect/read/search
  conversations and messages, and inspect/resolve/list Telegram identities.
- **Setup:** deployment credentials (bot token, webhook secret, MTProto
  `api_id`, and `api_hash`) arrive via `[admin_configuration]`; each linked-
  account tool carries a device-link credential requirement.
- **Vendor (credential authority):** `telegram`; `[auth.telegram]` declares the
  generic device-link method whose Telegram-specific adapter lives in this
  package.
- **Runtime:** `first_party`
- **Code:** crate `ironclaw_telegram_extension` (`src/`: Bot API channel
  mapping plus `linked/` for MTProto login, transport, session handling,
  mappings, pooling, and tool operations) + `manifest.toml`
- **Depends on:** contracts tier only — dependency-set parity with Slack (`host_api`, `extension_contracts`, `product_contracts`, `attachments`), pinned by `telegram_extension_gates.rs`; linked only by the binary and tests
- **Tests:** `cargo test -p ironclaw_telegram_extension` — `tests/channel_conformance.rs`
  runs the exported channel-capability conformance suite (+ proptest fixtures)

Channel `receive` returns a complete message: it performs Telegram's two-hop `getFile`
handle exchange and download, including provider-size and path-traversal
validation, through restricted egress. The package never sees raw token bytes:
the host runs the manifest-declared
`shared_secret_header` verification and injects credentials on mediated
egress.

Linked-account reads are live against Telegram rather than a mirrored inbox;
writes act as the linked user. The package owns Telegram-specific login and
provider behavior, while generic setup orchestration, linked-session custody,
authorization, and tool mediation remain host-owned. Working rules:
[`AGENTS.md`](./AGENTS.md). Family model:
`crates/extensions/AGENTS.md`.

## Upgrade behavior

Channel identity is the generated-code pairing ceremony (`web_generated_code`):
mint a code in WebUI, open the `t.me` link / QR, or send `/start <code>` to the
bot. Linked-device auth (`[auth.telegram] method = "device_link"`) stays
optional for the 15 personal-account tools and is **not** required to DM the
bot. A previously linked device does not auto-bind bot-channel identity; pair
once through the pairing panel (or `/start`) to talk to the bot. Device-link
rows remain valid for tool dispatch.
