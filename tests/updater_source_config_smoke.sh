#!/bin/bash

set -e

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/z2r_source_config.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

PREFIX="$TEST_DIR/z2r_prefix.sh"
awk '/^#___Проверка на наличие необходимых библиотек___#$/ { exit } { print }' \
  "$REPO_DIR/z2r.sh" > "$PREFIX"

unset Z2R_PROJECT_RAW_BASE Z2R_BRANCH Z2R_REPOSITORY Z2R_COMMIT
Z2R_UPDATE_DIR="$TEST_DIR/state"
Z2R_UPDATE_CONFIG="$Z2R_UPDATE_DIR/update.conf"
export Z2R_UPDATE_DIR Z2R_UPDATE_CONFIG

# shellcheck disable=SC1090
source "$PREFIX"
Z2R_RUNTIME_ROOT="$TEST_DIR/runtime"
# shellcheck disable=SC1090
source "$REPO_DIR/lib/updater.sh"

# Все runtime-библиотеки обязаны быть в preflight и в развёртывании. Иначе
# после удаления /opt/zapret2 следующий запуск launcher попадёт в рекурсию.
grep -F 'for rel in "${Z2R_RUNTIME_LIBRARIES[@]}"; do' "$REPO_DIR/z2r.sh" >/dev/null
grep -F 'project_files+=("lib/$rel")' "$REPO_DIR/z2r.sh" >/dev/null
grep -F 'for lib in "${Z2R_RUNTIME_LIBRARIES[@]}"; do' "$REPO_DIR/z2r.sh" >/dev/null
grep -F 'z2r_download_project_file "/opt/zapret2/z2r_lib/$lib" "lib/$lib"' "$REPO_DIR/z2r.sh" >/dev/null
grep -F 'z2r_download_project_file "$ORCH_LUA_LOCKED" "orchestra/locked.lua"' "$REPO_DIR/z2r.sh" >/dev/null
grep -F 'z2r_download_project_file "$RST_GUARD_LUA" "lua/rst-guard.lua"' "$REPO_DIR/z2r.sh" >/dev/null

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_file_contains() {
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || {
    echo "FAIL: '$needle' not found in $file" >&2
    exit 1
  }
}

mkdir -p "$Z2R_UPDATE_DIR"
cat > "$Z2R_UPDATE_CONFIG" <<'EOF'
# comments and surrounding whitespace are accepted
Z2R_PROJECT_RAW_BASE = "Sehat1137/zator"
Z2R_BRANCH='feature/test'
EOF
z2r_source_load_config
assert_eq "$Z2R_SOURCE_RAW_BASE" "Sehat1137/zator" "repository shorthand"
assert_eq "$Z2R_SOURCE_REF" "feature/test" "quoted installation ref"
assert_eq "$Z2R_SOURCE_CONFIG_ORIGIN" "config" "config origin"

cat > "$Z2R_UPDATE_CONFIG" <<'EOF'
Z2R_REPOSITORY="Sehat1137/zator"
Z2R_COMMIT="0123456789abcdef0123456789abcdef01234567"
EOF
z2r_source_load_config
assert_eq "$Z2R_SOURCE_RAW_BASE" "https://raw.githubusercontent.com/Sehat1137/zator" "repository alias"
assert_eq "$Z2R_SOURCE_REF" "0123456789abcdef0123456789abcdef01234567" "commit alias"

Z2R_ENV_SOURCE_REF="env/test"
z2r_source_load_config
assert_eq "$Z2R_SOURCE_REF" "env/test" "environment override"
assert_eq "$Z2R_SOURCE_CONFIG_ORIGIN" "environment" "environment origin"
unset Z2R_ENV_SOURCE_REF

marker="$TEST_DIR/should-not-exist"
cat > "$Z2R_UPDATE_CONFIG" <<EOF
Z2R_BRANCH="\$(touch $marker)"
EOF
if z2r_source_load_config; then
  echo "FAIL: command-like value was accepted" >&2
  exit 1
fi
[ ! -e "$marker" ] || {
  echo "FAIL: update.conf value was executed" >&2
  exit 1
}

cat > "$Z2R_UPDATE_CONFIG" <<'EOF'
Z2R_UNKNOWN="value"
EOF
if z2r_source_load_config; then
  echo "FAIL: unknown key was accepted" >&2
  exit 1
fi

z2r_source_write_config "Sehat1137/zator" "zator"
assert_file_contains 'Z2R_PROJECT_RAW_BASE="Sehat1137/zator"' "$Z2R_UPDATE_CONFIG"
assert_file_contains 'Z2R_BRANCH="zator"' "$Z2R_UPDATE_CONFIG"

if z2r_source_write_config "Sehat1137/zator" "bad ref"; then
  echo "FAIL: invalid ref was written" >&2
  exit 1
fi

cat > "$Z2R_UPDATE_CONFIG" <<'EOF'
Z2R_PROJECT_RAW_BASE="https://raw.githubusercontent.com/Sehat1137/zator/feature/test"
EOF
z2r_source_load_config
assert_eq "$Z2R_SOURCE_RAW_BASE" "https://raw.githubusercontent.com/Sehat1137/zator" "legacy raw root"
assert_eq "$Z2R_SOURCE_REF" "feature/test" "legacy raw ref"

