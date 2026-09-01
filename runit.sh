#!/usr/bin/env bash
# Populate the environment from SOPS, then run Docker Compose.
#
# Each service keeps its secrets in a committed `<service>/enc.env` (age-encrypted
# by SOPS) rather than a gitignored `<service>/.env`. Compose cannot read those:
# `env_file:` wants a plain file, and so does the per-directory .env that
# `include:` uses for ${VAR} interpolation. So this script decrypts each enc.env
# into the .env beside it, then hands off to `docker compose`.
#
#   ./runit.sh                 decrypt, then `docker compose up -d`
#   ./runit.sh down            decrypt, then `docker compose down`
#   ./runit.sh logs -f hermes  decrypt, then `docker compose logs -f hermes`
#   ./runit.sh --decrypt-only  decrypt and stop there
#   ./runit.sh --clean         ...and remove the plaintext .env files afterwards
#
# Any arguments that are not flags of this script are passed through to
# `docker compose` verbatim; with none, it runs `up -d`.
#
# Editing a secret does NOT go through this script — use `sops <service>/enc.env`,
# which decrypts into $EDITOR and re-encrypts on save without ever writing
# plaintext to disk. Then re-run ./runit.sh to push the change into .env.
set -euo pipefail

# CLAUDE.md: every compose command runs from the project root. Running
# `docker compose -f <service>/compose.yml` from a service directory starts a
# *separate* project with its own volumes.
cd "$(dirname "$0")"

# The six services whose enc.env this script manages. The root .env is
# deliberately absent: it holds only COMPOSE_PROFILES, which is host-specific and
# not a secret — llama.cpp/detect-gpu.sh writes it.
SERVICES=(traefik open-webui SearXNG llama.cpp mcpjungle hermes)

CLEAN=0
DECRYPT_ONLY=0
COMPOSE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean)        CLEAN=1 ;;
        --decrypt-only) DECRYPT_ONLY=1 ;;
        -h|--help)      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)              COMPOSE_ARGS+=("$arg") ;;
    esac
done
# No compose verb given: bring the lab up.
[ ${#COMPOSE_ARGS[@]} -eq 0 ] && COMPOSE_ARGS=(up -d)

command -v sops >/dev/null 2>&1 || {
    echo "runit.sh: sops not found. Install it (brew install sops) — the .env" >&2
    echo "          files are encrypted and nothing can start without it." >&2
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

echo "Decrypting env files..."
for svc in "${SERVICES[@]}"; do
    enc="$svc/enc.env"
    out="$svc/.env"
    [ -f "$enc" ] || { echo "runit.sh: missing $enc" >&2; exit 1; }

    # Decrypt to a temp first. Redirecting sops straight into $out truncates a
    # working .env the moment sops errors — which is exactly how the .env files
    # were lost once already.
    tmp="$(mktemp "${TMPDIR:-/tmp}/runit.XXXXXX")"
    if ! sops -d --input-type dotenv --output-type dotenv "$enc" > "$tmp" 2>"$tmp.err"; then
        echo "runit.sh: failed to decrypt $enc" >&2
        sed 's/^/          /' "$tmp.err" >&2
        rm -f "$tmp" "$tmp.err"
        exit 1
    fi
    [ -s "$tmp" ] || { echo "runit.sh: $enc decrypted to nothing" >&2; rm -f "$tmp" "$tmp.err"; exit 1; }

    install -m 600 "$tmp" "$out"
    rm -f "$tmp" "$tmp.err"
    printf '  %-11s -> %s\n' "$enc" "$out"
done

if [ "$DECRYPT_ONLY" -eq 1 ]; then
    echo "--decrypt-only: stopping before docker compose."
    exit 0
fi

# Parse the whole project before acting on it, so a bad env file or compose edit
# fails here rather than halfway through starting containers.
docker compose config --quiet

echo "Running: docker compose ${COMPOSE_ARGS[*]}"
set +e
docker compose "${COMPOSE_ARGS[@]}"
rc=$?
set -e

if [ "$CLEAN" -eq 1 ]; then
    # Note this leaves the project unusable until the next ./runit.sh: every later
    # compose command (ps, logs, down) re-parses env_file and fails without these.
    for svc in "${SERVICES[@]}"; do rm -f "$svc/.env"; done
    echo "--clean: removed the decrypted .env files."
fi

exit $rc
