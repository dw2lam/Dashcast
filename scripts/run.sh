#!/usr/bin/env bash
# Build build/Dashcast.app, quit any running copy, and open the fresh build.
#
#   scripts/run.sh
#   DASHCAST_MOCK=1 scripts/run.sh     # DASHCAST_* variables are forwarded to the app
#   NO_BUILD=1 scripts/run.sh          # relaunch the existing build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dashcast.app"

if [[ "${NO_BUILD:-0}" != 1 ]]; then
    "$ROOT/scripts/build-app.sh"
fi

if pgrep -x Dashcast >/dev/null; then
    pkill -x Dashcast || true
    for _ in {1..50}; do
        pgrep -x Dashcast >/dev/null || break
        sleep 0.1
    done
    pkill -9 -x Dashcast 2>/dev/null || true
fi

ENV_ARGS=()
while IFS='=' read -r name _; do
    [[ "$name" == DASHCAST_* ]] && ENV_ARGS+=(--env "$name=${!name}")
done < <(env)

open ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$APP"
echo "Launched $APP${ENV_ARGS[*]:+ (${ENV_ARGS[*]})}"
