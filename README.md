# SenseNova U1.5 server

A resident MLX-Swift model with OpenAI-style vision/chat, image generation and instruction editing on port **8003**. Requires Apple Silicon, macOS 26.4+, Xcode with the Metal toolchain, Swift 6.2+, and local SenseNova artifacts. The implementation uses Apple's [Network framework](https://developer.apple.com/documentation/network) to keep the HTTP dependency surface small. HTTP is deliberately limited to one request per connection; SSE is streamed over that connection.

## Why this exists

This server gives the [Hermes](https://github.com/NousResearch/hermes-agent) agent its eyes. Hermes sends screenshots to an OpenAI-style vision endpoint (its `auxiliary.vision` model) whenever it has to look at its own work, for example to check a rendered game HUD. Before this server, that vision model was Qwen3.8-27B running locally. Side by side on the same game screenshot, SenseNova U1.5 (8-step tier) answered faster (20 s vs 28 s including load), read the on-screen text accurately and invented nothing, while Qwen added more detail but made up a game title and misread a label. SenseNova had no HTTP server of its own, so this package wraps it in an OpenAI-compatible API and keeps the model resident. Hermes now uses it as its primary vision model, with Qwen kept as a fallback.

## Build and run

The model code comes from the upstream MIT library [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift), pinned by Swift Package Manager to commit `0efc029` and used unmodified. Download the SenseNova U1.5 weights separately (for example `mlx-community/SenseNova-U1.5-8B-MoT-8step-v2-8bit`). Default layout:

```
~/Development/sensenova-server/        # this package
~/sensenova/SenseNova-U1.5-8B-MoT-8step-v2-8bit/
```

Build, test and run:

```sh
cd ~/Development/sensenova-server
swift build -c release
swift test
.build/release/sensenova-server
```

The server loads the artifact before listening. It creates a random 48-character key at `~/.sensenova/api-key` with mode 600 if absent. An existing key must have at least 40 characters and be private and owned by the server user. The key is never logged. Every path except `/health` requires the exact `Authorization: Bearer KEY` header.

| Flag | Environment | Default |
|---|---|---|
| `--host` | `SENSENOVA_HOST` | `0.0.0.0` |
| `--port` | `SENSENOVA_PORT` | `8003` |
| `--weights` | `SENSENOVA_WEIGHTS` | `~/sensenova/SenseNova-U1.5-8B-MoT-8step-v2-8bit` |
| `--api-key-file` | `SENSENOVA_API_KEY_FILE` | `~/.sensenova/api-key` |
| `--idle-unload-minutes` | `SENSENOVA_IDLE_UNLOAD_MINUTES` | `0` (resident indefinitely) |

Flags override environment. Idle unloading is checked every 15 seconds on the GPU queue; the next job reloads the artifact. A weights path containing `bf16` selects model id `sensenova-u1.5-bf16` and image defaults of 50 steps / cfg 4. Otherwise the id is `sensenova-u1.5-8step`, with 8 steps / cfg 1. The optional bf16 tier has not been benchmarked by this package. No Python is used by the server.

## API examples

These commands run on the Mac. Supply the key through curl's stdin config to avoid putting it in process arguments:

```sh
auth_curl() {
  { printf 'header = "Authorization: Bearer '; tr -d '\r\n' < "$HOME/.sensenova/api-key"; printf '"\n'; } |
    curl --config - "$@"
}
curl -s http://127.0.0.1:8003/health
auth_curl -s http://127.0.0.1:8003/v1/models

auth_curl -s http://127.0.0.1:8003/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"sensenova-u1.5-8step","messages":[{"role":"system","content":"Answer briefly."},{"role":"user","content":"Hello"}],"max_tokens":100,"temperature":0}'
```

For vision, construct a JSON request with image data parts (Python here is just a client helper):

```sh
python3 - <<'PY' > /tmp/vision.json
import base64, json
from pathlib import Path
uri = 'data:image/png;base64,' + base64.b64encode(Path.home().joinpath('sensenova/vqa-test.png').read_bytes()).decode()
print(json.dumps({'messages': [{'role': 'user', 'content': [
    {'type': 'image_url', 'image_url': {'url': uri}},
    {'type': 'text', 'text': 'Describe this screenshot.'}
]}], 'max_tokens': 1536, 'temperature': 0, 'stream': True}))
PY
auth_curl -N http://127.0.0.1:8003/v1/chat/completions \
  -H 'Content-Type: application/json' --data-binary @/tmp/vision.json
```

SSE emits role, incremental content, final finish reason/usage, then `data: [DONE]`. Partial UTF-8 tokens are held until valid text is available. `stream:false` returns the complete answer with `choices[0].message.content`, `finish_reason` and token usage. Prompt usage includes ChatML and expanded image tokens; completion usage excludes the stop token, which the library does not return. `max_tokens` is 1–4096 (default 1536), `temperature` 0–2 (default 0 / greedy), `top_p` 0.001–1 (default 1). Unknown fields, including `chat_template_kwargs`, `reasoning_effort`, `extra_body` and `model`, are ignored. The selected resident artifact always determines the model.

```sh
auth_curl -s http://127.0.0.1:8003/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"A red sailboat on a mountain lake at sunrise","size":"1024x1024","n":1,"steps":8,"cfg":1,"seed":42,"response_format":"b64_json"}' \
  > /tmp/generation.json
python3 - <<'PY'
import base64, json
from pathlib import Path
value = json.loads(Path('/tmp/generation.json').read_text())
Path('/tmp/boat.png').write_bytes(base64.b64decode(value['data'][0]['b64_json']))
PY

auth_curl -s http://127.0.0.1:8003/v1/images/edits \
  -F image=@/tmp/boat.png \
  -F 'prompt=Change the red sail to yellow. Preserve everything else.' \
  -F size=1024x1024 -F steps=8 -F cfg=1 -F seed=42 > /tmp/edit.json
```

Both image routes return `{"created": UNIX_SECONDS, "data":[{"b64_json":"PNG_BASE64"}]}`. Only `n:1` and `response_format:b64_json` are supported. Size defaults to 1024x1024, including edits. The library supports a factor-32 grid: accepted sizes are multiples of 32, 256–2048 pixels per side, aspect ratio at most 4. Steps are 1–100; cfg 1–10; seed is a nonnegative signed 64-bit integer (default 42). The fast tier's intended recipe is 8 steps / cfg 1; overriding it does not turn it into the base quality tier. PNG encoding uses upstream's native Swift/ImageIO encoder, with rounded/clamped `x*0.5+0.5` RGB conversion.

## Scope and operations

- Chat supports ordered system, user and assistant history, plus up to four images across user turns. It ends with a user turn and is recomputed each request; there is no server-side conversation or KV session. No tools/functions, audio, image URLs over HTTP(S), or thinking-mode switch. A closed think block selects the same immediate-answer path as the CLI.
- Text strings and arrays of text/image_url parts are accepted. Raw reserved ChatML/image tokens are rejected to protect upstream image-splice preconditions. Roles are rendered as proper ChatML turns. Multi-image history is passed to the library in prompt order.
- One GPU job runs at a time with up to eight waiting; overflow is HTTP 429 with `Retry-After: 5`. Health's `queue` is the waiting count. Invalid requests return OpenAI-shaped JSON errors. Inference errors after SSE begins are SSE error objects followed by `[DONE]`.
- Request bodies are limited to 25 MiB; headers to 16 KiB; there are at most 64 receiving/serving connections. Upload timeout is 30 seconds. Input images are decoded and limited to 8192 per side / 20 million pixels before upstream resizing. Chat prompt limit is 16384 tokens, including expanded images; message limit is 128.
- HTTP/1.0 and HTTP/1.1 with Content-Length are supported, including `Expect: 100-continue`. There is no keepalive, pipelining, chunked request upload, TLS, or CORS. Chunked uploads receive 411. Use on a trusted LAN or behind a TLS proxy as appropriate for your setup.
- Client disconnects do not cancel accepted GPU work. SIGTERM/SIGINT stops listening and drains the serial GPU queue. The MLX allocation cache is capped at 1 GiB and cleared after each job while model weights stay resident.
- [deploy/sensenova-server.plist](deploy/sensenova-server.plist) is a LaunchAgent template that sends logs to `~/Library/Logs/`. Replace `/Users/YOU` with your home directory before installing; launchd does not expand `~`. Each job writes one `Job finished` log line with its duration, `type=chat|vqa|generate|edit`, `ok` or `error`, and token or image-size details.

To run the acceptance checks after starting the server, put its exact PID in `proof/server.pid` (the `proof/` output folder is git-ignored), then run `python3 scripts/prove.py` on the Mac. That Python script is a proof driver using curl, not a server dependency. Stop the exact server PID after testing; do not match processes by command text.

## Measured on the M4 Max

With the default 8-step v2 int8 artifact: warm VQA **18.59 s** for 508 output tokens; streaming **3.54 s** to first content / **19.44 s** total. Repeated standalone VQA varied up to **96.28 s** while other models shared the machine. First 1024x1024 generation with resident weights took **21.51 s**; editing took **23.72 s** (8 steps, cfg 1). Steady model allocations were about **18.51 GiB**; the server's observed physical-footprint peak was **20.440 GiB** with the 1 GiB allocation cache cap. These measurements are fixture-specific. Without the allocation-cache cap the process footprint reached about 50.8 GiB, which is why the server sets one.

## Similar projects

Checked in November 2026 from each project's own README or package page; features change, so check the current docs.

| Project | Runtime | Model | Image Q&A / chat | Generate | Edit | API |
|---|---|---|---|---|---|---|
| **sensenova-server** (this) | Swift, MLX, Network.framework | SenseNova U1.5 8B (8-step tier by default), one resident model | yes | yes | yes | `/v1/chat/completions`, `/v1/images/generations`, `/v1/images/edits` |
| [sensenova-mlx](https://github.com/Ericdaany0312/sensenova-mlx) | Python, MLX | SenseNova U1.5 8B, optional 8-step LoRA | no | yes | no (not in 0.2.0) | `/v1/images/generations` |
| [SenseNova-U1 official deployment](https://github.com/OpenSenseNova/SenseNova-U1/blob/main/docs/deployment.md) (LightLLM + LightX2V) | Python, Docker, CUDA (examples use 2 GPUs) | SenseNova U1 | yes | yes | yes | all three through `/v1/chat/completions`; images requested with `"modalities": ["image"]` |
| [vLLM-Omni](https://docs.vllm.ai/projects/vllm-omni/en/stable/user_guide/examples/online_serving/sensenova_u1/) | Python, CUDA | SenseNova-U1-8B-MoT | yes | yes | yes | all three through `/v1/chat/completions` |
| [mlx-openai-server](https://github.com/cubist38/mlx-openai-server), [vMLX](https://pypi.org/project/vmlx/), [Rapid-MLX](https://ai-tldr.dev/tools/rapid-mlx/), [mlx-lm-server](https://github.com/Ar9av/mlx-lm-server) | Python (mlx-lm-server: Rust + Python), MLX | general: a vision model (Qwen-VL, Gemma, …) plus a separate image model (FLUX, Z-Image, …) | yes | yes | some | OpenAI-compatible, multi-model |
| [mlx-serve](https://github.com/raspoli/mlx-serve), [mlx-router](https://github.com/henrybravo/mlx-router) | Python, MLX | general vision/language models | yes | no | no | OpenAI-compatible |

What sets this package apart: a native Swift server (no Python at runtime), and a single unified SenseNova model that both looks at images and draws them, so one resident ~20 GB model replaces a separate vision model and image generator. The official CUDA servers return generated images inside chat completions; this server also offers the standard OpenAI Images routes (`/v1/images/generations`, `/v1/images/edits`), so ordinary image clients work unchanged. It builds on the upstream [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift) port. Pick a general MLX server instead if you want to switch between many models, or the official CUDA deployment for NVIDIA hardware.

## License

MIT, see [LICENSE](LICENSE). The upstream library is MIT; the SenseNova model weights have their own license (Apache-2.0 for the U1.5 releases).
