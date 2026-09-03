#!/usr/bin/env bash
# Decrypt every service's SOPS secrets into this process's environment, then run
# Docker Compose in it.
#
# Nothing is written to disk. The `<service>/enc.env` files are age-encrypted and
# committed; their plaintext exists only in the environment of this script and the
# `docker compose` it execs. There are no `<service>/.env` files any more — the
# compose files read every value through `${VAR}` interpolation instead of
# `env_file:`.
#
#   ./runit.sh                 decrypt, then `docker compose up -d`
#   ./runit.sh down            decrypt, then `docker compose down`
#   ./runit.sh logs -f hermes  decrypt, then `docker compose logs -f hermes`
#   ./runit.sh --names         list the variable names that would be exported
#
# Any argument that is not a flag of this script is passed to `docker compose`
# verbatim; with none, it runs `up -d`.
#
# THIS SCRIPT IS NOW THE ONLY WAY IN. A bare `docker compose ps` (or down, or
# logs) fails at parse time, because the required variables are no longer on disk
# for Compose to find. That is the trade for keeping plaintext off the disk; use
# `./runit.sh ps` instead.
#
# Editing a secret does NOT go through this script — use `sops <service>/enc.env`,
# which decrypts into $EDITOR and re-encrypts on save without ever writing
# plaintext to disk.
set -euo pipefail

# CLAUDE.md: every compose command runs from the project root. Running
# `docker compose -f <service>/compose.yml` from a service directory starts a
# *separate* project with its own volumes.
cd "$(dirname "$0")"

# The six services whose enc.env this script manages. The root .env is
# deliberately absent: it holds only COMPOSE_PROFILES, which is host-specific and
# not a secret — llama.cpp/detect-gpu.sh writes it, and Compose reads it directly.
SERVICES=(traefik open-webui SearXNG llama.cpp mcpjungle hermes)

NAMES_ONLY=0
COMPOSE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --names)   NAMES_ONLY=1 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)         COMPOSE_ARGS+=("$arg") ;;
    esac
