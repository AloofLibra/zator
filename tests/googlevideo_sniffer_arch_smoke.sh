#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/googlevideo_ips.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export Z2R_GV_CPUINFO="$tmp/cpuinfo"
MOCK_UNAME=""
uname() { printf '%s\n' "$MOCK_UNAME"; }
check() {
  MOCK_UNAME="$1"
  printf '%s\n' "$2" > "$Z2R_GV_CPUINFO"
  got="$(googlevideo_sniffer_arch)"
  [ "$got" = "$3" ] || { echo "$1: expected $3, got $got" >&2; exit 1; }
}
check aarch64 '' arm64
check armv7l '' arm
check mips64 '' mips64
check mipsel 'system type : Lexra 5281' lexra
check mipsel 'system type : MIPS 24Kc' mipselsf
check mips 'system type : MIPS 24Kc' mipssf
check powerpc '' ppc
check i686 '' x86
check x86_64 '' x86_64
check riscv64 '' riscv64
googlevideo_local_collection_supported VPS
googlevideo_local_collection_supported WRT
googlevideo_local_collection_supported entware
if googlevideo_local_collection_supported merlin; then echo 'unsupported local collector platform accepted' >&2; exit 1; fi
MOCK_UNAME=loongarch64
if googlevideo_sniffer_arch >/dev/null; then echo 'unsupported architecture accepted' >&2; exit 1; fi
echo 'Googlevideo sniffer architecture mapping smoke ok'
