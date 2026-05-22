# llamaswap — notes for the next session

Day-to-day LLM endpoint for the Jetson AGX Xavier. One OpenAI/Anthropic-compatible HTTP server, multiple model configs, hot-swapped per request, auto-unloaded after idle.

## What's here

```
config.yaml          — model definitions, copied/condensed from ../bench_llamacpp_vllm/models.yaml
install.sh           — downloads llama-swap, then builds llama-server from llama.cpp into ./bin
start.sh             — launches it on :8090
service-install.sh   — install/uninstall the systemd unit so it starts at boot
llama-swap           — the supervisor binary (after install.sh)
bin/                 — llama-server / llama-cli / llama-bench symlinks (after install.sh)
vendor/              — llama.cpp source checkout (after install.sh)
```

## Quick start

```
./install.sh         # one-time: pulls llama-swap, builds llama-server
./start.sh           # foreground
```

Then point any OpenAI-compatible client at `http://localhost:8090/v1` (or `http://<jetson-ip>:8090/v1` from another box). The `model` field selects which underlying llama-server gets spawned (or hit, if already loaded).

Binds on `0.0.0.0:8090` by default. To restrict to loopback: `LLAMA_SWAP_HOST=127.0.0.1 ./start.sh`.

To run as a systemd service that comes up at boot:

```
./service-install.sh install     # writes /etc/systemd/system/llamaswap.service, enables + starts
./service-install.sh             # shows current status
./service-install.sh uninstall   # stops + disables + removes
```

Unit runs as the invoking user (not root) so it inherits the same CUDA / GPU access as interactive runs. Logs: `journalctl -u llamaswap -f`.

## Available models (and what they actually deliver)

All numbers measured on the same Xavier, coding-category sweeps, KV-q8 + the flags shown in `config.yaml`'s `speed_flags` macro. Full per-prompt data lives in `../bench_llamacpp_vllm/results/` and `REPORT_5.md` over there.

| Model name | Alias | Speed (gen tok/s) | TTFT | Notes |
|---|---|---:|---:|---|
| `qwen25-coder-7b` | `coder`, `fast` | **20.8** | 0.98 s | Best interactive overall (KV-q8 + 0.5B-Coder draft, ~85% acceptance) |
| `qwen25-14b` | `14b`, `smart` | **13.5** | 2.09 s | Best 14B-class (same draft pairing) |
| `qwen35-9b-mtp` | `thinking`, `9b`, `claude-opus-4-7` | **13.6** | thinking | Best thinking model (Unsloth MTP heads, n_max=4). 96k single-slot ctx for Claude Code; emits structured `tool_use` blocks. Model native ctx = 256k if more is needed. |
| `qwen25-coder-3b` | `tiny`, `3b` | 28.6 | 0.6 s | Fastest, limited capability |
| `qwen35-4b` | — | 13.8 | thinking | Small thinking model |
| `nemotron-nano-9b` | — | 11.7 | thinking | NVIDIA reasoning |
| `deepseek-r1-14b` | — | 28 (inflated) | thinking | Heavy hidden reasoning |
| `gemma4-e4b` | — | ~27 (inflated) | thinking | 4B-effective dense, Gemma-4 PLE |
| `gemma4-26b-q3ks` | `gemma-fast` | 58.7 | 120 s | High throughput, slow TTFT (thinking) |
| `gemma4-26b-q4km` | — | 6.8 | 75 s | Higher quant; experts on CPU |

For thinking models, "gen tok/s" can read inflated because the gen window is short — trust end-to-end (total) where the bench harness records it. TTFT for thinking models is end-of-think, not first visible token.

## Why these specific configs

Three things came out of the bench-project work and are baked in here:

1. **KV-q8 by default** (`-ctk q8_0 -ctv q8_0` in `speed_flags` macro). Halves KV memory at no measurable speed cost on Volta, gives ~88% more effective context per cache budget. Origin: REPORT_4 in the bench project.

2. **Dedicated 0.5B-Coder draft on the 7B and 14B targets.** Qwen2.5 family shares the Qwen2 tokenizer so a Coder-tuned draft works for Instruct targets too. Measured ~85% acceptance on coding workloads → 2× speedup. The 32B coder *would* benefit but can't co-load — see "NvMap ceiling" below.

3. **MTP heads on Qwen3.5 with `n_max=4` (not 16).** The default `--spec-draft-n-max 16` collapsed acceptance to ~28% (1.03×) on the thinking 9B. Dropping to 4 lifted acceptance to ~70% (1.48×). Don't change this without re-measuring.

## What's NOT in here (and why)

