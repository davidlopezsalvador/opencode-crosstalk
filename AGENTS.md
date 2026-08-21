# AGENTS.md — Bootstrap for LLM sessions participating in Cross-Talk

You are an LLM agent (OpenCode session) that has landed on this repository.
This file gives you everything you need to USE the Cross-Talk protocol without
reading anything else. Follow it top to bottom.

## What Cross-Talk is

Durable, verifiable messaging between OpenCode sessions: an outbox with ACK/NACK
handshakes, retries, idempotency and a dead-letter queue. The CLI is
`cross/cross.ps1`. Full spec: `CROSS_TALK.md` (only if you need edge cases).

## Step 1 — Identify yourself

Your session ID looks like `ses_xxxxxxxxxxxx...` and appears in your own
environment/session metadata. Put it in a local config (do NOT commit it):

```
cross/cross.config.local.json:
{ "my_session_id": "ses_YOUR_ID", "my_role": "advisor" }
```

## Step 2 — Verify connectivity

```powershell
cd cross
.\cross.ps1 health      # OpenCode Desktop must be running; needs OPENCODE_SERVER_PASSWORD
.\cross.ps1 whoami      # echoes your configured identity
.\cross.ps1 sessions    # lists other sessions of this project (your peers)
```

If AUTH_FAILED: the password lives in the `OPENCODE_SERVER_PASSWORD` env var or
`~/.config/opencode/.env`.

## Step 3 — Send a message to another session

```powershell
.\cross.ps1 send --dest ses_PEER_ID --text "your task text"
```

- Without `--msg`, a msg_id is auto-generated and tracked in `whiteboard/outbox.md`.
- The command blocks until ACK/NACK/timeout (default 120s) and handles retries.
- Final states: `CONFIRMADO` (ACK received), `NACKED`, `EXPIRADO` (timeout), `DLQ`.
- Parse the last JSON line of stdout for the result (`ok`, `state`, `ack_id`).

## Step 4 — When YOU receive a task message

1. **Claim it** before doing any work (idempotency, prevents double processing):
   `.\cross.ps1 claim --msg msg_X`
   - `{ok:true, already:false}` → you own it. Proceed.
   - `ALREADY_CLAIMED_BY_OTHER` → do nothing; another session owns it.
2. Do the task. Write any shared artifacts to `whiteboard/` files agreed in the task.
3. **Close it**: `.\cross.ps1 done --msg msg_X`
4. **Reply to the sender** through your own chat API as instructed in the task
   (typically POST to `/session/<their-id>/prompt_async`), signing your reply:

```
TOKEN:<your-session-id>:<your-model-name>
```

5. If you cannot or should not do it, reject explicitly:
   `.\cross.ps1 nack --token <token> --for-msg-id msg_X --reason CAPACITY`

## Protocol handshake conventions

- When you first talk to a peer, include your protocol version:
  `ACK-PROTOCOLO:1.8` means "I understand protocol 1.8".
- Sign every outbound reply with the `TOKEN:` line above so the sender can match
  it against its outbox token.

## Troubleshooting

```powershell
.\cross.ps1 status              # outbox/DLQ overview
.\cross.ps1 diagnose --msg X    # why a delivery failed (provider down, agent sleeping...)
.\cross.ps1 metrics             # ACK/NACK/timeout rates + latency P50/P95
```

Common errors: `SERVER_NOT_FOUND` (Desktop closed) · `AUTH_FAILED` (password) ·
`ACK_TIMEOUT` (peer busy — try `nudge`) · `DEST_NOT_FOUND` (bad session id).

## Rules of good citizenship

- Never edit `whiteboard/outbox.md` or `idempotencia-procesados.md` by hand while
  sessions are live — always through the CLI.
- One claim per message; release with `release --force` only if the owner is dead.
- Keep replies signed and short. Reference msg_id when acknowledging tasks.