mock_commit="0123456789abcdef0123456789abcdef01234567"
z2r_fetch_url_stdout() {
  printf '{"sha":"%s"}\n' "$mock_commit"
}
z2r_source_prepare
assert_eq "$Z2R_SOURCE_REPOSITORY" "Sehat1137/zator" "resolved repository"
assert_eq "$Z2R_SOURCE_RESOLVED_COMMIT" "$mock_commit" "resolved commit"
assert_eq "$(z2r_source_raw_url 'lib/updater.sh')" \
  "https://raw.githubusercontent.com/Sehat1137/zator/$mock_commit/lib/updater.sh" \
  "commit-pinned raw URL"

fetch_calls="$TEST_DIR/fetch.calls"
z2r_fetch_url_to_file() {
  printf '%s\n' "$2" >> "$fetch_calls"
  return 1
}
if z2r_download_project_file "$TEST_DIR/downloaded" "lists/test.txt"; then
  echo "FAIL: mocked strict download unexpectedly succeeded" >&2
  exit 1
fi
assert_eq "$(wc -l < "$fetch_calls" | tr -d ' ')" "1" "strict download request count"
assert_eq "$(cat "$fetch_calls")" \
  "https://raw.githubusercontent.com/Sehat1137/zator/$mock_commit/lists/test.txt" \
  "strict download URL"

payload="$TEST_DIR/payload"
printf 'cached payload\n' > "$payload"
z2r_source_cache_store "lists/test.txt" "$payload"
z2r_source_cache_restore "lists/test.txt" "$TEST_DIR/restored"
assert_eq "$(cat "$TEST_DIR/restored")" "cached payload" "source-scoped cache"
cache_path="$(z2r_source_cache_path "lists/test.txt")"
printf 'corrupted cache\n' > "$cache_path"
if z2r_source_cache_restore "lists/test.txt" "$TEST_DIR/corrupted-restored"; then
  echo "FAIL: corrupted cache was accepted" >&2
  exit 1
fi

runtime_file="$Z2R_RUNTIME_ROOT/zapret2/lists/test.txt"
mkdir -p "$(dirname "$runtime_file")"
cp "$payload" "$runtime_file"
z2r_source_track_begin
z2r_source_track_file "$runtime_file" "lists/test.txt"
z2r_source_track_finish
assert_eq "$(z2r_source_manifest_value resolved_commit)" "$mock_commit" "deployed manifest commit"
assert_eq "$(z2r_source_local_change_count)" "0" "clean deployed runtime"
printf 'manually changed\n' > "$runtime_file"
assert_eq "$(z2r_source_local_change_count)" "1" "manual runtime change"

z2r_fetch_url_to_file() {
  printf 'canonical payload\n' > "$1"
}
z2r_source_reset
assert_eq "$(cat "$runtime_file")" "canonical payload" "source reset reconciliation"
assert_file_contains 'Z2R_PROJECT_RAW_BASE="https://raw.githubusercontent.com/AloofLibra/zator"' "$Z2R_UPDATE_CONFIG"
assert_file_contains 'Z2R_BRANCH="zator"' "$Z2R_UPDATE_CONFIG"

persistent_command="$TEST_DIR/bin/z2r"
persistent_runtime="$TEST_DIR/runtime-launcher.sh"
mkdir -p "$(dirname "$persistent_command")"
printf '#!/bin/sh\necho legacy\n' > "$persistent_command"
printf '#!/bin/bash\nexit 0\n' > "$persistent_runtime"
chmod 755 "$persistent_command" "$persistent_runtime"
Z2R_COMMAND_LAUNCHER="$persistent_command"
Z2R_RUNTIME_LAUNCHER="$persistent_runtime"
z2r_install_persistent_launcher
assert_file_contains '# z2r persistent launcher' "$persistent_command"
assert_file_contains "$(command -v bash)" "$persistent_command"
assert_file_contains "$persistent_runtime" "$persistent_command"
assert_file_contains 'echo legacy' "$Z2R_UPDATE_DIR/legacy-bootstrap.z2r"
unset Z2R_COMMAND_LAUNCHER Z2R_RUNTIME_LAUNCHER

launcher="$TEST_DIR/launcher.sh"
refresh_payload="$TEST_DIR/launcher.new"
refresh_marker="$TEST_DIR/refreshed"
cat > "$launcher" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$refresh_payload" <<EOF
#!/bin/bash
printf '%s' "\$Z2R_SELF_REFRESHED" > "$refresh_marker"
EOF
chmod 755 "$launcher" "$refresh_payload"
launcher_link="$TEST_DIR/z2r"
ln -s "$launcher" "$launcher_link"
assert_eq "$(z2r_launcher_path "$launcher_link")" "$launcher" "launcher symlink resolution"
z2r_fetch_url_to_file() {
  cp "$refresh_payload" "$1"
}
(
  Z2R_LAUNCHER_PATH="$launcher"
  Z2R_SELF_REFRESH_ROOT="$TEST_DIR"
  Z2R_SELF_REFRESHED=0
  z2r_bootstrap_refresh_launcher
)
assert_eq "$(cat "$refresh_marker")" "1" "self-refresh exec guard"
cmp -s "$launcher" "$refresh_payload" || {
  echo "FAIL: launcher was not atomically replaced" >&2
  exit 1
}

echo "updater source config smoke ok"