These are configured in the bench project but were dropped or untested:

- **qwen25-coder-32b-q4km** — confirmed via probe that the 18.5 GB target can't be allocated as a single CUDA buffer on Xavier (NvMap single-block ceiling). Would need partial offload, which kills spec-decoding ROI.
- **qwen36-27b-q4km, qwen3.x-35b-a3b-iq3xxs, nemotron3-nano-30b-a3b** — same NvMap territory or untested at current defaults. `--cpu-moe` works for these as an escape hatch (~7 tok/s, see gemma4-26b-q4km) but isn't a speed win.
- **apriel-nemotron-15b-q4km** — had jinja chat template issues in earlier sweeps; YAML in bench project forces chatml but hasn't been re-swept since.

## Sister project

`../bench_llamacpp_vllm/` — the benchmark harness that produced all these numbers. It has its own `llama-server` build; this project no longer depends on it. `install.sh` here builds its own copy into `./bin/` (same CUDA sm_72 / CMake flags), so the two projects can be updated independently.

Other things from the bench project worth knowing:
- `flush_mem.sh` in the bench dir (`sudo ./flush_mem.sh`) drops page cache + compacts memory. Useful between heavy back-to-back loads. llama-swap's TTL+process-exit cycle already gives the page cache a chance to drop, so usually unnecessary here.
- `models.yaml` in the bench dir is the source of truth for measurements; `config.yaml` here is the *production translation* of the proven configs.
- Reports `REPORT.md` through `REPORT_5.md` document the perf journey — most relevant ones for tuning decisions:
  - `REPORT_4.md` — KV-q8 + speculative decoding deep dive
  - `REPORT_5.md` — current lineup status

## Common operations

```
# Start it
./start.sh

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
```

### Point Claude Code at it

Claude Code (the CLI) talks the Anthropic `/v1/messages` protocol and hard-codes a model name like `claude-opus-4-7`. llama-swap implements that endpoint, so you just need a local model whose name/alias matches what the client asks for:

```
ANTHROPIC_BASE_URL=http://<jetson-ip>:8090 claude
```

Currently `qwen35-9b-mtp` carries the `claude-opus-4-7` alias and runs at **96k context with a single slot** (`-c 98304 -np 1`) so a long Claude Code session fits. The single-slot setup is appropriate here because Claude Code is a single-user agent — no benefit to splitting KV memory across 4 slots — and it lets the whole KV budget go to one big conversation. To repoint at a different local model, move the alias in `config.yaml`, ensure that model's `-c` is large enough (Claude Code's prompt is ~24k+), then `curl -X POST :8090/api/unload && kill -HUP $(pgrep llama-swap)` — unloading is needed because a config reload alone doesn't recycle already-running upstreams.

