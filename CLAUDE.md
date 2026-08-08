# CLAUDE.md - DKR_AI_Lab

Guidance for Claude Code when working in this project.

## Project Overview

Self-hosted AI lab — Open WebUI, llama.cpp, SearXNG, the MCPJungle MCP gateway, and
the Hermes agent behind one Traefik v3 proxy with Let's Encrypt DNS-01 TLS.
`README.md` is the setup guide; keep it in sync.

## Conventions

**Bring-up.** The root `compose.yaml` is only an `include:` list of six per-service
files (`traefik/`, `open-webui/`, `SearXNG/`, `llama.cpp/`, `mcpjungle/`, `hermes/`);
run every command from the project root (`docker compose up -d`). Running `docker
compose -f <service>/compose.yml` from a service directory starts a *separate* project.

**Two kinds of `.env`, and mixing them up fails silently.** `include:` resolves each
file's relative paths *and* its interpolation `.env` against that file's own directory
— which is why `mcpjungle/.env` supplies `BRAVE_API_KEY` and `llama.cpp/.env` supplies
`LLAMA_MODEL`. But `COMPOSE_PROFILES` is read once *per project*, so it only works in
the root `.env`. Put it in `llama.cpp/.env` and Compose reads the file, ignores the
variable, and leaves both llama services absent with no error at all. Root `.env` also
feeds interpolation everywhere as a fallback; service `.env` files do not leak upward.

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
Hermes is the exception to all of this — its state is the `hermes/hermes-data/` bind
mount, not a named volume, so `down -v` leaves it alone and moving the directory moves
the agent. It is still the only copy, with no backup configured.

**Networks.** Everything Traefik must reach joins `ai-lab` / `name: AI-LAB`. MCPJungle
adds a second, `mcpjungle` / `name: MCPJUNGLE`, holding its Postgres and its MCP
servers; only the `mcpjungle` gateway container joins both. Those servers'
endpoints are unauthenticated, so do not move one onto AI-LAB to "make it reachable"
— register it with the gateway instead.

**Exposure.** Traefik binds host ports 443 and 10001-10003 and routes six hosts from
`traefik/proxies.yml`: oracle (Open WebUI), llm (llama.cpp), search (SearXNG), mcp
(MCPJungle), hermes (the Hermes dashboard), plus lmstudio — a host process via
`host.docker.internal`. Three are unauthenticated: `open-webui/.env` sets
`WEBUI_AUTH=False`, llama.cpp runs with no `--api-key`, and MCPJungle defaults to
`SERVER_MODE=development`. Treat as trusted-LAN-only. SearXNG also publishes
`9001:8080` and MCPJungle `8080:8080` on all interfaces, bypassing TLS. Hermes is the
one exception: password-gated, and published on no host port at all.

**Hermes is a dashboard bolted to a gateway, and they are different processes.** The
container's main command is `gateway run` (messaging platforms + cron); the web
dashboard is a *separate s6-supervised service* in the same image. It stays down
unless `HERMES_DASHBOARD` is truthy — the run script exits 0 and the finish script
returns 125, so there is no error anywhere, just no dashboard. `gateway run` itself
survives an empty `hermes-data/` and no platform config; it warns "No messaging
platforms enabled" and keeps running, so a fresh install does not crashloop.

Because Traefik reaches the dashboard across AI-LAB, it binds `0.0.0.0` inside the
container, and any non-loopback bind engages the auth gate: `start_server` fails
closed unless an auth provider is registered. `HERMES_DASHBOARD_INSECURE` has been a
no-op since the June 2026 hardening and there is no bypass. `hermes/.env` carries the
bundled password provider's `HERMES_DASHBOARD_BASIC_AUTH_*` keys; leave them blank and
the container runs normally while hermes.ham51.com never answers. Store
`_PASSWORD_HASH` (scrypt), not `_PASSWORD`, and set `_SECRET` or every restart
invalidates all sessions.

**Secrets.** All `.env` files, `traefik/letsencrypt/acme.json`, and
`SearXNG/core-config/settings.yml` are gitignored with committed `.example` siblings —
update both in the same commit. Name variables, never values: `CF_DNS_API_TOKEN`,
`OPENAI_API_KEY`, `WEBUI_SECRET_KEY`, `BRAVE_SEARCH_API_KEY`, `BRAVE_API_KEY`,
`server.secret_key`. Brave is keyed twice, from separate files: `open-webui/.env` for
Open WebUI's own web search, `mcpjungle/.env` for the Brave MCP server.

