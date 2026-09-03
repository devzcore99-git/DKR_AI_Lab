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
llama.cpp/
  compose.yml                     # llama-cuda + llama-vulkan, one per profile
  detect-gpu.sh                   # picks a profile, writes it to the root .env
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only (holds no secret)
mcpjungle/
  compose.yml                     # gateway + Postgres + MCP servers + registration jobs
  compose-prod.yml                # standalone enterprise-mode variant (not included)
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
  mcp-servers/*.json              # stdio server definitions to register
  tool-groups/*.json              # curated tool subsets, one file per group
hermes/
  compose.yml                     # nousresearch/hermes-agent — gateway + web dashboard
  enc.env                         # secrets, age-encrypted, committed
  enc.env.example                 # ^ its plaintext shape, documentation only
  hermes-data/                    # ALL agent state, bind-mounted       (gitignored)
```

Anything marked *gitignored* has a committed `.example` sibling. There are no
per-service `.env` files: `./runit.sh` decrypts each `enc.env` straight into its
own environment and never writes plaintext to disk. The root `.env` is the one
exception — it holds only `COMPOSE_PROFILES` and is written by
`llama.cpp/detect-gpu.sh`.

---

## Requirements

- Docker Engine / Docker Desktop with Compose v2
- For `llama.cpp` only: a GPU Docker can reach — NVIDIA + Container Toolkit, or
  any `/dev/dri` render node for the Vulkan backend. Neither is needed to run the
  rest of the stack. **Docker Desktop cannot pass a GPU through**; use the
  `default` context
- A domain in Cloudflare — TLS certs are issued via the ACME **DNS-01** challenge,
  so no port 80 exposure is needed, and wildcard/internal-only hosts work fine
- Port `443` free on the host — it is the only one the stack binds

---

## Setup

**1. Get the secrets readable**

Each service's configuration lives in a committed, age-encrypted
`<service>/enc.env`. There is nothing to copy and no `.env` to create:
`./runit.sh` decrypts all six into its **own environment** and execs
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
> `./runit.sh down`, `./runit.sh logs -f hermes` — every argument is passed
> straight through.

Starting from scratch on a new host, write each `<service>/enc.env` using the
committed `<service>/enc.env.example` as the list of variables — `sops` creates
and encrypts it in one step — then seed the two files that are not env files at
all:

```sh
cp SearXNG/core-config/settings.yml.example SearXNG/core-config/settings.yml
cp .env.example              .env          # COMPOSE_PROFILES only

mkdir -p hermes/hermes-data
cp hermes/config.yaml.example hermes/hermes-data/config.yaml
```

That last pair is not optional in the way it looks. Hermes chooses its model
from `hermes-data/config.yaml`; skip it and the container starts an agent
pointed at the image's built-in default rather than at anything in this lab.

The root `.env` is deliberately *not* encrypted: it holds only `COMPOSE_PROFILES`,
which is host-specific and written by `llama.cpp/detect-gpu.sh`.

**2. Fill in the secrets**

| File | Variable | Where it comes from |
| --- | --- | --- |
| `traefik/enc.env` | `CF_DNS_API_TOKEN` | Cloudflare API token with *Zone → DNS → Edit* and *Zone → Zone → Read* on your zone |
| `open-webui/enc.env` | `OPENWEBUI_OPENAI_API_KEY` | Your LM Studio / llama.cpp key (any value if the backend doesn't check it). Namespaced because `hermes/enc.env` has its own; `compose.yml` maps it back to `OPENAI_API_KEY` in the container |
| `open-webui/enc.env` | `WEBUI_SECRET_KEY` | `openssl rand -base64 32` |
| `open-webui/enc.env` | `OPENWEBUI_BRAVE_SEARCH_API_KEY` | https://api-dashboard.search.brave.com/ (omit if using SearXNG) |
| `SearXNG/core-config/settings.yml` | `server.secret_key` | `openssl rand -hex 16` |
| `mcpjungle/enc.env` | `BRAVE_API_KEY` | https://api-dashboard.search.brave.com/ — a third copy of the same Brave key under a different name (Open WebUI and Hermes hold the other two); one key, three files to update when it rotates |
| `hermes/enc.env` | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Any login name you want |
| `hermes/enc.env` | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | The scrypt hash below — **not** the plaintext |
| `hermes/enc.env` | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -base64 48` |
| `hermes/enc.env` | `HERMES_CUSTOM_LLM_CODER_MID_HAM51_COM_API_KEY` | The key for `llm-coder-mid.ham51.com`; the variable name is what `config.yaml`'s `key_env:` points at, so rename both together |

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

Then set the model in `llama.cpp/enc.env` (`sops llama.cpp/enc.env`):

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
(`terminal.backend: local`). Like every other service it publishes no host port,
so Traefik is the only way in.

### Which model it uses

**`hermes-data/config.yaml`, not `hermes/.env`.** This is the one thing about
Hermes that is easy to get wrong, because setting the environment variables
looks like it worked: the container starts, the dashboard answers, and the agent
replies — from the image's built-in default model. `OPENAI_BASE_URL` is read by
individual plugins; `model.default` in `config.yaml` is what the agent itself
uses for every turn.

`hermes/config.yaml.example` is the seed, and the only committed record of the
intended configuration — `hermes-data/` is gitignored. The lab's default is
llama.cpp on the `DKR_AI_Lab2` host:

```yaml
model:
  default: coder-mid
  provider: custom
  base_url: https://llm-coder-mid.ham51.com/v1
  api_key: ${HERMES_CUSTOM_LLM_CODER_MID_HAM51_COM_API_KEY}
```

`https`, not `http` — that host's Traefik binds 443 alone, exactly like this
one, so the plaintext port is closed rather than redirecting. Confirm the model
id against the server rather than assuming it, since llama.cpp reports whatever
alias it was started with:

```sh
curl -H "Authorization: Bearer $KEY" https://llm-coder-mid.ham51.com/v1/models
```

Verify end to end after any change — this runs one real turn through whatever
`config.yaml` currently names:

```sh
docker exec hermes-agent hermes -z "Reply with exactly: MODEL OK" -t ""
```

### Pointing it at the rest of the lab

Hermes is also on AI-LAB, so it can address the other services by name instead.
In `hermes/enc.env` (`sops hermes/enc.env`), and add the name to the
`environment:` block in `hermes/compose.yml` — enc.env alone does not reach the
container:

```sh
OPENAI_BASE_URL=http://llama-gpt-oss:9010/v1   # local inference
SEARXNG_URL=http://searxng:8080                # private search
```

`llama-gpt-oss` is a network alias carried by both llama.cpp profiles, so this
works whichever backend is active — and resolves to nothing when
`COMPOSE_PROFILES` names neither, which is its state on a host where
`llama.cpp/detect-gpu.sh` has never run. Switching the *model* over to it means
editing `config.yaml` as well; the variable alone does nothing.

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

- ~~**`open-webui/enc.env` mixes two syntaxes.**~~ Fixed. The four web-search lines
  (`ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`, `BRAVE_SEARCH_API_KEY`,
  `WEB_SEARCH_RESULT_COUNT`) once used the YAML-style `KEY: "value"` form, which
  Compose `env_file:` does not parse, so web search never reached the container.
  They are `KEY=value` now and `docker compose config` shows them resolving.
- **`WEBUI_AUTH=False`** disables Open WebUI's login entirely while Traefik
  publishes it on a public hostname. Set it to `True` before exposing this
  anywhere untrusted.
- **llama.cpp does nothing until `COMPOSE_PROFILES` is set**, and it must be set in
  the *root* `.env` — a copy in `llama.cpp/enc.env` is exported into the environment
  like any other variable but never activates a profile, leaving both services
  silently absent. `llm.ham51.com` 502s
  until one is active.
- **MCPJungle runs in `development` mode**, which means no authentication. It is
  no longer published on the host, but `https://mcp.ham51.com` still reaches it,
  and anyone who gets there can call every registered tool. TLS is not a login.
  Set `SERVER_MODE=enterprise` in `mcpjungle/enc.env` before exposing it beyond a
  trusted network.
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

Never commit a `.env` file, `traefik/letsencrypt/acme.json`,
`SearXNG/core-config/settings.yml`, or `hermes/hermes-data/` — `.gitignore`
covers all four. That last one is a whole directory rather than a single file:
the agent writes its own API keys, OAuth tokens and session history into it. When
changing configuration, update the matching `.example` file in the same commit
so the documentation stays honest.

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
sops hermes/enc.env     # decrypts into $EDITOR, re-encrypts on save
./runit.sh              # decrypt into the environment and restart
```

The age identity at `~/.config/sops/age/keys.txt` is the only thing that can read
any of it, and this repo contains no backup of it. Back it up somewhere outside
this machine, or the encrypted files become unreadable the day the disk dies.
