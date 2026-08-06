# CLAUDE.md - DKR_AI_Lab

Guidance for Claude Code when working in this project.

## Project Overview

Self-hosted AI lab — Open WebUI, llama.cpp, SearXNG, and the MCPJungle MCP gateway
behind one Traefik v3 proxy with Let's Encrypt DNS-01 TLS. `README.md` is the setup
guide; keep it in sync.

## Conventions

**Bring-up.** The root `compose.yaml` is only an `include:` list of per-service files;
run every command from the project root (`docker compose up -d`). Four are active
(`traefik/`, `open-webui/`, `SearXNG/`, `mcpjungle/`); `llama.cpp/` is commented out
and does not start — see below. Running `docker compose -f <service>/compose.yml` from
a service directory starts a *separate* project.
`include:` resolves each file's relative paths *and* its interpolation `.env`
against that file's own directory — which is why `mcpjungle/.env`, not a root one,
supplies `BRAVE_API_KEY`.

**State — read this before renaming anything.** `compose.yaml` has no top-level
`name:`, so Compose derives the project name from the directory basename
(`DKR_AI_Lab` → `dkr_ai_lab`) and prefixes the named volumes: `dkr_ai_lab_open-webui2`
(chats, users, settings), `dkr_ai_lab_searxng-core-data`, `dkr_ai_lab_searxng-valkey-data`,
`dkr_ai_lab_mcpjungle-db-data` (the MCP registry), `dkr_ai_lab_mcpjungle-uv-cache`.
Renaming, moving, or copying this directory silently brings Open WebUI up on a fresh
empty volume and orphans all chat history; adding `name:` later does the same unless
the volume is renamed too. Check `docker volume ls` first. `down -v` destroys all five.
Only the MCP registry survives that: the `mcpjungle-register-*` and
`mcpjungle-create-groups` one-shot jobs re-apply it from JSON on every `up`.

**Networks.** Everything Traefik must reach joins `ai-lab` / `name: AI-LAB`. MCPJungle
adds a second, `mcpjungle` / `name: MCPJUNGLE`, holding its Postgres and its MCP
servers; only the `mcpjungle` gateway container joins both. Those servers'
endpoints are unauthenticated, so do not move one onto AI-LAB to "make it reachable"
— register it with the gateway instead.

**Exposure.** Traefik binds host ports 443 and 10001-10003 and routes five hosts from
`traefik/proxies.yml`: oracle (Open WebUI), llm (llama.cpp), search (SearXNG), mcp
(MCPJungle), plus lmstudio — a host process via `host.docker.internal`. Three are
unauthenticated: `open-webui/.env` sets `WEBUI_AUTH=False`, llama.cpp runs with no
`--api-key`, and MCPJungle defaults to `SERVER_MODE=development`. Treat as
trusted-LAN-only. SearXNG also publishes `9001:8080` and MCPJungle `8080:8080` on all
interfaces, bypassing TLS.

**Secrets.** All `.env` files, `traefik/letsencrypt/acme.json`, and
`SearXNG/core-config/settings.yml` are gitignored with committed `.example` siblings —
update both in the same commit. Name variables, never values: `CF_DNS_API_TOKEN`,
`OPENAI_API_KEY`, `WEBUI_SECRET_KEY`, `BRAVE_SEARCH_API_KEY`, `BRAVE_API_KEY`,
`server.secret_key`. Brave is keyed twice, from separate files: `open-webui/.env` for
Open WebUI's own web search, `mcpjungle/.env` for the Brave MCP server.

**llama.cpp is disabled.** Its `include:` line in `compose.yaml` is commented out, so
`docker compose up -d` no longer tries to start it. Three separate reasons, all of
which must be dealt with before re-enabling: the `volumes:` entry is a literal Windows
path (`C:\Users\ahill\.lmstudio\models\lmstudio-community:/models`) that Docker rejects
outright; this host has no working NVIDIA driver; and `--model` names
`gpt-oss-20b-GGUF/gpt-oss-20b-MXFP4.gguf`, while `~/.lmstudio/models/lmstudio-community`
holds only `gemma-4-E4B-it-GGUF`. The file also declares `ai-lab` without `name:
AI-LAB`, which the other files' `name:` currently masks at merge time but which will
bite as soon as it is included again. `traefik/proxies.yml` still routes
`llm.ham51.com` to it and will 502 until then.

**Broken config, don't copy as a pattern.** `open-webui/.env` writes its four
web-search lines as YAML `KEY: "value"`, but `env_file:` parses only `KEY=value`, so web
search never reaches the container (`.env.example` is correct). `recommendations.md`
reviews these — note its `searxng-valkey` finding is fixed, not open.

**MCP registrations are code, not database rows.** `mcpjungle/mcp-servers/*.json` and
`mcpjungle/tool-groups/*.json` are the source of truth; the one-shot jobs overwrite
whatever is in Postgres. Adding a server means adding a `mcpjungle-register-<name>`
job *and* a `depends_on` entry in `mcpjungle-create-groups` — groups are validated
against the live registry, so an unregistered tool fails the whole group job.

## Dependencies

Only `traefik:v3.7.8`, `postgres:17`, and `prom/prometheus:v2.53.0` are pinned;
`searxng:latest`, `open-webui:main`, `llama.cpp:server-cuda`, `mcpjungle:latest-stdio`,
`mcp/brave-search:latest`, and `mcp/context7:latest` re-resolve on every pull, so
rebuilds are not reproducible. llama.cpp needs an NVIDIA GPU and the NVIDIA Container
Toolkit. MCPJungle needs the `-stdio` image tag specifically — it ships the `uvx` and
`python3` that stdio servers such as `fetch` are spawned with; plain `latest` cannot
run them.

---

This file loads as live instructions every session — keep it short and true.
A stale rule here is worse than no rule, and it is not a place to park notes
meant for somewhere else.
