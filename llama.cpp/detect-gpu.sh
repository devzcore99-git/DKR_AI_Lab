#!/bin/sh
# Pick a llama.cpp GPU backend for this host and record it.
#
# Writes COMPOSE_PROFILES to the PROJECT ROOT .env (../.env), not to
# llama.cpp/.env. Compose reads COMPOSE_PROFILES once per project; a copy in a
# service directory is read for interpolation but never activates a profile, so
# putting it there leaves llama.cpp silently not running.
#
# Run once at setup, or again after installing/removing a GPU driver. The result
# is a plain file — edit ../.env by hand whenever the guess is wrong.
#
#   ./detect-gpu.sh          detect and write
#   ./detect-gpu.sh --dry-run  print what it would choose, change nothing
set -eu

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

cd "$(dirname "$0")"
ENV_FILE="../.env"

# Detect on the NVIDIA container *runtime*, not on hardware. Hardware presence is
# not the question — whether Docker can hand a GPU to a container is. This host,
# for instance, has a stale /dev/nvidiactl and no NVIDIA card at all, so probing
# /dev/nvidia* would pick CUDA and fail at container start.
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    PROFILE=cuda
    REASON="docker reports an 'nvidia' runtime (NVIDIA Container Toolkit installed)"
elif [ -e /dev/dri/renderD128 ]; then
    PROFILE=vulkan
    REASON="no nvidia runtime; /dev/dri/renderD128 present (AMD/Intel GPU)"
else
    echo "No usable GPU backend found:" >&2
    echo "  - docker reports no 'nvidia' runtime" >&2
    echo "  - no /dev/dri/renderD128 render node" >&2
    echo "" >&2
    echo "Leave COMPOSE_PROFILES unset and llama.cpp simply will not start;" >&2
    echo "the rest of the lab comes up normally." >&2
    exit 1
fi

echo "Backend: $PROFILE"
echo "Reason:  $REASON"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "(--dry-run, $ENV_FILE not modified)"
    exit 0
fi

# Rewrite only the COMPOSE_PROFILES line, preserving anything else in the file.
touch "$ENV_FILE"
if grep -q '^COMPOSE_PROFILES=' "$ENV_FILE"; then
    OLD=$(grep -m1 '^COMPOSE_PROFILES=' "$ENV_FILE" | cut -d= -f2-)
    [ "$OLD" = "$PROFILE" ] && { echo "$ENV_FILE already set to $PROFILE, unchanged"; exit 0; }
    grep -v '^COMPOSE_PROFILES=' "$ENV_FILE" > "$ENV_FILE.tmp"
    echo "COMPOSE_PROFILES=$PROFILE" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
    echo "Updated $ENV_FILE: $OLD -> $PROFILE"
else
    echo "COMPOSE_PROFILES=$PROFILE" >> "$ENV_FILE"
    echo "Wrote $ENV_FILE: COMPOSE_PROFILES=$PROFILE"
fi

echo ""
echo "Next: set LLAMA_MODELS_DIR and LLAMA_MODEL in llama.cpp/.env, then"
echo "      docker compose up -d   (from the project root)"
