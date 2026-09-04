# CLAUDE.md - DKR_AI_Lab

Guidance for Claude Code when working in this project.

## Project Overview

Self-hosted AI lab — Open WebUI, SearXNG and the MCPJungle MCP gateway behind one
Traefik v3 proxy with Let's Encrypt DNS-01 TLS. Inference is not run here: Open
WebUI points at `coder-mid` on the DKR_AI_Lab2 host over the LAN. `README.md` is
the setup guide; keep it in sync.

## Conventions

**Bring-up.** The root `compose.yaml` is only an `include:` list of four per-service
files (`traefik/`, `open-webui/`, `SearXNG/`, `mcpjungle/`); run every command from the
project root (`docker compose up -d`). Running `docker compose -f <service>/compose.yml`
from a service directory starts a *separate* project.

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

**Exposure — 443 is the only host port.** No service publishes one; Traefik binds
443 alone and routes four hosts from `traefik/proxies.yml`: oracle (Open WebUI),
search (SearXNG), mcp (MCPJungle), plus lmstudio — a host process via
`host.docker.internal`. Every router binds `port443` with `certResolver: letsencrypt`,
so there is no plaintext path in. Adding a `ports:` block anywhere re-opens one; reach
for `docker compose exec` instead.

TLS is not authentication, and nothing here has any: `open-webui/enc.env` sets
`WEBUI_AUTH=False` and MCPJungle defaults to `SERVER_MODE=development`. Anyone who
resolves the hostname reaches them. Trusted-LAN-only, with no exceptions left.

**Secrets — there are no `.env` files, and `./runit.sh` is the only way in.** Each
service commits an age-encrypted `<service>/enc.env`. `./runit.sh` decrypts all four
into *its own environment* and execs `docker compose` there (passing arguments
through, so `./runit.sh ps`, `./runit.sh down`, `./runit.sh logs -f traefik` all work).
Nothing plaintext is written to disk. The consequence is absolute: a bare `docker
compose` command of any kind — `ps`, `down`, `config` — dies at parse time on the
first `${VAR:?}` it cannot resolve. That error means "you forgot ./runit.sh", not
that anything is misconfigured. Edit a secret with `sops <service>/enc.env`, which
round-trips through `$EDITOR` without putting plaintext on disk.

**A variable in `enc.env` reaches nothing on its own.** `env_file:` is gone, so each
service's `compose.yml` `environment:` block is the complete, explicit list of what
that container receives, wired with `${VAR}`. Add a variable to `enc.env` and forget
the compose file and it is exported into the environment, ignored by Compose, and
never seen by the application — no error. That is the standing cost of this design;
`:?` on anything genuinely required is what buys the error back.

**Quoting in an `enc.env` is significant, and asymmetric.** Values are passed through
literally, but one matching pair of surrounding quotes is stripped. A value containing
`$` **must** be quoted: unquoted, the dotenv parser expands its `$`-segments as
variables and silently mangles it — a `$`-bearing secret such as a `scrypt$N$r$p$...`
hash arrives subtly wrong, with no error anywhere. This also makes eyeballing two
values misleading: `open-webui/enc.env` quotes some values the other files leave
bare, so identical secrets do not look identical. `runit.sh` refuses a
double-quoted value containing a backslash rather
than pass through an escape it would decode differently from Compose.

`.sops.yaml` encrypts by variable *name* (`KEY|TOKEN|SECRET|PASSWORD|HASH|USERNAME|
CREDENTIAL`), leaving everything else legible. So a new secret whose name misses that
regex is committed in the clear, and **comments are never encrypted** — a value in a
`#` line goes to the repo plaintext. There is no root `.env` at all any more: nothing
in the project needs a project-wide Compose variable.

The `enc.env.example` siblings are the documentation — they are not copied anywhere,
they describe what an `enc.env` must contain. Still gitignore-paired with
`traefik/letsencrypt/acme.json` and `SearXNG/core-config/settings.yml` — update both
in the same commit. Name variables, never values: `CF_DNS_API_TOKEN`,
`OPENWEBUI_OPENAI_API_KEY`, `WEBUI_SECRET_KEY`, `BRAVE_API_KEY`, `server.secret_key`.

