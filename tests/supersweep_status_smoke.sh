#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_DIR="$TMP/orchestra" Z2R_SUPERSWEEP_DIR="$TMP/run" Z2R_SUPERSWEEP_ARCHIVE_DIR="$TMP/history"
source lib/supersweep.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
type supersweep_report_json >/dev/null 2>&1 || fail 'missing shared supersweep report reader'
supersweep_report_json > "$TMP/report.json"
python3 - "$TMP/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='idle' and not r['available'] and not r['active']
assert r['workers']==[] and r['applied']==[] and r['domains']==[]
PY
mkdir -p "$Z2R_SUPERSWEEP_DIR" "$Z2R_SUPERSWEEP_DIR.lock"
printf '%s\n' "$$" > "$Z2R_SUPERSWEEP_DIR.lock/pid"
printf 'state=running\nstarted=100\nupdated=200\nscope=mark:5\nalive=yt\ndomains=a.com b.com\n' > "$Z2R_SUPERSWEEP_DIR/status"
printf 'yt\tyt\tprofile\t1\thttps://example.org/"x\t2\ngv\tgv\tprofile\t2\thttps://video.org/\t2\nds\tds\tprofile\t4\thttps://discord.com/\t2\nrkn\tRKN\trkn\t3\ta.com,b.com\t2\n' > "$Z2R_SUPERSWEEP_DIR/workers.tsv"
printf '100\t1\t1\tok\tok\tok\t64\t0.1\tok\n101\t1\t2\twarn\ttimeout\tok\t64\t0.1\twarn\n123\tpartial\t9' > "$Z2R_SUPERSWEEP_DIR/progress.yt.tsv"
printf 'r|2\nprofile|1|tls|2\n' > "$Z2R_SUPERSWEEP_DIR/applied.yt"
printf 'greens=1\nwarns=2\nbest=2\nbest_kind=warn\n' > "$Z2R_SUPERSWEEP_DIR/best.yt"
printf 'profile\t1\t1\ndomain\ta.com\t1\n' > "$Z2R_SUPERSWEEP_DIR/applied.tsv"
printf '100\ta.com\t1\tok\t0.1\t10\tok\n100\tb.com\t2\twarn\t0.1\t5\twarn\n' > "$Z2R_SUPERSWEEP_DIR/coverage.tsv"
supersweep_report_json > "$TMP/report.json"
python3 - "$TMP/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['available'] and r['active'] and r['state']=='running'
assert r['scope']=='mark:5' and r['phase']=='yt' and r['started']==100
w=r['workers'][0]
assert w['completed']==2 and w['ok']==1 and w['warn']==1 and w['fail']==0
assert w['current_strategy']==2 and w['current_target']=='https://example.org/"x'
assert w['applied']=='1' and w['greens']=='1' and w['warns']=='2'
assert r['completed']==2 and r['total']==sum(w['total'] for w in r['workers'])
domains={d['domain']:d for d in r['domains']}
assert domains['a.com']['applied']==1
assert domains['b.com']['best_strategy']==2 and domains['b.com']['applied'] is None
assert domains['b.com']['verdict']=='warn'
PY
rm -f "$Z2R_SUPERSWEEP_DIR.lock/pid"
supersweep_report_json > "$TMP/stale.json"
python3 - "$TMP/stale.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='interrupted' and not r['active']
PY
printf 'state=done\nstarted=100\nupdated=300\nscope=mark:5\nalive=\n' > "$Z2R_SUPERSWEEP_DIR/status"
type supersweep_report_save >/dev/null 2>&1 || fail 'missing persistent last report'
supersweep_report_save
rm -rf "$Z2R_SUPERSWEEP_DIR" "$Z2R_SUPERSWEEP_DIR.lock"
supersweep_report_json > "$TMP/saved.json"
python3 - "$TMP/saved.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['available'] and r['state']=='done' and not r['active'] and r['source']=='saved'
assert r['scope']=='mark:5' and r['completed']==2 and r['updated']==300
assert len(r['applied'])==2 and len(r['domains'])==2
PY
type supersweep_report_cli >/dev/null 2>&1 || fail 'missing CLI report'
supersweep_report_cli > "$TMP/cli.txt"
grep -q 'Всего: 2/' "$TMP/cli.txt"
grep -q 'Применено: профиль 1, стратегия 1' "$TMP/cli.txt"
! grep -q 'Применено: профиль 1, стратегия 2' "$TMP/cli.txt"
grep -q 'api_supersweep_get' webui/cgi-bin/settings.cgi || fail 'missing read-only CGI route'
source <(sed -n '/^send_json() {$/,/^}$/p' webui/cgi-bin/_lib.sh)
source <(sed -n '/^api_supersweep_get() {$/,/^}$/p' webui/cgi-bin/_lib.sh)
api_supersweep_get > "$TMP/cgi.txt"
python3 - "$TMP/cgi.txt" <<'PY'
import json,sys
headers,body=open(sys.argv[1]).read().split('\n\n',1)
assert 'Cache-Control: no-store' in headers
r=json.loads(body)
assert r['state']=='done' and r['source']=='saved'
PY
printf 'supersweep status smoke ok\n'
