# DKR AI Lab

A self-hosted AI lab stack, run as a set of Docker Compose services behind a
single Traefik reverse proxy with automatic Let's Encrypt TLS.

| Service | What it does | URL |
| --- | --- | --- |
| **Traefik** | TLS termination + routing for everything below | — |
| **Open WebUI** | Chat front-end for OpenAI-compatible models | `https://oracle.ham51.com` |
| **llama.cpp** | GPU inference server (`gpt-oss-20b`, OpenAI-compatible API) — **currently disabled**, see below | `https://llm.ham51.com` |
| **SearXNG** | Private metasearch engine, usable as Open WebUI's web-search backend | `https://search.ham51.com` |
| **MCPJungle** | MCP gateway + registry — one endpoint fronting several MCP servers | `https://mcp.ham51.com` |
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
compose.yaml                      # top-level: includes every service's compose file
traefik/
  compose.yml                     # Traefik v3 — entrypoints, ACME/DNS-01 config
  proxies.yml                     # file-provider routers + services (the routing table)
  .env                            # CF_DNS_API_TOKEN                    (gitignored)
  letsencrypt/acme.json           # cert + account private keys         (gitignored)
open-webui/
  compose.yml
  .env                            # model backend, auth, search keys    (gitignored)
SearXNG/
  compose.yml                     # searxng + valkey cache
  .env                            #                                     (gitignored)
  core-config/settings.yml        # instance settings, secret_key       (gitignored)
llama.cpp/
  compose.yml                     # CUDA llama.cpp server  (include commented out)
mcpjungle/
  compose.yml                     # gateway + Postgres + MCP servers + registration jobs
  compose-prod.yml                # standalone enterprise-mode variant (not included)
  .env                            # BRAVE_API_KEY                       (gitignored)
  mcp-servers/*.json              # stdio server definitions to register
  tool-groups/*.json              # curated tool subsets, one file per group
```

Anything marked *gitignored* has a committed `.example` sibling.

---

## Requirements

- Docker Engine / Docker Desktop with Compose v2
- An NVIDIA GPU + NVIDIA Container Toolkit — only for `llama.cpp`, which is
  currently disabled, so not needed to run the rest
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

**3. Point DNS at the host**

Create `A`/`AAAA` records for `oracle`, `llm`, `search`, `lmstudio`, and `mcp`
in your zone. They must resolve for Traefik's routers to match, but DNS-01 means
they don't need to be publicly reachable for the certificate itself to issue.

**4. (Optional) Re-enable llama.cpp**

Skip this unless you want local GPU inference — the stack runs fine without it,
with Open WebUI pointed at LM Studio on the host instead.

`llama.cpp`'s line in the root `compose.yaml` is commented out because the
committed config cannot start: the volume is a literal Windows path, which Docker
rejects with `invalid volume specification`.

```yaml
volumes:
  - C:\Users\ahill\.lmstudio\models\lmstudio-community:/models
```

To bring it back, uncomment the include, change that to wherever your models
actually live, make sure the `--model` argument below it names a file inside that
directory, and add `name: AI-LAB` to the file's `networks:` block — without it the
container joins a project-prefixed network Traefik is not on. You also need a
working NVIDIA driver and the Container Toolkit.

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

# Follow inference logs (only if llama.cpp has been re-enabled)
docker compose logs -f llama-gpt-oss

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
- **`llama.cpp` is commented out of the root `compose.yaml`** and none of its
  problems are fixed — unrunnable volume path, missing driver, missing weights,
  and a `networks:` block with no `name: AI-LAB`. Setup step 4 covers what to do
  before re-enabling it. `traefik/proxies.yml` still routes `llm.ham51.com` at it,
  so that hostname 502s in the meantime.
- **SearXNG publishes `9001:8080` directly** in addition to being proxied, which
  bypasses TLS. Drop the `ports:` block if you only want access via Traefik.
- **MCPJungle runs in `development` mode**, which means no authentication, and it
  publishes `8080` on the host on top of being proxied at `mcp.ham51.com`. Anyone
  who can reach either can call every registered tool. Set `SERVER_MODE=enterprise`
  in `mcpjungle/.env` before exposing it beyond a trusted network.
- **The gateway mounts `mcpjungle/` at `/host:ro`** so filesystem MCP servers have
  something to read. Widen it to `${HOME}:/host/home:ro` only if you mean to.

---

## Secrets

Never commit `.env` files, `traefik/letsencrypt/acme.json`, or
`SearXNG/core-config/settings.yml` — `.gitignore` covers all three. When
changing configuration, update the matching `.example` file in the same commit
so the documentation stays honest.
