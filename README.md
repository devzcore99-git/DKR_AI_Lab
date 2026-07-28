# DKR AI Lab

A self-hosted AI lab stack, run as a set of Docker Compose services behind a
single Traefik reverse proxy with automatic Let's Encrypt TLS.

| Service | What it does | URL |
| --- | --- | --- |
| **Traefik** | TLS termination + routing for everything below | — |
| **Open WebUI** | Chat front-end for OpenAI-compatible models | `https://oracle.ham51.com` |
| **llama.cpp** | GPU inference server (`gpt-oss-20b`, OpenAI-compatible API) | `https://llm.ham51.com` |
| **SearXNG** | Private metasearch engine, usable as Open WebUI's web-search backend | `https://search.ham51.com` |
| **LM Studio** | Runs on the *host*, not in Docker — proxied through Traefik | `https://lmstudio.ham51.com` |
| **MCP Gateway** | Runs on the *host*, not in Docker — proxied through Traefik | `https://mcp.ham51.com` |

All containers share an external-style Docker network named `AI-LAB`, so they
address each other by service name (e.g. `http://searxng:8080`). Host-side
services are reached via `host.docker.internal`.

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
  compose.yml                     # CUDA llama.cpp server
```

Anything marked *gitignored* has a committed `.example` sibling.

---

## Requirements

- Docker Engine / Docker Desktop with Compose v2
- An NVIDIA GPU + NVIDIA Container Toolkit (for `llama.cpp`)
- A domain in Cloudflare — TLS certs are issued via the ACME **DNS-01** challenge,
  so no port 80 exposure is needed, and wildcard/internal-only hosts work fine
- Ports free on the host: `443`, `9001`, `10001`, `10002`, `10003`

---

## Setup

**1. Create the env files from the examples**

```sh
cp traefik/.env.example      traefik/.env
cp open-webui/.env.example   open-webui/.env
cp SearXNG/.env.example      SearXNG/.env
cp SearXNG/core-config/settings.yml.example SearXNG/core-config/settings.yml
```

**2. Fill in the secrets**

| File | Variable | Where it comes from |
| --- | --- | --- |
| `traefik/.env` | `CF_DNS_API_TOKEN` | Cloudflare API token with *Zone → DNS → Edit* and *Zone → Zone → Read* on your zone |
| `open-webui/.env` | `OPENAI_API_KEY` | Your LM Studio / llama.cpp key (any value if the backend doesn't check it) |
| `open-webui/.env` | `WEBUI_SECRET_KEY` | `openssl rand -base64 32` |
| `open-webui/.env` | `BRAVE_SEARCH_API_KEY` | https://api-dashboard.search.brave.com/ (omit if using SearXNG) |
| `SearXNG/core-config/settings.yml` | `server.secret_key` | `openssl rand -hex 16` |

**3. Point DNS at the host**

Create `A`/`AAAA` records for `oracle`, `llm`, `search`, `lmstudio`, and `mcp`
in your zone. They must resolve for Traefik's routers to match, but DNS-01 means
they don't need to be publicly reachable for the certificate itself to issue.

**4. Adjust the model path**

`llama.cpp/compose.yml` mounts a host directory of GGUF weights at `/models`.
The committed value is a Windows path:

```yaml
volumes:
  - C:\Users\ahill\.lmstudio\models\lmstudio-community:/models
```

Change it to wherever your models live, and make sure the `--model` argument
below it matches a file inside that directory.

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

# Follow inference logs
docker compose logs -f llama-gpt-oss

# Tear down (volumes — and therefore chat history — are preserved)
docker compose down

# Tear down INCLUDING volumes
docker compose down -v
```

Persistent state lives in named volumes: `open-webui2` (chats, users, settings),
`searxng-core-data`, `searxng-valkey-data`.

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
`http://host.docker.internal:<port>` as the server URL — that's how LM Studio
and the MCP Gateway are wired.

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
- **`llama.cpp/compose.yml` declares its network without `name: AI-LAB`**, unlike
  the other three files. That yields a project-prefixed network instead of the
  shared one; add the `name:` key to match.
- **SearXNG publishes `9001:8080` directly** in addition to being proxied, which
  bypasses TLS. Drop the `ports:` block if you only want access via Traefik.

---

## Secrets

Never commit `.env` files, `traefik/letsencrypt/acme.json`, or
`SearXNG/core-config/settings.yml` — `.gitignore` covers all three. When
changing configuration, update the matching `.example` file in the same commit
so the documentation stays honest.
