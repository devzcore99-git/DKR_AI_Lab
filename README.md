# DKR AI Lab

A self-hosted AI lab stack, run as a set of Docker Compose services behind a
single Traefik reverse proxy with automatic Let's Encrypt TLS.

| Service | What it does | URL |
| --- | --- | --- |
| **Traefik** | TLS termination + routing for everything below | — |
| **Open WebUI** | Chat front-end for OpenAI-compatible models | `https://oracle.ham51.com` |
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
runit.sh                          # decrypt every enc.env, then run docker compose
.sops.yaml                        # which values get encrypted, and to which age key
traefik/
  compose.yml                     # Traefik v3 — entrypoints, ACME/DNS-01 config
  proxies.yml                     # file-provider routers + services (the routing table)
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
  letsencrypt/acme.json           # cert + account private keys         (gitignored)
open-webui/
  compose.yml                     # + TOOL_SERVER_CONNECTIONS: the MCPJungle tool groups
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
SearXNG/
  compose.yml                     # searxng + valkey cache
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
  core-config/settings.yml        # instance settings, secret_key       (gitignored)
mcpjungle/
  compose.yml                     # gateway + Postgres + MCP servers + registration jobs
  compose-prod.yml                # standalone enterprise-mode variant (not included)
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
  mcp-servers/*.json              # stdio server definitions to register
  tool-groups/*.json              # curated tool subsets, one file per group
```

Anything marked *gitignored* has a committed `.example` sibling. There are no
`.env` files anywhere, not even at the root: `./runit.sh` decrypts each `enc.env`
straight into its own environment and never writes plaintext to disk.

---

## Requirements

- Docker Engine / Docker Desktop with Compose v2
- A domain in Cloudflare — TLS certs are issued via the ACME **DNS-01** challenge,
  so no port 80 exposure is needed, and wildcard/internal-only hosts work fine
- Port `443` free on the host — it is the only one the stack binds

---

## Setup

**1. Get the secrets readable**

Each service's configuration lives in a committed, age-encrypted
`<service>/enc.env`. There is nothing to copy and no `.env` to create:
`./runit.sh` decrypts all four into its **own environment** and execs
`docker compose` there, so plaintext never touches the disk. Check the key works:

```sh
./runit.sh --names          # lists the variables it would export, starts nothing
```

That needs `sops` and the project's age identity at `~/.config/sops/age/keys.txt`
(or `SOPS_AGE_KEY_FILE`). **Without the key you cannot read them at all** — there
is no second copy.

> **`./runit.sh` is the only way in.** A bare `docker compose ps`, `down`, or
> `logs` now fails at parse time, because the variables the compose files require
> are no longer sitting on disk for Compose to find. Use `./runit.sh ps`,
> `./runit.sh down`, `./runit.sh logs -f traefik` — every argument is passed
> straight through.

Starting from scratch on a new host, write each `<service>/enc.env` using the
committed `<service>/enc.env.example` as the list of variables — `sops` creates
and encrypts it in one step — then seed the one file that is not an env file at
all:

```sh
cp SearXNG/core-config/settings.yml.example SearXNG/core-config/settings.yml
```

**2. Fill in the secrets**

| File | Variable | Where it comes from |
| --- | --- | --- |
| `traefik/enc.env` | `CF_DNS_API_TOKEN` | Cloudflare API token with *Zone → DNS → Edit* and *Zone → Zone → Read* on your zone |
| `open-webui/enc.env` | `OPENWEBUI_OPENAI_API_KEY` | The key for whichever OpenAI-compatible backend you point at — `llm-coder-mid.ham51.com` by default (any value if the backend doesn't check it). Prefixed so it cannot collide in `runit.sh`'s flat environment; `compose.yml` maps it back to `OPENAI_API_KEY` in the container |
| `open-webui/enc.env` | `WEBUI_SECRET_KEY` | `openssl rand -base64 32` |
| `open-webui/enc.env` | `OPENWEBUI_BRAVE_SEARCH_API_KEY` | https://api-dashboard.search.brave.com/ (omit if using SearXNG) |
| `SearXNG/core-config/settings.yml` | `server.secret_key` | `openssl rand -hex 16` |
| `mcpjungle/enc.env` | `BRAVE_API_KEY` | https://api-dashboard.search.brave.com/ — a second copy of the same Brave key under a different name (Open WebUI holds the other); one key, two files to update when it rotates |

**3. Point DNS at the host**

Create `A`/`AAAA` records for `oracle`, `search`, `lmstudio` and `mcp` in your
zone. They must resolve for Traefik's routers to match, but DNS-01 means they
don't need to be publicly reachable for the certificate itself to issue.

**4. Bring it up**

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
| `playwright` | container on `MCPJUNGLE` | Microsoft's image; headless Chromium only |

Registration is not stored in the compose file's head — it is applied by one-shot
`mcpjungle-register-*` jobs that run on every `up` and exit. They use `--force`, so
they converge rather than fail on "already exists", and the registry survives a
wiped `mcpjungle-db-data` volume because bringing the stack back up re-applies them.

A **tool group** is a curated subset of the gateway's tools with its own endpoint,
`/v0/groups/<name>/mcp` — point a client at one and it sees a handful of tools
instead of the whole registry. Groups live in `mcpjungle/tool-groups/*.json`, one file per group,
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

**Playwright needs `--allowed-hosts`.** It drives a real headless Chromium, so
unlike the other servers it checks the `Host` header for DNS-rebinding protection —
and that check defaults to *the host it is bound to*, which means `localhost:9003`
even though `--host` is `0.0.0.0`. Without the flag the container starts, the
healthcheck passes, and every request from the gateway comes back
`403 Access is only allowed at localhost:9003`. The list in `mcpjungle/compose.yml`
must match the URL the registration job uses (`http://playwright:9003/mcp`); change
one and you must change the other. Chromium also gets `shm_size: 1gb` — Docker's
default 64MB is not enough for it to render real pages.

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

- ~~**`open-webui/enc.env` mixes two syntaxes.**~~ Fixed. The four web-search lines
  (`ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`, `BRAVE_SEARCH_API_KEY`,
  `WEB_SEARCH_RESULT_COUNT`) once used the YAML-style `KEY: "value"` form, which
  Compose `env_file:` does not parse, so web search never reached the container.
  They are `KEY=value` now and `docker compose config` shows them resolving.
- **`WEBUI_AUTH=False`** disables Open WebUI's login entirely while Traefik
  publishes it on a public hostname. Set it to `True` before exposing this
  anywhere untrusted.
- **MCPJungle runs in `development` mode**, which means no authentication. It is
  no longer published on the host, but `https://mcp.ham51.com` still reaches it,
  and anyone who gets there can call every registered tool. TLS is not a login.
  Set `SERVER_MODE=enterprise` in `mcpjungle/enc.env` before exposing it beyond a
  trusted network.
- **The gateway mounts `mcpjungle/` at `/host:ro`** so filesystem MCP servers have
  something to read. Widen it to `${HOME}:/host/home:ro` only if you mean to.

---

## Secrets

Never commit a `.env` file, `traefik/letsencrypt/acme.json`, or
`SearXNG/core-config/settings.yml` — `.gitignore` covers all three. When changing
configuration, update the matching `.example` file in the same commit so the
documentation stays honest.

What *is* committed is the encrypted counterpart, `<service>/enc.env`, one per
service. `.sops.yaml` encrypts only values whose **name** matches
`KEY|TOKEN|SECRET|PASSWORD|HASH|USERNAME|CREDENTIAL`, so hostnames, ports, model
paths and comments stay readable and the file still works as documentation.

Two consequences worth keeping in mind:

- **Comments are never encrypted.** A secret parked in a `#` line ships to the
  repo in the clear. Put values in variables, not in commentary.
- **A new variable is only protected if its name matches that regex.** Adding
  `FOO_APIKEY` (no underscore before KEY still matches; `FOO_CREDS` does not)
  leaves it plaintext. Check with `grep FOO <service>/enc.env` after encrypting.

Change a secret with `sops`, which never writes plaintext to disk:

```sh
sops open-webui/enc.env   # decrypts into $EDITOR, re-encrypts on save
./runit.sh                # decrypt into the environment and restart
```

The age identity at `~/.config/sops/age/keys.txt` is the only thing that can read
any of it, and this repo contains no backup of it. Back it up somewhere outside
this machine, or the encrypted files become unreadable the day the disk dies.
