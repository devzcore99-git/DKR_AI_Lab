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

**Exposure — 443 is the only host port.** No service publishes one; Traefik binds
443 alone and routes six hosts from `traefik/proxies.yml`: oracle (Open WebUI), llm
(llama.cpp), search (SearXNG), mcp (MCPJungle), hermes (the Hermes dashboard), plus
lmstudio — a host process via `host.docker.internal`. Every router binds `port443`
with `certResolver: letsencrypt`, so there is no plaintext path in. Adding a `ports:`
block anywhere re-opens one; reach for `docker compose exec` instead.

TLS is not authentication, and three of these have none: `open-webui/.env` sets
`WEBUI_AUTH=False`, llama.cpp runs with no `--api-key`, and MCPJungle defaults to
`SERVER_MODE=development`. Anyone who resolves the hostname reaches them. Still
trusted-LAN-only. Hermes is the one exception — password-gated at the app.

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

**Hermes picks its model in `hermes-data/config.yaml`, not from the environment.**
`model.default` + the matching `custom_providers` entry are what the agent uses every
turn; `OPENAI_BASE_URL` reaches only individual plugins. Setting the env var alone
therefore *looks* like it worked — container up, dashboard answering, agent replying
out of the image's built-in default. The lab's is `coder-mid` at
`https://llm-coder-mid.ham51.com/v1`, llama.cpp on the DKR_AI_Lab2 host (a separate
machine over the LAN, not AI-LAB), keyed by `HERMES_CUSTOM_LLM_CODER_MID_HAM51_COM_API_KEY`
— the variable name is what `key_env:` names, so the two rename together. `https` is
required: that Traefik binds 443 alone too. `hermes-data/` is gitignored and the
container chowns it to uid 10000, so `hermes/config.yaml.example` is the only readable
record of the intent, and reading the live file means `docker exec`. `./runit.sh` seeds
config.yaml from that example when it is missing, and only then — it never overwrites,
because Hermes rewrites the file itself. Once the container owns the directory the host
cannot even stat inside it, so the seeder detects that and says it is skipping rather
than misreading it as a fresh install. Verify a change
with `docker exec hermes-agent hermes -z "Reply with exactly: MODEL OK" -t ""` — the
config parses fine when the model name is wrong.

**Secrets — there are no `.env` files, and `./runit.sh` is the only way in.** Each
service commits an age-encrypted `<service>/enc.env`. `./runit.sh` decrypts all six
into *its own environment* and execs `docker compose` there (passing arguments
through, so `./runit.sh ps`, `./runit.sh down`, `./runit.sh logs -f hermes` all work).
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
variables and silently mangles it. `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` is a
scrypt hash of the form `scrypt$N$r$p$...` and is single-quoted for exactly this
reason — unquoting it produces a hash that no password matches, with no error
anywhere. This also makes eyeballing two values misleading: `open-webui/enc.env`
quotes some values the other files leave bare, so identical secrets do not look
identical. `runit.sh` refuses a double-quoted value containing a backslash rather
than pass through an escape it would decode differently from Compose.

`.sops.yaml` encrypts by variable *name* (`KEY|TOKEN|SECRET|PASSWORD|HASH|USERNAME|
CREDENTIAL`), leaving everything else legible. So a new secret whose name misses that
regex is committed in the clear, and **comments are never encrypted** — a value in a
`#` line goes to the repo plaintext. The root `.env` is out of the scheme on purpose:
it holds only `COMPOSE_PROFILES`, host-specific and written by `detect-gpu.sh`, and
Compose reads it directly.

The `enc.env.example` siblings are the documentation — they are not copied anywhere,
they describe what an `enc.env` must contain. Still gitignore-paired with
`traefik/letsencrypt/acme.json` and `SearXNG/core-config/settings.yml` — update both
in the same commit. Name variables, never values: `CF_DNS_API_TOKEN`,
`OPENWEBUI_OPENAI_API_KEY`, `WEBUI_SECRET_KEY`, `BRAVE_API_KEY`, `server.secret_key`.

**Secrets shared between services are namespaced by service, and must stay that way.**
All six `enc.env` files are now loaded into one flat environment, so two services
defining the same name is a real collision rather than a latent one. `runit.sh`
refuses it: it tracks which service claimed each name and exits with both filenames.
So the shared names carry a service prefix in `enc.env` — `OPENWEBUI_`, `HERMES_` —
and `open-webui/compose.yml` / `hermes/compose.yml` map them back to the plain names
the applications read. The prefixed names stay host-side and no longer leak into the
containers, which `env_file:` used to do.

`OPENWEBUI_OPENAI_API_KEY` and `HERMES_OPENAI_API_KEY` are genuinely different keys for
different backends. Brave is the opposite case and worth knowing before rotating it:
`OPENWEBUI_BRAVE_SEARCH_API_KEY`, `HERMES_BRAVE_SEARCH_API_KEY` and mcpjungle's
`BRAVE_API_KEY` are three copies of the *same* value, under two names, that nothing
keeps in step — so a rotation is three edits, and comparing them by eye is misleading
because `open-webui/enc.env` quotes its value and the others do not.

The age identity (`~/.config/sops/age/keys.txt`) is the only key, with no backup in
the repo.

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

## Dependencies

Only `traefik:v3.7.8`, `postgres:17`, `prom/prometheus:v2.53.0`, and
`playwright/mcp:v0.0.79` are pinned; `searxng:latest`, `open-webui:main`,
`llama.cpp:server-cuda`, `llama.cpp:server-vulkan`, `mcpjungle:latest-stdio`,
`mcp/brave-search:latest`, `mcp/context7:latest`, and
`nousresearch/hermes-agent:latest` re-resolve on every pull, so rebuilds are not
reproducible. Playwright is pinned because a bump moves both the MCP tool surface
and the bundled Chromium; override with `PLAYWRIGHT_MCP_IMAGE_TAG`. Hermes is the
sharpest case: a pull can swap the application *and its on-disk schemas* under
`hermes-data/`, with no rollback. The llama.cpp images also
publish `server-rocm` and plain `server` (CPU) if a third profile is ever wanted.
MCPJungle needs the `-stdio` image tag specifically — it ships the `uvx` and
`python3` that stdio servers such as `fetch` are spawned with; plain `latest` cannot
run them.

---

This file loads as live instructions every session — keep it short and true.
A stale rule here is worse than no rule, and it is not a place to park notes
meant for somewhere else.
