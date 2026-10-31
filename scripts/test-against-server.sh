#!/usr/bin/env bash
# Runs AtlasDrive's integration tests against a real Neutrino server: builds ../neutrino (or
# $NEUTRINO_DIR), starts it on a free port with a throwaway database and storage, runs the tests
# with ATLAS_TEST_SERVER set, and stops it. Extra arguments go to `swift test`.
#
#   scripts/test-against-server.sh                 # AtlasDriveTests
#   ATLAS_TEST_SERVER=http://localhost:8080 swift test --filter AtlasDriveTests   # your own server
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
neutrino="${NEUTRINO_DIR:-$here/../neutrino}"
[ -f "$neutrino/Cargo.toml" ] || { echo "no neutrino checkout at $neutrino (set NEUTRINO_DIR)" >&2; exit 1; }

(cd "$neutrino" && cargo build --quiet --bin neutrino)

work="$(mktemp -d)"
mkdir -p "$work/storage"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
url="http://localhost:$port"

PORT="$port" JWT_SECRET="$(openssl rand -hex 32)" WORKER_SECRET="$(openssl rand -hex 32)" \
  DATABASE_URL="$work/neutrino.db" STORAGE_PATH="$work/storage" MAIL_TRANSPORT=outbox DRIVE_URL="$url" \
  "${CARGO_TARGET_DIR:-$neutrino/target}/debug/neutrino" > "$work/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 120); do
  curl -fs "$url/health" > /dev/null && break
  kill -0 $pid 2>/dev/null || { cat "$work/server.log" >&2; exit 1; }
  sleep 0.5
done
curl -fs "$url/health" > /dev/null || { echo "server didn't start" >&2; tail -50 "$work/server.log" >&2; exit 1; }

cd "$here"
if [ $# -eq 0 ]; then set -- --filter AtlasDriveTests; fi
ATLAS_TEST_SERVER="$url" swift test "$@"
