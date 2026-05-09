# local-llm

Shell helper to start and stop a local Ollama stack on macOS. Two **profiles** differ by whether you also run embeddings and Qdrant for vector search.

## Profiles

| Profile | What runs | `OLLAMA_MAX_LOADED_MODELS` | Docker required |
|---------|-----------|----------------------------|-----------------|
| **indexed** | Embedding model + LLM + Qdrant | 2 | Yes |
| **plain** | LLM only (no vector index) | 1 | No |

**Aliases**

| Alias | Maps to |
|-------|---------|
| `vectored`, `roo` | indexed |
| `aider`, `aider-vision`, `cursor` | plain |

Use **indexed** for RAG / codebase indexing (e.g. Roo). Use **plain** for tools that only need chat completion (e.g. Aider vision workflows).

## Prerequisites

- [Ollama](https://ollama.com/) and `curl`
- **indexed only:** Docker (for Qdrant)

On Apple Silicon, `start` launches Ollama with `OLLAMA_MLX=1` when it is not already running.

## Quick start

```bash
chmod +x local-llm.sh

# Full stack (embedding + LLM + Qdrant)
./local-llm.sh start vectored
./local-llm.sh status indexed
./local-llm.sh stop

# LLM only (no Docker, no Qdrant)
./local-llm.sh start aider-vision
./local-llm.sh stop plain
```

Profile can appear before or after the command:

```bash
./local-llm.sh aider-vision start
./local-llm.sh start aider-vision
```

Default profile is **indexed** if omitted.

## Configuration

You can set models and paths without editing the script. Pick what fits how you work:

| Approach | Best for |
|----------|----------|
| **`local-llm.env`** (recommended) | Defaults you keep on this machine; copy from `local-llm.env.example` |
| **Shell exports** | One-off runs, CI, or scripts that wrap `local-llm.sh` |
| **`~/.config/local-llm/env`** | Machine-wide defaults shared across clones |

**Precedence** (highest wins): variables already in your shell (including `DATA_MODEL=… ./local-llm.sh`) → repo `.env` (overrides `local-llm.env`) → `local-llm.env` → `~/.config/local-llm/env` → built-in defaults.

### Model variables

Users usually think in two models:

| You set | Role | Used when |
|---------|------|-----------|
| `INDEX_MODEL` or `EMBEDDING_MODEL` | Embedding / index model | **indexed** only |
| `DATA_MODEL`, `CHAT_MODEL`, or `LLM_MODEL` | Chat / completion model | **indexed** and **plain** |

All names are aliases for the same Ollama tags. If both `INDEX_MODEL` and `EMBEDDING_MODEL` are set, `EMBEDDING_MODEL` wins. Same for `DATA_MODEL` vs `LLM_MODEL`.

```bash
cp local-llm.env.example local-llm.env
# edit INDEX_MODEL and DATA_MODEL
./local-llm.sh start vectored
```

One-off override without a file:

```bash
DATA_MODEL=llama3.2:latest ./local-llm.sh start aider-vision
```

`status` prints the active chat and index model names and which config file was loaded last.

## Commands

| Command | Description |
|---------|-------------|
| `start` | Pull models (if needed), start Ollama, preload models; indexed also starts Qdrant |
| `stop` | Shut down services for the selected profile |
| `status` | Print Ollama, model, and (indexed) Qdrant health |
| `help` | Usage summary |

### Stop options

| Option | Effect |
|--------|--------|
| `--keep-ollama` | Unload models but leave the Ollama server running |
| `--keep-qdrant` | Do not stop Qdrant (**indexed** only) |
| `--force` | Kill processes without graceful unload |

```bash
./local-llm.sh stop indexed --keep-ollama
./local-llm.sh stop --keep-qdrant
```

## Environment variables

See [Configuration](#configuration) for precedence and model aliases.

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_MODE` | `indexed` | Profile: `indexed` or `plain` (aliases accepted) |
| `DATA_MODEL` / `CHAT_MODEL` / `LLM_MODEL` | `qwen3.6:27b-q4_K_M` | Chat / generate model |
| `INDEX_MODEL` / `EMBEDDING_MODEL` | `nomic-embed-text` | Embedding model (**indexed** only) |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API base URL |
| `QDRANT_STORAGE` | `<repo>/qdrant_storage` | Host path for Qdrant data |
| `QDRANT_CONTAINER_NAME` | `qdrant` | Docker container name |

`ROO_AGENT` is deprecated; use `LLM_MODE` instead.

## What `start` does

**indexed**

1. Ensure Ollama is running (start with MLX if needed).
2. Require Docker; pull embedding + LLM models.
3. Preload both models in memory.
4. Create or start the Qdrant container on ports 6333/6334.

**plain**

1. Ensure Ollama is running.
2. Pull and preload the LLM model only.
3. Skip Docker and Qdrant.

Ollama logs when auto-started: `~/.ollama/logs/server.log`.

## License

MIT
