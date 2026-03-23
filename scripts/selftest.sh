#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTNET_MAJOR="${1:-10}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/js-next-selftest.XXXXXX")"
TSONIC_CLI="${TSONIC_CLI:-tsonic@latest}"
LOCAL_NUGET_FEED="$WORK_DIR/local-nuget"
export NUGET_PACKAGES="$WORK_DIR/nuget-packages"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

run_tsonic() {
  if [[ "$TSONIC_CLI" == *.js ]]; then
    node "$TSONIC_CLI" "$@"
    return
  fi

  npx --yes "$TSONIC_CLI" "$@"
}

run_tsonic_in() {
  local workdir="$1"
  shift
  (
    cd "$workdir"
    run_tsonic "$@"
  )
}

write_local_nuget_config() {
  local workspace_dir="$1"
  cat >"$workspace_dir/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$LOCAL_NUGET_FEED" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF
}

pack_local_runtime_packages() {
  mkdir -p "$LOCAL_NUGET_FEED"
  dotnet pack "$PROJECT_ROOT/../runtime/src/Tsonic.Runtime/Tsonic.Runtime.csproj" -c Release -o "$LOCAL_NUGET_FEED" >/dev/null
}

pack_local_runtime_packages

cat >"$WORK_DIR/package.json" <<EOF
{
  "name": "js-next-selftest",
  "private": true,
  "type": "module",
  "dependencies": {
    "@tsonic/core": "file:$PROJECT_ROOT/../core/versions/$DOTNET_MAJOR",
    "@tsonic/dotnet": "file:$PROJECT_ROOT/../dotnet/versions/$DOTNET_MAJOR",
    "@tsonic/js": "file:$PROJECT_ROOT/versions/$DOTNET_MAJOR"
  }
}
EOF

npm --prefix "$WORK_DIR" install >/dev/null
run_tsonic_in "$WORK_DIR" init --surface @tsonic/js --skip-types >/dev/null
write_local_nuget_config "$WORK_DIR"

PROJECT_NAME="$(basename "$WORK_DIR")"
APP_PATH="$WORK_DIR/packages/$PROJECT_NAME/src/App.ts"

cat >"$APP_PATH" <<'EOF'
import type { long } from "@tsonic/core/types.js";

export function main(): void {
  const parsed = parseInt("42");
  const parsedFloat = parseFloat("42.5");
  const finite = isFinite(parsedFloat);
  const nan = isNaN(parseFloat("not-a-number"));
  const rounded = Math.round(42.7);
  const epoch = Date.parse("2024-01-01T00:00:00Z");
  const now: long = Date.now();
  const truthy = Boolean(1);
  const falsey = Boolean(0);

  console.log(`${parsed},${parsedFloat},${finite},${nan},${rounded},${epoch > 0},${now > 0},${truthy.toString()},${String(falsey)}`);
}
EOF

run_tsonic_in "$WORK_DIR" build >/dev/null

ASSETS_FILE="$(find "$WORK_DIR" -name project.assets.json | head -n 1)"
if [ -z "$ASSETS_FILE" ]; then
  echo "project.assets.json not found" >&2
  exit 1
fi

if rg -q "Tsonic\\.JSRuntime" "$ASSETS_FILE"; then
  echo "Unexpected Tsonic.JSRuntime package reference in $ASSETS_FILE" >&2
  exit 1
fi

OUTPUT="$(
  run_tsonic_in "$WORK_DIR" run 2>/dev/null \
    | sed '/^Running /d;/^Process exited with code /d;/^─/d;/^$/d' \
    | tail -n 1
)"
[ "$OUTPUT" = "42,42.5,true,true,43,true,true,true,false" ]

echo "js-next selftest passed"
