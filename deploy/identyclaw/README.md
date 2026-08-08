# Host-side IdentyClaw helper for IronClaw Podman deploy
#
# Implements the IronClaw path from IdentyClaw `doc:skills` /
# `doc:reference:ironclaw-integration-guide`:
# Passport keys stay on the host (or in this sidecar volume), JWTs are cached
# on disk, and the agent never sees private keys or full JWTs.
#
# Ops:
#   ./ironclaw.sh identyclaw-init
#   # place gennearaccount JSON under ironclaw-app/secrets/near-credentials/
#   ./ironclaw.sh build-image && ./ironclaw.sh start
#   ./ironclaw.sh identyclaw ensure-session
#   ./ironclaw.sh identyclaw me
#
# Agent (same pod netns — use shell curl, not the mediated http tool):
#   curl -sS http://127.0.0.1:3921/v1/ensure_session -X POST -H 'content-type: application/json' -d '{}'
