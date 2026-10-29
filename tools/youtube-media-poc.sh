#!/bin/sh
# Независимый PoC: только shell/curl + jsonfilter или jq; никаких сервисов и firewall.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/lib/youtube_media.sh"
umask 077
dir=$(mktemp -d /tmp/zator-media-poc.XXXXXX) || exit 1
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if ! z2r_media_resolve "${1:-}" "$dir"; then
    printf 'resolver_status=%s\n' "$(cat "$dir/status")"
    exit 1
fi
# Только обезличенная метаинформация: подписанные ссылки не попадают в stdout.
cat "$dir/meta.json"
failed=0
for kind in audio video; do
    count=262144; [ "$kind" != video ] || count=1048576
    for middle in 0 1; do
        row=$(z2r_media_probe "$dir" "$kind" "$count" "$middle") || row='UNKNOWN|probe_error'
        printf '%s middle=%s %s\n' "$kind" "$middle" "$row"
        [ "${row%%|*}" = OK ] || failed=1
    done
done
exit "$failed"