**Secrets that could collide are namespaced by service, and must stay that way.**
All four `enc.env` files are loaded into one flat environment, so two services defining
the same name is a real collision rather than a latent one. `runit.sh` refuses it: it
tracks which service claimed each name and exits with both filenames. That is why Open
WebUI's keys carry an `OPENWEBUI_` prefix in `enc.env` and `open-webui/compose.yml`
maps them back to the plain `OPENAI_API_KEY` / `BRAVE_SEARCH_API_KEY` the application
reads. Keep the prefix when adding a generically-named secret — the alternative is a
name that works today and breaks the day another service wants it.

Brave is worth knowing before rotating: `OPENWEBUI_BRAVE_SEARCH_API_KEY` and
mcpjungle's `BRAVE_API_KEY` are two copies of the *same* value, under different names,
that nothing keeps in step — so a rotation is two edits, and comparing them by eye is
misleading because `open-webui/enc.env` quotes its value and mcpjungle's does not.

The age identity (`~/.config/sops/age/keys.txt`) is the only key, with no backup in
the repo.

**`recommendations.md` is a review, not a to-do list** — its `searxng-valkey` finding
is fixed, not open, and so is the `open-webui/.env` one (the four web-search lines
used YAML `KEY: "value"`, which `env_file:` does not parse; they are `KEY=value` now
and resolve in `docker compose config`). Check a finding against the tree before
acting on it.

**Playwright's host check is the one that bites.** `mcpjungle/compose.yml` runs
Microsoft's `playwright/mcp` image with its stdio entrypoint overridden to
`node /app/cli.js ... --port=9003 --host=0.0.0.0`. `--host 0.0.0.0` binds every
interface but does *not* widen the DNS-rebinding check: `--allowed-hosts` "defaults
to the host the server is bound to", i.e. `localhost:9003`. Omit it and the
container starts, the healthcheck passes, and the gateway gets `403 Access is only
allowed at localhost:9003` on every call. The flag must list the Host mcpjungle
sends (`playwright:9003`, from the register job's `--url`) plus `127.0.0.1:9003`
for the healthcheck — edit the URL and the flag together. The image is Debian slim
with neither curl nor wget, so that healthcheck goes through `node` instead. Docker
gets headless Chromium only (`--browser firefox` will not start), it needs
`--no-sandbox` and `shm_size: 1gb`, and `browser_run_code_unsafe` is
RCE-equivalent — it is deliberately kept out of the `WebAutomation` tool group.

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

**And so does the model backend — this is the same trap, on the setting most likely
to be changed.** `OPENAI_API_BASE_URL` and `OPENAI_API_KEY` are PersistentConfig in
Open WebUI: they seed `webui.db` while the row is absent and are ignored afterwards.
On the lab host, whose `dkr_ai_lab_open-webui2` volume is long since populated,
editing `open-webui/enc.env` and restarting therefore changes *nothing* — no error,
the old backend simply stays. Change it in Admin Settings → Connections instead, or
clear the row and restart:

```sh
./runit.sh exec open-webui python -c \
  "import sqlite3;sqlite3.connect('/app/backend/data/webui.db').execute(\"delete from config where key='openai'\").connection.commit()"
```

The enc.env value is still what a fresh volume gets, so keep the two in step rather
than treating the UI as the only record.

## Dependencies

Only `traefik:v3.7.8`, `postgres:17`, `prom/prometheus:v2.53.0`, and
`playwright/mcp:v0.0.79` are pinned; `searxng:latest`, `open-webui:main`,
`mcpjungle:latest-stdio`, `mcp/brave-search:latest` and `mcp/context7:latest`
re-resolve on every pull, so rebuilds are not reproducible. Playwright is pinned
because a bump moves both the MCP tool surface and the bundled Chromium; override with
`PLAYWRIGHT_MCP_IMAGE_TAG`. MCPJungle needs the `-stdio` image tag specifically — it
ships the `uvx` and `python3` that stdio servers such as `fetch` are spawned with;
plain `latest` cannot run them.

---

This file loads as live instructions every session — keep it short and true.
A stale rule here is worse than no rule, and it is not a place to park notes
meant for somewhere else.