**llama.cpp is profile-gated.** `llama.cpp/compose.yml` defines the same server twice
— `llama-cuda` (profile `cuda`, `server-cuda`, needs the NVIDIA Container Toolkit) and
`llama-vulkan` (profile `vulkan`, `server-vulkan`, needs a `/dev/dri` render node) —
sharing everything else through the `x-llama-common` anchor. One definition cannot
cover both: CUDA needs a `deploy.resources.reservations.devices` block and Vulkan needs
`devices:`, and interpolation can substitute values but not include a block. Both carry
the network alias `llama-gpt-oss`, so `traefik/proxies.yml` addresses either without
change. Neither starts unless `COMPOSE_PROFILES` names its profile; `llama.cpp/detect-gpu.sh`
writes that to the root `.env`, testing for the *runtime* in `docker info` rather than
for hardware — this host has a stale `/dev/nvidiactl` and no NVIDIA card, so probing
`/dev/nvidia*` would pick CUDA and fail at container start.

**Docker Desktop cannot pass through a GPU.** Its containers run in a linuxkit VM with
no `/dev/dri`, so `llama-vulkan` dies with `error gathering device information while
adding custom device "/dev/dri"` even though the host has the node. This machine runs
both a Desktop daemon and a native one; `docker context ls` shows which is active, and
GPU work needs `default`. Verified on `default`: Vulkan0 = AMD Radeon 880M, and
`LLAMA_NGL=999` measured 2.9x the prompt throughput of `LLAMA_NGL=0`.

**Broken config, don't copy as a pattern.** `open-webui/.env` writes its four
web-search lines as YAML `KEY: "value"`, but `env_file:` parses only `KEY=value`, so web
search never reaches the container (`.env.example` is correct). `recommendations.md`
reviews these — note its `searxng-valkey` finding is fixed, not open.

**MCP registrations are code, not database rows.** `mcpjungle/mcp-servers/*.json` and
`mcpjungle/tool-groups/*.json` are the source of truth; the one-shot jobs overwrite
whatever is in Postgres. Adding a server means adding a `mcpjungle-register-<name>`
job *and* a `depends_on` entry in `mcpjungle-create-groups` — groups are validated
against the live registry, so an unregistered tool fails the whole group job.

**Open WebUI's copy of those groups seeds once.** `open-webui/compose.yml` sets
`TOOL_SERVER_CONNECTIONS` (JSON, one entry per tool group, each needing `"type":
"mcp"` and `"config": {"enable": true}` — the default type is `openapi`, and an entry
without `enable` is stored and ignored). Unlike the mcpjungle jobs this does *not*
converge on every `up`: Open WebUI falls back to the env var only while the
`tool_server.connections` row is absent from `webui.db`, so the first save in Admin
Settings → External Tools makes the UI authoritative and later edits to the compose
file do nothing until that row is deleted. A group is reached at
`http://mcpjungle:8080/v0/groups/<name>/mcp` over AI-LAB, and only when a chat uses
it — nothing is fetched at startup, so the two services need no `depends_on`.

## Dependencies

Only `traefik:v3.7.8`, `postgres:17`, and `prom/prometheus:v2.53.0` are pinned;
`searxng:latest`, `open-webui:main`, `llama.cpp:server-cuda`, `llama.cpp:server-vulkan`,
`mcpjungle:latest-stdio`, `mcp/brave-search:latest`, `mcp/context7:latest`, and
`nousresearch/hermes-agent:latest` re-resolve on every pull, so rebuilds are not
reproducible. Hermes is the sharpest case: a pull can swap the application *and its
on-disk schemas* under `hermes-data/`, with no rollback. The llama.cpp images also
publish `server-rocm` and plain `server` (CPU) if a third profile is ever wanted.
MCPJungle needs the `-stdio` image tag specifically — it ships the `uvx` and
`python3` that stdio servers such as `fetch` are spawned with; plain `latest` cannot
run them.

---

This file loads as live instructions every session — keep it short and true.
A stale rule here is worse than no rule, and it is not a place to park notes
meant for somewhere else.
