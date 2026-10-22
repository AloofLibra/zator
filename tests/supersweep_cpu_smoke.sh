#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/netcheck.sh
source lib/supersweep.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ "${1:-all}" != priority ]; then
v12='0|200|HTTP/2|0.123|192.0.2.1'
v13='0|404|HTTP/2|0.234|192.0.2.1'
dl='0|206|65536|0.500'
green=G yellow=Y red=R plain=P
exec 9> "$TMP/trace"
BASH_XTRACEFD=9
PS4='+${BASHPID} '
parent=$BASHPID
set -x
_supersweep_progress_row 1700000000 2 7 warn "$v12" "$v13" "$dl" 'данные идут' > "$TMP/row"
_supersweep_print_line gv '' 7 warn "$v12" "$v13" 'данные идут' > "$TMP/line"
set +x
unset BASH_XTRACEFD
python3 - "$TMP" "$parent" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
row=p.joinpath('row').read_text()
assert row=='1700000000\t2\t7\twarn\tok\thttp\t65536\t0.500\tданные идут\n',row
line=p.joinpath('line').read_text()
assert 'WARN' in line and 'tls1.2 OK 0.1с' in line and 'tls1.3 404 0.2с' in line,line
trace=p.joinpath('trace').read_text()
pids=set(re.findall(r'^\++(\d+) ',trace,re.M))
assert pids=={sys.argv[2]},f'hot renderer created subprocesses: {len(pids)-1}'
assert not re.search(r'^\++\d+ (?:cut|sed|date) ',trace,re.M)
print('supersweep CPU smoke ok: exact progress, log badges, zero renderer subprocesses')
PY
fi
type _supersweep_worker_priority >/dev/null 2>&1 || { echo 'FAIL: missing background-worker priority' >&2; exit 1; }
renice() { printf '%s\n' "$@" > "$TMP/renice"; }
Z2R_SUPERSWEEP_ISOLATED=0
_supersweep_worker_priority
[ ! -e "$TMP/renice" ]
Z2R_SUPERSWEEP_ISOLATED=1
parent=$BASHPID
(_supersweep_worker_priority)
python3 - "$TMP/renice" "$parent" <<'PY'
import pathlib,sys
args=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert args[:2]==['10','-p'] and args[2].isdigit() and args[2]!=sys.argv[2],args
print('supersweep priority smoke ok: detached worker only, never parent')
PY
