#!/usr/bin/env bash
# Только mock пакетных менеджеров: тест ничего не устанавливает.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/youtube_media.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for mode in installed install retry fail updatefail apk apt none; do
    (
        ready="$tmp/$mode.ready"; calls="$tmp/$mode.calls"
        : > "$calls"
        [ "$mode" != installed ] || touch "$ready"
        command() {
            case "$*" in
                '-v jq') test -f "$ready" ;;
                '-v opkg') case "$mode" in install|retry|fail|updatefail) return 0 ;; *) return 1 ;; esac ;;
                '-v apk') test "$mode" = apk ;;
                '-v apt-get') test "$mode" = apt ;;
                *) builtin command "$@" ;;
            esac
        }
        package() {
            echo "$*" >> "$calls"
            echo 'mock package manager output'
            case "$mode:$1" in
                updatefail:*) return 1 ;;
                *:update) return 0 ;;
                fail:*) return 1 ;;
                retry:install)
                    if [ ! -f "$tmp/attempt" ]; then touch "$tmp/attempt"; return 1; fi ;;
            esac
            touch "$ready"
        }
        opkg() { package "$@"; }
        apk() { package "$@"; }
        apt-get() { package "$@"; }
        rc=0
        z2r_media_install_jq > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
        test ! -s "$tmp/stdout"
        case "$mode" in
            fail|updatefail|none) test "$rc" = 1 ;;
            *) test "$rc" = 0 ;;
        esac
        case "$mode" in
            installed|none) test ! -s "$calls" ;;
            install) test "$(cat "$calls")" = 'install jq' ;;
            retry|fail) test "$(cat "$calls")" = $'install jq\nupdate\ninstall jq' ;;
            updatefail) test "$(cat "$calls")" = $'install jq\nupdate' ;;
            apk) test "$(cat "$calls")" = 'add jq' ;;
            apt) test "$(cat "$calls")" = 'install -y jq' ;;
        esac
    )
done
for answer in '' 0 1; do
    (
        command() { case "$*" in '-v jq') return 1 ;; *) builtin command "$@" ;; esac; }
        z2r_media_install_jq() { touch "$tmp/consented"; }
        rm -f "$tmp/consented"
        printf '%s\n' "$answer" | z2r_media_ask_jq > "$tmp/stdout" 2> "$tmp/stderr"
        test ! -s "$tmp/stdout"
        if [ "$answer" = 1 ]; then test -f "$tmp/consented"; else test ! -f "$tmp/consented"; fi
    )
done
# Неинтерактивный deploy не читает предложение и не устанавливает пакеты.
(
    export ZATOR_ROOT="$tmp/runtime" ZAPRET2_ROOT="$tmp/zapret"
    mkdir -p "$ZATOR_ROOT/z2r_lib" "$ZAPRET2_ROOT"
    touch "$ZAPRET2_ROOT/config"
    printf 'touch "%s"\n' "$tmp/deploy-prompted" > "$ZATOR_ROOT/z2r_lib/youtube_media.sh"
    source lib/deploy.sh
    deploy_offer_media_jq </dev/null
    test ! -e "$tmp/deploy-prompted"
)
# Старый deploy может иметь stdin=/dev/null; новый CLI спрашивает после exec с TTY.
python3 - <<'PY'
import os
import pathlib
import pty
import shlex
import subprocess
import tempfile

library = shlex.quote(str(pathlib.Path('lib/youtube_media.sh').resolve()))
for mode in ('missing', 'installed'):
    with tempfile.TemporaryDirectory() as root:
        cache = pathlib.Path(root) / 'extra_strats/cache'
        (cache / 'deploy').mkdir(parents=True)
        version = cache / 'deploy/version.env'
        version.write_text('ZATOR_SHA="first"\n')
        script = f'''
set -eu
export ZATOR_ROOT={shlex.quote(root)}
. {library}
command() {{
    case "$*" in '-v jq') test {mode} = installed ;; *) builtin command "$@" ;; esac
}}
z2r_media_install_jq() {{ echo installed >> "$ZATOR_ROOT/installs"; }}
z2r_media_offer_jq
z2r_media_offer_jq
printf 'ZATOR_SHA="second"\\n' > "$ZATOR_ROOT/extra_strats/cache/deploy/version.env"
z2r_media_offer_jq
'''
        result = subprocess.run(['bash', '-c', script], input='1\n', text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
        assert result.returncode == 0 and not result.stdout, result.stdout
        assert not (cache / 'jq-offer').exists()
        assert not (pathlib.Path(root) / 'installs').exists()
        version.write_text('ZATOR_SHA="first"\n')
        master, slave = pty.openpty()
        try:
            os.write(master, b'\n1\n')
            result = subprocess.run(['bash', '-c', script], stdin=slave, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
        finally:
            os.close(master)
            os.close(slave)
        assert result.returncode == 0, result.stdout
        if mode == 'missing':
            assert result.stdout.count('Установить jq') == 2, result.stdout
            assert (cache / 'jq-offer').read_text() == 'second\n'
            assert (pathlib.Path(root) / 'installs').read_text() == 'installed\n'
        else:
            assert not result.stdout and not (cache / 'jq-offer').exists()
assert sum(line.strip() == 'z2r_media_offer_jq' for line in pathlib.Path('z2r.sh').read_text().splitlines()) == 2
PY

echo 'youtube media install smoke ok'
