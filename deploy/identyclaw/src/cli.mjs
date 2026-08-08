#!/usr/bin/env node
/**
 * Operator CLI for IdentyClaw host login / HOLA (IronClaw deploy).
 *
 * Usage:
 *   node src/cli.mjs ensure-session [--api-endpoint URL]
 *   node src/cli.mjs list-sessions
 *   node src/cli.mjs me [--api-endpoint URL]
 *   node src/cli.mjs agents [--limit N]
 *   node src/cli.mjs request --method GET --path /api/me/identity
 *   node src/cli.mjs create-hola --recipient MUNDO
 *   node src/cli.mjs verify-hola --hola 'HOLA/...'
 *   node src/cli.mjs info
 */
import {
  apiRequest,
  createHola,
  ensureSession,
  helperInfo,
  listSessions,
  verifyHola,
} from "./lib.mjs";

function usage(code = 0) {
  const text = `ironclaw-identyclaw CLI

Commands:
  ensure-session [--api-endpoint URL] [--credentials PATH]
  list-sessions
  me [--api-endpoint URL]
  agents [--limit N]
  request --method METHOD --path /api/... [--api-endpoint URL] [--body JSON] [--no-auth]
  create-hola [--recipient ID] [--api-endpoint URL] [--token-id ID]
  verify-hola --hola LINE [--expected-recipient ID] [--api-endpoint URL] [--auth]
  info
`;
  process.stdout.write(text);
  process.exit(code);
}

function argValue(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

function hasFlag(argv, name) {
  return argv.includes(name);
}

async function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  if (!cmd || cmd === "-h" || cmd === "--help" || cmd === "help") usage(0);

  const credentialsPath = argValue(argv, "--credentials");
  const apiEndpoint = argValue(argv, "--api-endpoint");

  let result;
  switch (cmd) {
    case "ensure-session":
      result = await ensureSession({ apiEndpoint, credentialsPath });
      break;
    case "list-sessions":
      result = listSessions();
      break;
    case "me":
      result = await apiRequest({
        method: "GET",
        path: "/api/me/identity",
        apiEndpoint,
        auth: true,
        credentialsPath,
      });
      break;
    case "agents": {
      const limit = argValue(argv, "--limit") || "20";
      result = await apiRequest({
        method: "GET",
        path: `/api/agents?limit=${encodeURIComponent(limit)}`,
        auth: false,
      });
      break;
    }
    case "request": {
      const method = argValue(argv, "--method") || "GET";
      const path = argValue(argv, "--path");
      if (!path) throw new Error("--path is required");
      const bodyRaw = argValue(argv, "--body");
      const body = bodyRaw ? JSON.parse(bodyRaw) : undefined;
      result = await apiRequest({
        method,
        path,
        body,
        apiEndpoint,
        auth: !hasFlag(argv, "--no-auth"),
        credentialsPath,
      });
      break;
    }
    case "create-hola":
      result = await createHola({
        recipient: argValue(argv, "--recipient") || "MUNDO",
        apiEndpoint,
        credentialsPath,
        tokenId: argValue(argv, "--token-id"),
      });
      break;
    case "verify-hola": {
      const hola = argValue(argv, "--hola");
      if (!hola) throw new Error("--hola is required");
      result = await verifyHola({
        hola,
        expectedRecipient: argValue(argv, "--expected-recipient"),
        apiEndpoint,
        auth: hasFlag(argv, "--auth"),
        credentialsPath,
      });
      break;
    }
    case "info":
      result = helperInfo();
      break;
    default:
      process.stderr.write(`unknown command: ${cmd}\n`);
      usage(1);
  }

  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((err) => {
  process.stderr.write(`error: ${err?.message || err}\n`);
  process.exit(1);
});
