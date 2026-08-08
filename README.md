# DKR AI Lab

A self-hosted AI lab stack, run as a set of Docker Compose services behind a
single Traefik reverse proxy with automatic Let's Encrypt TLS.

| Service | What it does | URL |
| --- | --- | --- |
| **Traefik** | TLS termination + routing for everything below | — |
| **Open WebUI** | Chat front-end for OpenAI-compatible models | `https://oracle.ham51.com` |
| **llama.cpp** | GPU inference server, OpenAI-compatible — CUDA or Vulkan, picked per host | `https://llm.ham51.com` |
| **SearXNG** | Private metasearch engine, usable as Open WebUI's web-search backend | `https://search.ham51.com` |
| **MCPJungle** | MCP gateway + registry — one endpoint fronting several MCP servers | `https://mcp.ham51.com` |
| **Hermes** | Nous Research agent — web dashboard plus a messaging/cron gateway | `https://hermes.ham51.com` |
| **LM Studio** | Runs on the *host*, not in Docker — proxied through Traefik | `https://lmstudio.ham51.com` |

All containers share an external-style Docker network named `AI-LAB`, so they
address each other by service name (e.g. `http://searxng:8080`). Host-side
services are reached via `host.docker.internal`.

MCPJungle's own backing services (Postgres and the individual MCP servers) sit on
a second, private network named `MCPJUNGLE`. Only the gateway itself joins both,
which is what lets Traefik and Open WebUI reach it while the unauthenticated MCP
servers behind it stay unreachable from the rest of the lab.

---

## Layout

```
.env                              # COMPOSE_PROFILES only                (gitignored)
compose.yaml                      # top-level: includes every service's compose file
traefik/
  compose.yml                     # Traefik v3 — entrypoints, ACME/DNS-01 config
  proxies.yml                     # file-provider routers + services (the routing table)
  .env                            # CF_DNS_API_TOKEN                    (gitignored)
  letsencrypt/acme.json           # cert + account private keys         (gitignored)
open-webui/
  compose.yml                     # + TOOL_SERVER_CONNECTIONS: the MCPJungle tool groups
  .env                            # model backend, auth, search keys    (gitignored)
SearXNG/
  compose.yml                     # searxng + valkey cache
  .env                            #                                     (gitignored)
  core-config/settings.yml        # instance settings, secret_key       (gitignored)
llama.cpp/
  compose.yml                     # llama-cuda + llama-vulkan, one per profile
  detect-gpu.sh                   # picks a profile, writes it to the root .env
  .env                            # model dir + model file               (gitignored)
mcpjungle/
  compose.yml                     # gateway + Postgres + MCP servers + registration jobs
  compose-prod.yml                # standalone enterprise-mode variant (not included)
  .env                            # BRAVE_API_KEY                       (gitignored)
  mcp-servers/*.json              # stdio server definitions to register
  tool-groups/*.json              # curated tool subsets, one file per group
hermes/
  compose.yml                     # nousresearch/hermes-agent — gateway + web dashboard
  .env                            # dashboard login, agent keys         (gitignored)
  hermes-data/                    # ALL agent state, bind-mounted       (gitignored)
```

Anything marked *gitignored* has a committed `.example` sibling.

---

## Requirements

- Docker Engine / Docker Desktop with Compose v2
- For `llama.cpp` only: a GPU Docker can reach — NVIDIA + Container Toolkit, or
  any `/dev/dri` render node for the Vulkan backend. Neither is needed to run the
  rest of the stack. **Docker Desktop cannot pass a GPU through**; use the
  `default` context
- A domain in Cloudflare — TLS certs are issued via the ACME **DNS-01** challenge,
  so no port 80 exposure is needed, and wildcard/internal-only hosts work fine
- Ports free on the host: `443`, `8080`, `9001`, `10001`, `10002`, `10003`

---

## Setup

**1. Create the env files from the examples**

```sh
cp traefik/.env.example      traefik/.env
cp open-webui/.env.example   open-webui/.env
cp SearXNG/.env.example      SearXNG/.env
cp SearXNG/core-config/settings.yml.example SearXNG/core-config/settings.yml
cp mcpjungle/.env.example    mcpjungle/.env
cp llama.cpp/.env.example    llama.cpp/.env
cp hermes/.env.example       hermes/.env
cp .env.example              .env
```

**2. Fill in the secrets**

