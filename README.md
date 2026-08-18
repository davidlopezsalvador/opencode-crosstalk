# CROSS-TALK

Multi-agent communication protocol for [OpenCode Desktop](https://opencode.ai). Lets AI agent sessions in the same project talk to each other via the local HTTP API — with durable outbox, ACK/NACK handshakes, idempotent delivery, and automatic diagnostics.

**Version: 1.6.1** | [Protocol spec](CROSS_TALK.md) | [Changelog](CHANGELOG.md) | [Windows pitfalls](CROSS_WINDOWS.md)

## What it does

OpenCode Desktop runs a local HTTP server (`http://127.0.0.1:PORT`) that exposes each chat session. CROSS-TALK builds on top of that to enable:

- **Inter-session messaging** — send messages between any two sessions in the same project
- **Durable outbox** — messages survive crashes; tracked in `outbox.md`
- **ACK/NACK handshakes** — sender knows if the recipient processed the message
- **Idempotent delivery** — at-least-once with deduplication via `idempotencia-procesados.md`
- **Automatic retries** — configurable backoff, lease renewal, and circuit breakers
- **Diagnostics** — classify failures (provider down, agent sleeping, config error) from OpenCode logs
- **Dead letter queue** — messages that can't be delivered after max retries go to DLQ for human review
- **AVISO-SPOF** — passive detection if the leader session goes silent

## Quick start

### Prerequisites

- Windows with PowerShell 5.1+
- [OpenCode Desktop](https://opencode.ai) running with at least 2 open sessions
- `curl.exe` (ships with Windows)

### Setup

1. Clone this repo
2. Edit `cross/cross.config.json` — set your session IDs:

```json
{
    "my_session_id": "ses_YOUR_SESSION_ID",
    "lider_session_id": "ses_LEADER_SESSION_ID",
    "my_model": "your-model-name",
    "my_role": "asesor"
}
```

3. Run the CLI:

```powershell
cd cross
.\cross.ps1 health          # verify server is reachable
.\cross.ps1 sessions         # list active sessions
.\cross.ps1 send --msg test --dest ses_DEST --text "Hello from CROSS-TALK"
```

### Usage

```
cross health                    # verify server connection
cross whoami                    # show current session info
cross sessions                  # list all sessions in the project
cross read --session ses_X      # read messages from a session
cross config --list             # show current configuration

cross send --msg MSG_ID --dest ses_Y --text "..."   # send a message
cross ack --token T --for-msg-id X                   # acknowledge receipt
cross nack --token T --for-msg-id X --reason RAZON   # reject with reason

cross status                    # overview of outbox + idempotency + DLQ
cross scan                      # check for expired leases
cross diagnose --msg MSG_ID     # classify why a message failed
cross metrics                   # delivery statistics
```

See `cross.ps1 --help` for the full list of 20+ subcommands.

## Project structure

```
cross-talk/
├── CROSS_TALK.md              # Protocol specification (v1.6.1)
├── CHANGELOG.md               # Version history and discoveries
├── CROSS_WINDOWS.md           # PowerShell 5.1 / Windows pitfalls
├── LICENSE                    # MIT
├── README.md                  # This file
└── cross/
    ├── cross.ps1              # CLI entry point (20+ subcommands)
    ├── cross.config.json      # Runtime configuration
    ├── send_message.ps1       # Legacy wrapper (delegates to cross send)
    ├── lib/
    │   └── cross-format.psm1  # Formatting utilities
    ├── modules/
    │   ├── cross-transport.psm1   # HTTP transport, port detection
    │   ├── cross-state.psm1       # Outbox, idempotency, mutex
    │   ├── cross-delivery.psm1    # ACK/NACK parsing, retries, leases
    │   ├── cross-diagnostic.psm1  # Polling, status, reconcile, aviso-spof
    │   └── cross-action.psm1      # ack, nack, resume, restart, etc.
    └── tests/                 # 28 test suites (520+ assertions)
        ├── T-ack.ps1
        ├── T-nack.ps1
        ├── T-send.ps1
        ├── T-e2e.ps1
        └── ... (28 files)
```

## How it works

1. **Autodetect credentials** — port and password are read from OpenCode logs before every send (they change on restart)
2. **Write to outbox** — message is recorded in `outbox.md` with state `EN_VUELO`
3. **Send via HTTP** — `prompt_async` wakes the target agent
4. **Wait for ACK** — sender polls for acknowledgment (configurable timeout)
5. **Classify result** — ACK → `CONFIRMADO`, NACK → reason logged, timeout → diagnostic from logs
6. **Retry or DLQ** — on failure, retry with backoff; after max retries, move to dead letter queue

The full protocol rules are in [CROSS_TALK.md](CROSS_TALK.md) (section 4 for messaging, section 12 for the anti-sleep protocol).

## Running tests

```powershell
cd cross\tests
# Run all tests
Get-ChildItem T-*.ps1 | ForEach-Object { powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName }

# Run a specific test
powershell -NoProfile -ExecutionPolicy Bypass -File T-send.ps1
```

## License

[MIT](LICENSE)
