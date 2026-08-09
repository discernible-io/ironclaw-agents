---
name: himalaya
version: "1.0.0"
description: Himalaya CLI for IMAP/SMTP mail — list, read, search, compose, reply, forward, copy, move, delete when the user asks about email outside the Gmail extension.
activation:
  keywords:
    - himalaya
    - imap
    - smtp
    - check email
    - read email
    - send email
    - inbox
    - mailbox
    - email search
  exclude_keywords:
    - gmail api
    - gmail extension
  patterns:
    - "(?i)\\bhimalaya\\b"
    - "(?i)\\b(list|check|read|search|send|reply|forward)\\b.+\\b(email|inbox|mailbox|mail)\\b"
    - "(?i)\\b(imap|smtp)\\b"
  tags:
    - email
    - mail
    - cli
  max_context_tokens: 1800
requires:
  bins: [himalaya]
---

# Himalaya

Use the `himalaya` CLI via `shell` for IMAP/SMTP (and other Himalaya backends). Prefer this over inventing raw IMAP/SMTP clients. Do not paste mailbox passwords, app passwords, OAuth tokens, or keyring secrets into chat or logs.

For Google Workspace through IronClaw's first-party **Gmail** extension (OAuth API), use that extension instead. Use Himalaya when the user has (or wants) a local Himalaya config / non-Gmail IMAP/SMTP account.

## References

- `references/configuration.md` — account config, auth, provider examples
- `references/message-composition.md` — MML compose / attach syntax

## Setup

```bash
himalaya --version
himalaya account list
himalaya account check
```

Default config path: `~/.config/himalaya/config.toml` (also `$XDG_CONFIG_HOME/himalaya/config.toml` or `~/.himalayarc`).

If no config exists, run interactive setup on the host (`himalaya` with no args / follow upstream wizard docs) and store secrets via `pass`, OS keyring, or `auth.cmd` — never `auth.raw` in shared configs.

Inside the Reborn container/pod, `himalaya` must be on `PATH` and the config + credential helpers must be available to that runtime; otherwise this skill is gated off (`requires.bins`).

## Read / search

```bash
himalaya mailbox list
himalaya envelope list
himalaya envelope list --page 2
himalaya envelope search from alice@example.com and after 2026-01-01 order by date desc
himalaya message read <id>
himalaya attachment download <id>
```

Use `himalaya envelope search --help` for the query DSL. Prefer `--account <name>` when more than one account is configured.

## Write

```bash
himalaya message write
himalaya message reply <id>
himalaya message reply <id> --all
himalaya message forward <id>
himalaya template send < /tmp/message.eml
```

For attachments or HTML, read `references/message-composition.md` and use MML. Prefer non-interactive template/send flows in automation; interactive `$EDITOR` compose only when the user is present on an interactive shell.

## Organize

```bash
himalaya message copy --from INBOX --to Archives <id>
himalaya message move --from INBOX --to Archives <id>
himalaya message delete <id>
himalaya flag add --flag seen <id>
himalaya flag remove --flag seen <id>
```

Exact flags/subcommands vary by Himalaya version — run `himalaya <subcommand> --help` when unsure.

## Safety

- Confirm with the user before **send**, **delete**, or bulk **move**/**copy**.
- Quote exact message IDs and account names in summaries.
- Do not dump full message bodies into memory unless the user asked to retain them.
- Never echo credentials, app passwords, or OAuth tokens.
