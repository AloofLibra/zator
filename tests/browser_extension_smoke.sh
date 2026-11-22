#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_TEST="$ROOT/tests/browser_extension_smoke.mjs"
if command -v node >/dev/null 2>&1; then
  node "$NODE_TEST"
elif command -v node.exe >/dev/null 2>&1; then
  command -v wslpath >/dev/null 2>&1 && NODE_TEST="$(wslpath -w "$NODE_TEST")"
  node.exe "$NODE_TEST"
elif command -v powershell.exe >/dev/null 2>&1; then
  command -v wslpath >/dev/null 2>&1 && NODE_TEST="$(wslpath -w "$NODE_TEST")"
  powershell.exe -NoProfile -Command "node -- '$NODE_TEST'"
else
  echo 'Node.js is required for the browser extension smoke test' >&2
  exit 1
fi
