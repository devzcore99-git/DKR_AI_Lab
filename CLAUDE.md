# CLAUDE.md - DKR_AI_Lab

Guidance for Claude Code when working in this project.

## Project Overview

Self-hosted AI lab — Open WebUI, llama.cpp, and SearXNG behind one Traefik v3
proxy with Let's Encrypt DNS-01 TLS. `README.md` is the setup guide; keep it in sync.

## Conventions

**Bring-up.** The root `compose.yaml` is only an `include:` list of four per-service
files (`traefik/`, `open-webui/`, `SearXNG/`, `llama.cpp/`); run every command from
the project root (`docker compose up -d`). Running `docker compose -f
<service>/compose.yml` from a service directory starts a *separate* project.

**State — read this before renaming anything.** `compose.yaml` has no top-level
`name:`, so Compose derives the project name from the directory basename
(`DKR_AI_Lab` → `dkr_ai_lab`) and prefixes the named volumes: `dkr_ai_lab_open-webui2`
(chats, users, settings), `dkr_ai_lab_searxng-core-data`, `dkr_ai_lab_searxng-valkey-data`.
Renaming, moving, or copying this directory silently brings Open WebUI up on a fresh
empty volume and orphans all chat history; adding `name:` later does the same unless
the volume is renamed too. Check `docker volume ls` first. `down -v` destroys all three.

**Exposure.** Traefik binds host ports 443 and 10001-10003 and routes five hosts from
`traefik/proxies.yml`: oracle (Open WebUI), llm (llama.cpp), search (SearXNG), plus
lmstudio and mcp — host processes via `host.docker.internal`. Two are unauthenticated:
`open-webui/.env` sets `WEBUI_AUTH=False`, llama.cpp runs with no `--api-key`. Treat as
trusted-LAN-only. SearXNG also publishes `9001:8080` on all interfaces, bypassing TLS.

**Secrets.** All `.env` files, `traefik/letsencrypt/acme.json`, and
`SearXNG/core-config/settings.yml` are gitignored with committed `.example` siblings —
update both in the same commit. Name variables, never values: `CF_DNS_API_TOKEN`,
`OPENAI_API_KEY`, `WEBUI_SECRET_KEY`, `BRAVE_SEARCH_API_KEY`, `server.secret_key`.

**Model weights.** `llama.cpp/compose.yml` bind-mounts a literal Windows path,
`C:\Users\ahill\.lmstudio\models\lmstudio-community:/models`, loading
`gpt-oss-20b-GGUF/gpt-oss-20b-MXFP4.gguf` — unresolvable on this macOS host.

**Broken config, don't copy as a pattern.** `llama.cpp/compose.yml` declares `ai-lab`
without `name: AI-LAB` (the other three set it), so it joins a project-prefixed network
Traefik is not on and `llm.ham51.com` cannot reach it. `open-webui/.env` writes its four
web-search lines as YAML `KEY: "value"`, but `env_file:` parses only `KEY=value`, so web
search never reaches the container (`.env.example` is correct). `searxng-valkey` declares
no `networks:`, so SearXNG cannot reach its cache. `recommendations.md` reviews these.

## Dependencies

Only `traefik:v3.7.8` is pinned; `searxng:latest`, `open-webui:main`, and
`llama.cpp:server-cuda` re-resolve on every pull, so rebuilds are not reproducible.
llama.cpp needs an NVIDIA GPU and the NVIDIA Container Toolkit.

---

This file loads as live instructions every session — keep it short and true.
A stale rule here is worse than no rule, and it is not a place to park notes
meant for somewhere else.
