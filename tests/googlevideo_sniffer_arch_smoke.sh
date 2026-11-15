#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/googlevideo_ips.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export Z2R_GV_CPUINFO="$tmp/cpuinfo"
export Z2R_GV_ELF_FILE="$tmp/busybox"
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
printf '\177ELF\001\001' > "$Z2R_GV_ELF_FILE"
check mips 'system type : MediaTek MT7621 SoC' mipselsf
printf '\177ELF\001\002' > "$Z2R_GV_ELF_FILE"
check mips 'system type : MIPS 24Kc' mipssf

# A mislabeled beta asset must be replaced before the listener tries to exec it.
export ZATOR_ROOT="$tmp/zator"
mkdir -p "$ZATOR_ROOT/tools/bin"
cp "$Z2R_GV_ELF_FILE" "$ZATOR_ROOT/tools/bin/googlevideo-dns-sniffer"
chmod +x "$ZATOR_ROOT/tools/bin/googlevideo-dns-sniffer"
if googlevideo_sniffer_binary_matches_arch mipselsf; then echo 'big-endian MIPS binary accepted for MT7621' >&2; exit 1; fi
printf '\177ELF\001\001' > "$tmp/little-endian"
printf '\177ELF\001\001' > "$Z2R_GV_ELF_FILE"
chmod +x "$tmp/little-endian"
googlevideo_sniffer_binary_matches_arch mipselsf "$tmp/little-endian"
googlevideo_sniffer_install() {
  cp "$tmp/little-endian" "$ZATOR_ROOT/tools/bin/googlevideo-dns-sniffer"
  chmod +x "$ZATOR_ROOT/tools/bin/googlevideo-dns-sniffer"
}
googlevideo_sniffer_ensure_installed
googlevideo_sniffer_binary_matches_arch mipselsf
check powerpc '' ppc
check i686 '' x86
check x86_64 '' x86_64
check riscv64 '' riscv64

# Keenetic/Entware: uname says plain "mips" and the old probe hardcoded
# /bin/busybox (absent on Entware — the install silently no-op'd). The fix:
# a candidate list (/proc/self/exe first, Entware paths included) plus an
# opkg layer. The cascade answer for a little-endian board is platform-
# independent (on Linux /proc/self/exe decides, elsewhere the loud default).
unset Z2R_GV_ELF_FILE
check mips 'system type : MediaTek MT7621 SoC' mipselsf

# Deterministic opkg layer: suppress the ELF probe entirely.
gv_elf_endian_real="$(declare -f googlevideo_sniffer_elf_endian)"
googlevideo_sniffer_elf_endian() { return 1; }
opkg() { printf 'arch all 100\narch mipsel-3.4 150\narch mipsel-3.4_kn 200\n'; }
check mips 'system type : MediaTek MT7621 SoC' mipselsf
opkg() { printf 'arch all 100\narch mips-3.4 150\n'; }
check mips 'system type : MIPS 24Kc' mipssf
# No ELF evidence and no opkg: last-resort guess is little-endian, loudly.
opkg() { return 127; }
got="$(googlevideo_sniffer_arch 2>"$tmp/warn")"
[ "$got" = mipselsf ] || { echo "no-evidence fallback: expected mipselsf, got $got" >&2; exit 1; }
grep -q 'endianness not detected' "$tmp/warn" || { echo 'no-evidence fallback must warn on stderr' >&2; exit 1; }
unset -f opkg
eval "$gv_elf_endian_real"
# The explicit-argument probe stays authoritative: an unreadable file is an
# error, not a platform fallback to the running interpreter.
if googlevideo_sniffer_elf_endian "$tmp/absent" >/dev/null 2>&1; then echo 'unreadable explicit ELF accepted' >&2; exit 1; fi

# Core tar updates restore the platform startup hook, including the SysV path
# used by VPS; repeated deployment remains an overwrite, not an extra hook.
export ZAPRET2_ROOT="$tmp/zapret2" OSystem=VPS
mkdir -p "$ZATOR_ROOT/tools" "$ZAPRET2_ROOT/init.d/sysv"
cp "$ROOT/tools/wssize-ramp-firewall.sh" "$ZATOR_ROOT/tools/wssize-ramp-firewall.sh"
googlevideo_listener_hook_install
hook="$ZAPRET2_ROOT/init.d/sysv/custom.d/90-z2r-wssize-ramp.sh"
[ -x "$hook" ] && cmp -s "$hook" "$ROOT/tools/wssize-ramp-firewall.sh"
googlevideo_listener_hook_install
[ "$(find "$ZAPRET2_ROOT/init.d/sysv/custom.d" -maxdepth 1 -type f -name '90-z2r-wssize-ramp.sh' | wc -l | tr -d ' ')" = 1 ]
OSystem=WRT
mkdir -p "$ZAPRET2_ROOT/init.d/openwrt"
googlevideo_listener_hook_install
[ -x "$ZAPRET2_ROOT/init.d/openwrt/custom.d/90-z2r-wssize-ramp.sh" ]
unset OSystem
printf '#!/bin/sh\nexit 0\n' > "$ZAPRET2_ROOT/init.d/sysv/zapret2"
chmod +x "$ZAPRET2_ROOT/init.d/sysv/zapret2"
googlevideo_listener_hook_install
[ -x "$ZAPRET2_ROOT/init.d/sysv/custom.d/90-z2r-wssize-ramp.sh" ]
cmp -s "$ZAPRET2_ROOT/init.d/sysv/custom.d/90-z2r-wssize-ramp.sh" "$ROOT/tools/wssize-ramp-firewall.sh"

MOCK_UNAME=loongarch64
if googlevideo_sniffer_arch >/dev/null; then echo 'unsupported architecture accepted' >&2; exit 1; fi
echo 'Googlevideo sniffer architecture mapping smoke ok'