| File | Variable | Where it comes from |
| --- | --- | --- |
| `traefik/.env` | `CF_DNS_API_TOKEN` | Cloudflare API token with *Zone → DNS → Edit* and *Zone → Zone → Read* on your zone |
| `open-webui/.env` | `OPENAI_API_KEY` | Your LM Studio / llama.cpp key (any value if the backend doesn't check it) |
| `open-webui/.env` | `WEBUI_SECRET_KEY` | `openssl rand -base64 32` |
| `open-webui/.env` | `BRAVE_SEARCH_API_KEY` | https://api-dashboard.search.brave.com/ (omit if using SearXNG) |
| `SearXNG/core-config/settings.yml` | `server.secret_key` | `openssl rand -hex 16` |
| `mcpjungle/.env` | `BRAVE_API_KEY` | https://api-dashboard.search.brave.com/ — separate from Open WebUI's copy; the gateway's Brave MCP server needs its own |
| `hermes/.env` | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Any login name you want |
| `hermes/.env` | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | The scrypt hash below — **not** the plaintext |
| `hermes/.env` | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -base64 48` |

Hermes is the only service here that refuses to serve without credentials, so
its three are not optional. Generate the password hash with the image's own
helper — the password is not echoed and never enters shell history:

```sh
docker run --rm -it --entrypoint /opt/hermes/.venv/bin/python \
  nousresearch/hermes-agent:latest -c \
  'import getpass; from plugins.dashboard_auth.basic import hash_password; print(hash_password(getpass.getpass("password: ")))'
```

Leave them blank and nothing looks broken: the container starts, the gateway
runs, and `hermes.ham51.com` simply never answers, because the dashboard's auth
gate fails closed rather than serving unauthenticated.

**3. Point DNS at the host**

Create `A`/`AAAA` records for `oracle`, `llm`, `search`, `lmstudio`, `mcp`, and
`hermes` in your zone. They must resolve for Traefik's routers to match, but
DNS-01 means they don't need to be publicly reachable for the certificate itself
to issue.

**4. Pick a llama.cpp GPU backend**

Skip this if you don't want local inference in Docker — leave `COMPOSE_PROFILES`
unset and llama.cpp simply won't start; nothing else is affected.

```sh
./llama.cpp/detect-gpu.sh          # writes COMPOSE_PROFILES to the root .env
./llama.cpp/detect-gpu.sh --dry-run  # just report, change nothing
```

`llama.cpp/compose.yml` defines the same server twice, once per backend, each
behind a profile:

| Profile | Service | Image | Needs |
| --- | --- | --- | --- |
| `cuda` | `llama-cuda` | `server-cuda` | NVIDIA Container Toolkit (an `nvidia` runtime in `docker info`) |
| `vulkan` | `llama-vulkan` | `server-vulkan` | a `/dev/dri` render node — AMD or Intel, no toolkit |

They share everything else through a YAML anchor, and both take the network alias
`llama-gpt-oss`, so `traefik/proxies.yml` points at `http://llama-gpt-oss:9010`
either way and needs no change when the backend does.

Then set the model in `llama.cpp/.env`:

```sh
LLAMA_MODELS_DIR=/home/ahill/.lmstudio/models/lmstudio-community
LLAMA_MODEL=gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf
```

`LLAMA_MODEL` is relative to `LLAMA_MODELS_DIR`, which is mounted read-only at
`/models`. Both are required — Compose fails with a named error rather than
starting a server that can't find its weights.

> **Docker Desktop cannot do this.** Its containers run inside a linuxkit VM that
> has no `/dev/dri`, so the container fails with `error gathering device
> information while adding custom device "/dev/dri"` even though the host has one.
> Check with `docker context ls`; GPU work needs the `default` context (the native
> engine on the host kernel), not `desktop-linux`.

**5. Bring it up**

```sh
docker compose up -d
docker compose ps
docker compose logs -f traefik
```

---

## Common tasks

```sh
# Restart one service
docker compose restart open-webui

# Rebuild the routing table after editing traefik/proxies.yml
# (Traefik's file provider hot-reloads, but a restart is the sure thing)
docker compose restart traefik

# Follow inference logs (llama-cuda or llama-vulkan, whichever profile is active)
docker compose logs -f llama-vulkan

# Tear down (volumes — and therefore chat history — are preserved)
docker compose down

# Tear down INCLUDING volumes
docker compose down -v
```

Persistent state lives in named volumes: `open-webui2` (chats, users, settings),
`searxng-core-data`, `searxng-valkey-data`, `mcpjungle-db-data` (the MCP registry),
`mcpjungle-uv-cache`.

---

## The MCP gateway

MCPJungle registers several MCP servers and re-serves them as one endpoint, so a
client points at the gateway instead of wiring up each server itself.

| Registered server | Runs as | Notes |
| --- | --- | --- |
| `brave-search` | container on `MCPJUNGLE` | needs `BRAVE_API_KEY` |
| `context7` | container on `MCPJUNGLE` | library docs; anonymous, rate-limited |
| `fetch` | stdio subprocess inside the gateway | URL → markdown |
| `MicrosoftLearnMCP` | remote, `learn.microsoft.com` | nothing runs locally |

Registration is not stored in the compose file's head — it is applied by one-shot
`mcpjungle-register-*` jobs that run on every `up` and exit. They use `--force`, so
they converge rather than fail on "already exists", and the registry survives a
wiped `mcpjungle-db-data` volume because bringing the stack back up re-applies them.

A **tool group** is a curated subset of the gateway's tools with its own endpoint,
`/v0/groups/<name>/mcp` — point a client at one and it sees five tools instead of
all fourteen. Groups live in `mcpjungle/tool-groups/*.json`, one file per group,
and `mcpjungle-create-groups` applies them after every registration job finishes.
Those files are the source of truth: the job fully overwrites the stored config.

The CLI ships inside the image at `/mcpjungle`, so no host install is needed:

```sh
# What is registered right now
docker compose exec mcpjungle /mcpjungle list servers

# Re-apply the JSON files after editing them (each job is idempotent)
docker compose up -d mcpjungle-register-brave mcpjungle-create-groups

# Why a registration failed
docker compose logs mcpjungle-register-fetch mcpjungle-create-groups
```

The group files were generated by `mcpjungle export`, and editing a group through
the API rather than the file is fine — just export it back over the JSON, or the
next `up` will overwrite your change with the file's contents.

Adding a server means adding a `mcpjungle-register-<name>` job to
`mcpjungle/compose.yml` **and** listing it in `mcpjungle-create-groups`'
`depends_on` — groups are validated against the live registry, so a group naming a
tool that has not been registered yet fails the whole job.

### Open WebUI sees the groups automatically

The three groups are pre-wired as MCP tool servers by `TOOL_SERVER_CONNECTIONS` in
`open-webui/compose.yml`, so a fresh `open-webui2` volume comes up with them already
listed under *Admin Settings → External Tools* — no clicking through the form. Each
entry points at a group endpoint on the `AI-LAB` network
(`http://mcpjungle:8080/v0/groups/<name>/mcp`), needs `"type": "mcp"` for the native
streamable-HTTP client, and needs `"config": {"enable": true}` to show up at all.
Pick one per chat from the **+** menu; a model only sees the tools of the groups
selected for that conversation.

Two things to know before editing it:

- **It seeds, it does not override.** Open WebUI reads the variable only while the
  `tool_server.connections` row is missing from `webui.db`. The first save in *Admin
  Settings → External Tools* writes that row, and after that the UI wins and changes
  to the compose file do nothing. The comment above the variable has the SQL to drop
  the row and hand authority back to the file.
- **Nothing is fetched at boot.** Open WebUI connects to a group only when a chat
  actually uses it, so the gateway being down delays nothing at startup — and no
  `depends_on` is needed between the two services.

---

## Hermes

`nousresearch/hermes-agent` is one image running **two independent things**, and
most confusion about it comes from conflating them.

- **The gateway** — `command: ["gateway", "run"]`, the container's main process.
  Messaging platforms (Slack, Telegram, …) plus the cron scheduler. It stays up
  with nothing configured, logging `No messaging platforms enabled`, so a fresh
  install does not crashloop while you set the rest up.
- **The dashboard** — a *separate s6-supervised service* inside the same
  container, serving the web UI on 9119. This is what `hermes.ham51.com` fronts.

The dashboard does not run unless `HERMES_DASHBOARD=1` (set in
`hermes/compose.yml`). Without it the run script exits 0 and its finish script
returns 125, which s6 reads as permanent failure — the slot reports down and
nothing is logged as an error.

### Why it demands a password

The dashboard binds `0.0.0.0` inside the container, because that is what lets
Traefik reach it across AI-LAB. Any non-loopback bind engages the auth gate, and
`start_server` fails closed unless an auth provider is registered.
`HERMES_DASHBOARD_INSECURE` was that escape hatch and has been a **no-op since
the June 2026 hardening**; per the image's own comment, unauthenticated public
dashboards were the entry point for an MCP-config persistence campaign. There is
no bypass. The bundled username/password provider needs no external IDP; Nous
Portal OAuth (`hermes dashboard register`) is the alternative.

This makes Hermes the only authenticated service in the lab. It is also the one
that most needs to be: the agent has local shell execution inside its container
(`terminal.backend: local`). It publishes no host port for the same reason —
Traefik is the only way in, unlike SearXNG's `9001` and MCPJungle's `8080`.

### Pointing it at the rest of the lab

Hermes is on AI-LAB, so it addresses the others by name. Uncomment in
`hermes/.env`:

```sh
OPENAI_BASE_URL=http://llama-gpt-oss:9010/v1   # local inference
SEARXNG_URL=http://searxng:8080                # private search
```

`llama-gpt-oss` is a network alias carried by both llama.cpp profiles, so this
works whichever backend is active — and resolves to nothing when
`COMPOSE_PROFILES` names neither.

### State

Everything lives in `hermes/hermes-data/`, a **bind mount, not a named volume**:
`.env`, `auth.json`, `config.yaml`, `SOUL.md`, `kanban.db`, `state.db`, logs and
session history. Two consequences — `docker compose down -v` does *not* clear it,
and there is no backup mechanism, so it is the only copy. The container writes
that directory itself, including `config.yaml.bak*` snapshots; edit config there
and `docker compose restart hermes`, but don't hand-edit generated files while it
is running.

---

## Adding a service to the proxy

1. Add the container to its own `<service>/compose.yml` on the `ai-lab` network,
   and include that file from the root `compose.yaml`.
2. Add a router + service pair to `traefik/proxies.yml`:

   ```yaml
   http:
     routers:
       myservice:
         entryPoints: [port443]
         rule: "Host(`myservice.ham51.com`)"
         tls:
           certResolver: letsencrypt
         service: myservice-service
     services:
       myservice-service:
         loadBalancer:
           servers:
             - url: "http://myservice:8080"
   ```
3. Create the DNS record, then `docker compose up -d`.

For something running on the host rather than in Docker, use
`http://host.docker.internal:<port>` as the server URL — that's how LM Studio is
wired.

---

## Known rough edges

- **`open-webui/.env` mixes two syntaxes.** Compose `env_file:` only understands
  `KEY=value`; the YAML-style `KEY: "value"` lines (`ENABLE_WEB_SEARCH`,
  `WEB_SEARCH_ENGINE`, `BRAVE_SEARCH_API_KEY`, `WEB_SEARCH_RESULT_COUNT`) do not
  reach the container, so web search is effectively off. The `.env.example` uses
  the correct `KEY=value` form throughout.
- **`WEBUI_AUTH=False`** disables Open WebUI's login entirely while Traefik
  publishes it on a public hostname. Set it to `True` before exposing this
  anywhere untrusted.
- **llama.cpp does nothing until `COMPOSE_PROFILES` is set**, and it must be set in
  the *root* `.env` — a copy in `llama.cpp/.env` is read for interpolation but never
  activates a profile, leaving both services silently absent. `llm.ham51.com` 502s
  until one is active.
- **SearXNG publishes `9001:8080` directly** in addition to being proxied, which
  bypasses TLS. Drop the `ports:` block if you only want access via Traefik.
- **MCPJungle runs in `development` mode**, which means no authentication, and it
  publishes `8080` on the host on top of being proxied at `mcp.ham51.com`. Anyone
  who can reach either can call every registered tool. Set `SERVER_MODE=enterprise`
  in `mcpjungle/.env` before exposing it beyond a trusted network.
- **The gateway mounts `mcpjungle/` at `/host:ro`** so filesystem MCP servers have
  something to read. Widen it to `${HOME}:/host/home:ro` only if you mean to.
- **Hermes fails silently when its credentials are blank.** The container comes
  up, `docker compose ps` looks healthy, and `hermes.ham51.com` 502s because the
  dashboard's auth gate refused to bind. `docker compose logs hermes` is where it
  says so — look for `HERMES_DASHBOARD_READY`, which is absent when the gate
  fails closed.
- **`hermes-data/` is a bind mount and survives `down -v`.** Every other
  service's state is a named volume that `down -v` destroys; Hermes is the
  reverse, and deleting the directory by hand is unrecoverable.

---

## Secrets

Never commit `.env` files, `traefik/letsencrypt/acme.json`,
`SearXNG/core-config/settings.yml`, or `hermes/hermes-data/` — `.gitignore`
covers all four. That last one is a whole directory rather than a single file:
the agent writes its own API keys, OAuth tokens and session history into it. When
changing configuration, update the matching `.example` file in the same commit
so the documentation stays honest.