done
[ ${#COMPOSE_ARGS[@]} -eq 0 ] && COMPOSE_ARGS=(up -d)

command -v sops >/dev/null 2>&1 || {
    echo "runit.sh: sops not found. Install it (brew install sops) — the config is" >&2
    echo "          encrypted and nothing can start without it." >&2
    exit 1
}

# SOPS finds the age identity via SOPS_AGE_KEY_FILE, SOPS_AGE_KEY, or this default
# path. Checking here turns a wall of per-file decryption errors into one message.
KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [ -z "${SOPS_AGE_KEY:-}" ] && [ ! -f "$KEY_FILE" ]; then
    echo "runit.sh: no age identity at $KEY_FILE" >&2
    echo "          Set SOPS_AGE_KEY_FILE, or restore the key: it is the only way" >&2
    echo "          to read the enc.env files and there is no other copy." >&2
    exit 1
fi

# Every name exported so far, and which service claimed it. The environment is one
# flat namespace, unlike the per-directory .env files this replaced, so two
# services defining the same name would leave one value silently overwritten.
# Refuse instead: prefix the name per service (OPENWEBUI_/HERMES_) and map it back
# in that service's compose.yml `environment:` block.
declare -A CLAIMED_BY=()
EXPORTED=()

# Progress goes to stderr: stdout belongs to the pass-through command, so
# `./runit.sh config --format json` stays machine-readable.
echo "Loading secrets into the environment..." >&2
for svc in "${SERVICES[@]}"; do
    enc="$svc/enc.env"
    [ -f "$enc" ] || { echo "runit.sh: missing $enc" >&2; exit 1; }

    if ! plaintext="$(sops -d --input-type dotenv --output-type dotenv "$enc" 2>&1)"; then
        echo "runit.sh: failed to decrypt $enc" >&2
        printf '%s\n' "$plaintext" | sed 's/^/          /' >&2
        exit 1
    fi

    count=0
    while IFS= read -r line; do
        # Blank lines and comments. A value is never taken from a comment — SOPS
        # does not encrypt comment text, so anything in one is public anyway.
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac

        key="${line%%=*}"
        val="${line#*=}"

        case "$key" in
            [A-Za-z_]*) ;;
            *) echo "runit.sh: $enc: bad variable name '$key'" >&2; exit 1 ;;
        esac
        if [ -n "$(printf '%s' "$key" | tr -d 'A-Za-z0-9_')" ]; then
            echo "runit.sh: $enc: bad variable name '$key'" >&2; exit 1
        fi

        # Strip one matching pair of surrounding quotes, the way Compose's dotenv
        # parser does. This matters: the quotes are load-bearing on values
        # containing '$' — an unquoted scrypt hash gets its $-segments expanded as
        # variables and silently mangled. Here the value is passed through
        # literally either way, but the quotes must still come off or they end up
        # inside the value.
        n=${#val}
        if [ "$n" -ge 2 ]; then
            first="${val:0:1}"; last="${val:n-1:1}"
            if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || \
               { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
                inner="${val:1:n-2}"
                # A double-quoted dotenv value may carry escapes (\n, \t) that
                # Compose would decode and this parser would not. Refuse rather
                # than pass through something subtly different.
                case "$inner" in
                    *\\*) echo "runit.sh: $enc: $key has a backslash escape this parser cannot reproduce" >&2; exit 1 ;;
                esac
                val="$inner"
            fi
        fi

        if [ -n "${CLAIMED_BY[$key]:-}" ]; then
            echo "runit.sh: $key is defined in both ${CLAIMED_BY[$key]}/enc.env and $enc." >&2
            echo "          The environment is one namespace — one of those values would be" >&2
            echo "          lost silently. Prefix it per service and map it back in that" >&2
            echo "          service's compose.yml \`environment:\` block." >&2
            exit 1
        fi
        CLAIMED_BY[$key]="$svc"

        export "$key=$val"
        EXPORTED+=("$key")
        count=$((count + 1))
    done <<< "$plaintext"

    printf '  %-18s %2d variables\n' "$enc" "$count" >&2
done
unset plaintext line val inner

if [ "$NAMES_ONLY" -eq 1 ]; then
    printf '%s\n' "${EXPORTED[@]}" | sort
    exit 0
fi

# Hermes chooses its model from hermes-data/config.yaml, which is gitignored and
# therefore absent on a fresh clone. Left absent, the container does not fail —
# it bootstraps its own config on the image's built-in default model and comes up
# looking entirely healthy, answering from the wrong place. Seed it here so that
# cannot happen silently.
#
# Only ever creates the file; Hermes rewrites config.yaml itself when settings
# change in the dashboard, so overwriting one that exists would discard real
# state.
HERMES_DATA="hermes/hermes-data"
HERMES_CONFIG="$HERMES_DATA/config.yaml"
HERMES_SEED="hermes/config.yaml.example"

if [ ! -e "$HERMES_DATA" ]; then
    # Create it as this user rather than letting Docker create it as root. The
    # container chowns it to its own uid (10000) on first run either way.
    mkdir -p "$HERMES_DATA"
fi

if [ ! -r "$HERMES_DATA" ] || [ ! -x "$HERMES_DATA" ]; then
    # The container has taken ownership (uid 10000, mode 700), so this is an
    # existing install and not a fresh one. We cannot even stat inside it — which
    # would make the -e test below read as "missing" and the copy fail. Say so
    # once and leave it alone.
    echo "  $HERMES_DATA is owned by the container; leaving config.yaml alone" >&2
elif [ ! -e "$HERMES_CONFIG" ]; then
    [ -f "$HERMES_SEED" ] || { echo "runit.sh: missing $HERMES_SEED" >&2; exit 1; }
    cp "$HERMES_SEED" "$HERMES_CONFIG"
    echo "  seeded $HERMES_CONFIG from $HERMES_SEED — edit it there, not in the" >&2
    echo "  example, and re-run to apply. It sets which model the agent uses." >&2
fi

# Parse the whole project before acting on it, so a missing variable or a bad
# compose edit fails here rather than halfway through starting containers.
docker compose config --quiet

echo "Running: docker compose ${COMPOSE_ARGS[*]}" >&2
exec docker compose "${COMPOSE_ARGS[@]}"