**Why qwen35-9b-mtp and not qwen25-coder-7b**: Claude Code needs the upstream to emit structured `tool_use` content blocks. Tested both — Qwen2.5-Coder emits the call as plain `<tools>{"name":...,"arguments":...}</tools>` text (it's code-tuned, not agent-tuned), so llama.cpp's tool-call parser doesn't recognize it (`Chat format: peg-native` in the upstream logs), Claude Code never sees a tool call, and the model confabulates file contents. Qwen3.5-9B has dedicated function-calling training and emits proper `tool_use` blocks (plus a `thinking` block, which Claude Code handles). Trade-off: ~13.5 tok/s vs 20+ for the coder, and every turn pays a hidden-think TTFT.

**Why 96k and not 256k (the model's native max)** — four reasons, in rough order of bite:

1. *KV cache is the dominant GPU cost at long context, not the weights.* Qwen3.5-9B Q6_K is ~7.7 GB of weights, but each token of KV at q8 across ~40 layers / 8 KV heads / 128 head_dim is ~80 KB. So 96k ≈ 7.7 GB of KV, 196k ≈ 15 GB, 256k ≈ 20 GB. Xavier has 32 GB total unified — model + KV + draft + activations + scratch is already tight at 96k. Higher risks OOM during prefill of a long prompt (loads fine, then crashes mid-conversation).
2. *Prefill scales linearly with prompt length.* This build does ~200 prefill tok/s. A full 96k prompt is already ~8 min of "cursor sitting there" before any output; 256k would be ~21 min per turn. Thinking-model TTFT compounds on top of that.
3. *Effective recall < nominal context.* "Native to 256k" means the model was *trained* on sequences that long, not that 9B-class retrieval stays sharp at the limit. Pushing past ~half the nominal max tends to mean the model politely makes things up rather than flagging that it didn't find the relevant chunk.
4. *Diminishing returns vs. /compact.* Claude Code auto-compacts history. System prompt + tools is ~24k *fixed*; the rest is conversation. 96k − 24k = ~72k of conversation room (hundreds of turns before compact triggers). Doubling that mostly buys a more bloated conversation, not a more capable one.

If a session does start hitting 96k regularly, pushing to ~131k is fine; beyond that, prefill latency starts to dominate.


## Things worth trying next

In rough order of expected value (from REPORT_5 "open experiments" list):

1. **MTP `n_max=4` on bigger MTP variants** (Qwen3.5-27B-MTP, Qwen3.5-35B-A3B-MTP from Unsloth). Bigger target → more wall-clock saved per accepted token. Pull, add to config, measure.
2. **`--cpu-moe` on the qwen3.x-35b-a3b variants** as the principled replacement for the `-fit off` hack. They'll be slow (~7 tok/s, per gemma4-26b-q4km data) but at least cleanly configurable.
3. **A separate small thinking-model draft** (Qwen3.5-0.8B) for the 9B/27B Qwen3.5 targets, to compare against MTP. Might displace MTP if acceptance is higher.

## llama-server build flags (and why)

`install.sh` builds llama-server from `vendor/llama.cpp` with these CMake flags:

```
-DGGML_CUDA=ON
-DCMAKE_CUDA_ARCHITECTURES=72       # Volta on Xavier
-DGGML_CUDA_FA_ALL_QUANTS=ON        # compile FA kernels for every quant we use
-DLLAMA_CURL=ON
-DCMAKE_BUILD_TYPE=Release
```

`Release` mode auto-enables the things that matter on this board: `GGML_NATIVE` (picks up NEON / ARM_FMA), `GGML_CCACHE`, `GGML_CUDA_FA`, `GGML_CUDA_GRAPHS`, CUDA VMM. Verified against the bench project's `build/CMakeCache.txt`.

The non-obvious one is **`GGML_CUDA_FA_ALL_QUANTS=ON`**. By default llama.cpp only compiles flash-attention kernels for a common subset of quant types — Q4_0, Q4_1, Q8_0, F16. Our `config.yaml` mixes Q6_K targets, Q8_0 KV cache, Q4_K_M drafts, Q5_K_M, Q3_K_S, IQ3_XXS — if any of those combinations hit a missing kernel, FA silently falls back to a non-FA path that's significantly slower (and we wouldn't notice from tok/s alone since it just degrades quietly). `FA_ALL_QUANTS` makes the build slower but guarantees FA is actually engaged for every config we run. Tradeoff is build time only, not runtime.

### Flags considered but not set

- **`GGML_CUDA_FORCE_MMQ=ON`** — forces MMQ kernels over cuBLAS. Sometimes a win on older arch (Pascal). The bench project tested it on/off in early sweeps (see `logs/llamacpp-7B_Q4_K_M_+_MMQ_off-*` from 2026-05-17) and didn't enable it as the default — keeping default OFF until re-measured on this lineup.
- **`GGML_LTO=ON`** — link-time optimization, default OFF. Marginal runtime win for substantially longer link step. Skipped.
- **`GGML_CUDA_NO_PEER_COPY=ON`** — only relevant for multi-GPU; Xavier is single-GPU. Default OFF is correct.

### Rebuilding

```
rm -rf vendor/llama.cpp/build
./install.sh         # picks up the missing build, prompts to rebuild
```

To pull in a new upstream llama.cpp commit:

```
git -C vendor/llama.cpp fetch --depth 1 origin
git -C vendor/llama.cpp reset --hard origin/master
rm -rf vendor/llama.cpp/build
./install.sh
```

## Diagnostics

- `llama-swap` binary version: `./llama-swap --version`
- GPU state: `tegrastats --interval 1000` or `cat /proc/meminfo | grep -i cuda` (no /proc/cuda on Tegra — use `tegrastats` for GR3D_FREQ)
- If a model fails to load: check `http://localhost:8090/logs/stream/upstream` — it shows the raw llama-server output for the most recent swap.

## Don't repeat these mistakes

- **Don't add `cma=<size>` to `/boot/extlinux/extlinux.conf`.** Tried it during the bench session — kernel rejects sizes >4G and even smaller values broke nvgpu firmware init, killing the GPU until the boot arg was removed. NvMap manages its own pool independent of generic CMA. Use `--cpu-moe` or smaller quants instead.
- **Don't run single-model sweeps back-to-back without flushing memory** — page cache fragmentation can cause SIGSEGV on the next model load. The bench harness's `flush_mem.sh` (or llama-swap's TTL-based unload) is the safe path.
