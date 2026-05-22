# llamaswap

Day-to-day LLM endpoint for the Jetson AGX Xavier. One OpenAI/Anthropic-compatible HTTP server, multiple model configs, hot-swapped per request, auto-unloaded after idle.

See [`NOTES.md`](./NOTES.md) for the engineering rationale (why these configs, build flags, gotchas, perf history).

## What's here

```
config.yaml          — model definitions
install.sh           — one-time: pulls llama-swap, builds llama-server from llama.cpp
start.sh             — launch in foreground on :8090
stop.sh              — stop (handles both bare and systemd modes; unloads first)
service-install.sh   — install/uninstall the systemd unit (boot autostart)
llama-swap           — the supervisor binary (after install.sh)
bin/                 — llama-server / llama-cli / llama-bench (after install.sh)
vendor/              — llama.cpp source checkout (after install.sh)
```

## Quick start

```
./install.sh         # one-time
./start.sh           # foreground
./stop.sh            # stop
```

Then point any OpenAI-compatible client at `http://localhost:8090/v1` (or `http://<jetson-ip>:8090/v1` from another box). The `model` field selects which underlying llama-server gets spawned (or hit, if already loaded).

Binds on `0.0.0.0:8090` by default. To restrict to loopback: `LLAMA_SWAP_HOST=127.0.0.1 ./start.sh`.

### As a systemd service (boot autostart)

```
./service-install.sh install     # writes /etc/systemd/system/llamaswap.service, enables + starts
./service-install.sh             # status
./service-install.sh uninstall   # stops + disables + removes
```

Runs as the invoking user (not root) so it inherits the same CUDA / GPU access as interactive runs. Logs: `journalctl -u llamaswap -f`. `./stop.sh` also handles the systemd case.

## Available models

All numbers measured on this Xavier with KV-q8 + the flags in `config.yaml`'s `speed_flags` macro.

| Model name | Alias | Speed (gen tok/s) | TTFT | Notes |
|---|---|---:|---:|---|
| `qwen25-coder-7b` | `coder`, `fast` | **20.8** | 0.98 s | Best interactive overall (KV-q8 + 0.5B-Coder draft, ~85% acceptance) |
| `qwen25-14b` | `14b`, `smart` | **13.5** | 2.09 s | Best 14B-class (same draft pairing) |
| `qwen35-9b-mtp` | `thinking`, `9b`, `claude-opus-4-7` | **13.6** | thinking | Best thinking model. 96k single-slot ctx; emits structured `tool_use` blocks → use this for Claude Code |
| `qwen25-coder-3b` | `tiny`, `3b` | 28.6 | 0.6 s | Fastest, limited capability |
| `qwen35-4b` | — | 13.8 | thinking | Small thinking model |
| `nemotron-nano-9b` | — | 11.7 | thinking | NVIDIA reasoning |
| `deepseek-r1-14b` | — | 28 (inflated) | thinking | Heavy hidden reasoning |
| `gemma4-e4b` | — | ~27 (inflated) | thinking | 4B-effective dense, Gemma-4 PLE |
| `gemma4-26b-q3ks` | `gemma-fast` | 58.7 | 120 s | High throughput, slow TTFT (thinking) |
| `gemma4-26b-q4km` | — | 6.8 | 75 s | Higher quant; experts on CPU |

For thinking models, "gen tok/s" can read inflated because the gen window is short — trust end-to-end where the bench harness records it. TTFT for thinking models is end-of-think, not first visible token.

## Use as a Claude Code backend

Claude Code (the CLI) talks the Anthropic `/v1/messages` protocol and hard-codes a model name like `claude-opus-4-7`. llama-swap implements that endpoint, so you just need a local model whose name/alias matches:

```
ANTHROPIC_BASE_URL=http://<jetson-ip>:8090 claude
```

The `claude-opus-4-7` alias is wired to `qwen35-9b-mtp` (96k single-slot ctx). To repoint at a different local model, move the alias in `config.yaml`, ensure its `-c` is large enough (Claude Code's prompt is ~24k+), then:

```
curl -X POST :8090/api/unload && kill -HUP $(pgrep llama-swap)
```

Unloading is needed because a config reload alone doesn't recycle already-running upstreams. The full reasoning (why `qwen35-9b-mtp` rather than `qwen25-coder-7b`, why 96k rather than 256k) lives in `NOTES.md`.

## Common operations

```
# What's currently loaded
curl -s http://localhost:8090/v1/models | python3 -m json.tool

# Force-unload everything (frees GPU)
curl -X POST http://localhost:8090/api/unload

# Tail logs
curl -N http://localhost:8090/logs/stream

# Test a model — alias works
curl -s http://localhost:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "fast", "messages": [{"role":"user","content":"hello"}], "max_tokens": 32}'

# Web UI
open http://localhost:8090/ui/
```
