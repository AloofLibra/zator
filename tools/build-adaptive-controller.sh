#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/tools/adaptive_controller.c"
OUT_DIR=${OUT_DIR:-${TMPDIR:-/tmp}/zator-adaptive-controller}
TARGETS="aarch64-unknown-linux-musl armv6-unknown-linux-musleabi i586-unknown-linux-musl x86_64-unknown-linux-musl mips-unknown-linux-muslsf mipsel-unknown-linux-muslsf mips64-unknown-linux-musl mips64el-unknown-linux-musl powerpc-unknown-linux-musl riscv64-unknown-linux-musl"

usage() {
  echo "Usage: $0 [all|host|<Linux target triple>]"
  echo "Set CC for host builds and OUT_DIR to choose the output directory."
}

build_one() {
  target=$1
  flags=
  case "$target" in
    host) compiler=${CC:-cc} ;;
    armv6-unknown-linux-musleabi)
      compiler=$target-gcc
      flags="-mthumb -msoft-float"
      ;;
    aarch64-unknown-linux-musl|i586-unknown-linux-musl|x86_64-unknown-linux-musl|\
    mips-unknown-linux-muslsf|mipsel-unknown-linux-muslsf|\
    mips64-unknown-linux-musl|mips64el-unknown-linux-musl|\
    powerpc-unknown-linux-musl|riscv64-unknown-linux-musl)
      compiler=$target-gcc
      ;;
    *)
      echo "Unsupported target: $target" >&2
      return 2
      ;;
  esac
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "Compiler not found: $compiler" >&2
    return 1
  fi
  # CFLAGS/LDFLAGS intentionally accept conventional whitespace-separated flags.
  # shellcheck disable=SC2086
  $compiler $flags ${CFLAGS:-} -std=c99 -Os -flto -s -Wall -Wextra -Werror \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -ffunction-sections -fdata-sections "$SOURCE" \
    ${LDFLAGS:-} -Wl,--gc-sections -static -o "$OUT_DIR/adaptive-controller-$target"
  echo "built $OUT_DIR/adaptive-controller-$target"
}

mkdir -p "$OUT_DIR"
[ "$#" -le 1 ] || { usage >&2; exit 2; }
target=${1:-all}
case "$target" in
  -h|--help) usage; exit 0 ;;
  all)
    for item in $TARGETS; do build_one "$item"; done
    ;;
  *) build_one "$target" ;;
esac
