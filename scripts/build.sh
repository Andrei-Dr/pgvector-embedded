#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Builds one pgvector archive for an embedded PostgreSQL: stock pgvector compiled against the
# exact theseus-rs/postgresql-binaries build that postgresql_embedded installs, zipped in
# PortalCorp's layout (`lib/vector.<so|dylib>`, `share/extension/vector.control` and
# `vector--*.sql`), plus pgvector's LICENSE and a BUILD-INFO.txt at the root.
#
#   scripts/build.sh <pgvector-version> <postgresql-version> <target> <outdir>
#   scripts/build.sh 0.8.7 17.11.1 x86_64-unknown-linux-musl dist
#
# <postgresql-version> is the theseus release (17.11.1 is PostgreSQL 17.11, theseus build 1).
# Writes <outdir>/pgvector-<pgvector-version>-pg<major>-<target>.zip.
#
# Targets: aarch64-apple-darwin (native, on a macOS arm64 host with the Xcode command line
# tools); x86_64-unknown-linux-gnu and aarch64-unknown-linux-gnu (in a digest-pinned
# debian:bookworm-slim, the distribution theseus builds its glibc servers on, so the module
# needs no newer glibc than the server); x86_64-unknown-linux-musl and aarch64-unknown-linux-musl
# (in a digest-pinned alpine:3.22, against theseus's musl servers). The linux targets run under
# `docker run --platform`, natively on a host of the same architecture, emulated otherwise.
#
# Fail closed on inputs: the pgvector source tarball and the theseus archive must be listed in
# inputs.sha256 at the repository root (`<sha256>  <file name>`); an unlisted or mismatching
# download stops the build and prints the line to review and add.
#
# Reproducible: pgvector's -march=native is off (OPTFLAGS=""), the build directory is mapped out
# of the objects, the zip has fixed timestamps, modes and member order. The linux targets give
# the same bytes on any host (pinned image, pinned inputs); aarch64-apple-darwin depends on the
# host's Xcode toolchain, which BUILD-INFO.txt records.
set -eu

# per-platform manifests of debian:bookworm-slim and alpine:3.22 (pinning the multi-arch index
# trips `docker: cannot overwrite digest` on hosts that hold the index for another platform)
DEBIAN_AMD64=debian@sha256:ec31d744f83f4a73447ba045aaab9409997efe5cc706eca4890c1be36cc1606a
DEBIAN_ARM64=debian@sha256:991827bb788d78bbc130dcb851913beecff43296360f48838aca7cbdfae4375c
ALPINE_AMD64=alpine@sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec
ALPINE_ARM64=alpine@sha256:3e07a4f627d12468155eb812785e10f2453a447c346872b47788a62437366764
# 2000-01-01T00:00:00Z: the timestamp of every file in the zip
FIXED_TOUCH=200001010000.00

usage() {
  echo "usage: scripts/build.sh <pgvector-version> <postgresql-version> <target> <outdir>" >&2
  exit 2
}
die() { echo "build: $*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <file> <inputs.sha256>: download once, then require the file's listed digest
fetch() {
  name=$(basename "$2")
  if [ ! -f "$2" ]; then
    curl -fsSL --retry 3 -o "$2.part" "$1" || die "download failed: $1"
    mv "$2.part" "$2"
  fi
  got=$(sha256_of "$2")
  want=$(awk -v n="$name" '$2 == n { print $1 }' "$3")
  if [ -z "$want" ]; then
    die "$name is not in inputs.sha256; review the download, then add:
$got  $name"
  fi
  [ "$got" = "$want" ] || die "$name: sha256 $got, inputs.sha256 lists $want"
}

dlsuffix_of() {
  case "$1" in
    *-apple-darwin) echo dylib ;;
    *-unknown-linux-gnu | *-unknown-linux-musl) echo so ;;
    *) die "unsupported target $1" ;;
  esac
}

# build <pgvector> <postgresql> <target> <workdir> <outdir> <inputs.sha256> <built-in>
build() {
  pgv=$1 pg=$2 target=$3 work=$4 out=$5 inputs=$6 built_in=$7
  major=${pg%%.*}
  dlsuffix=$(dlsuffix_of "$target")
  mkdir -p "$work"
  pg_archive="postgresql-${pg}-${target}.tar.gz"
  src_archive="pgvector-${pgv}.tar.gz"
  fetch "https://github.com/theseus-rs/postgresql-binaries/releases/download/${pg}/${pg_archive}" \
    "$work/$pg_archive" "$inputs"
  fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${pgv}.tar.gz" \
    "$work/$src_archive" "$inputs"

  rm -rf "$work/pg" "$work/src" "$work/stage"
  mkdir -p "$work/pg" "$work/src" "$work/stage/lib" "$work/stage/share/extension"
  tar -xzf "$work/$pg_archive" -C "$work/pg" --strip-components=1
  tar -xzf "$work/$src_archive" -C "$work/src" --strip-components=1

  src=$(cd "$work/src" && pwd)
  # the work directory (as given and resolved: macOS /tmp is /private/tmp) maps to `build`, so
  # neither the source nor the server headers' paths (their assertions' __FILE__) vary by host
  real=$(cd "$work" && pwd -P)
  # with_llvm=no: no bitcode (the server's JIT is optional, and the archive's clang path is the
  # builder's). PG_SYSROOT: the archive records its builder's SDK path; use this host's.
  set -- OPTFLAGS= with_llvm=no "PG_CONFIG=$work/pg/bin/pg_config" \
    "PG_CFLAGS=-ffile-prefix-map=$real=build -ffile-prefix-map=$(cd "$work" && pwd)=build"
  case "$target" in
    *-apple-darwin) set -- "$@" "PG_SYSROOT=$(xcrun --show-sdk-path)" ;;
  esac
  make -C "$src" -s "$@" >/dev/null || die "make failed for $target"

  [ -f "$src/sql/vector--${pgv}.sql" ] || die "make did not produce sql/vector--${pgv}.sql"
  grep -q "default_version = '${pgv}'" "$src/vector.control" || die "vector.control does not name ${pgv}"
  cp "$src/vector.$dlsuffix" "$work/stage/lib/"
  cp "$src/vector.control" "$work/stage/share/extension/"
  for sql in "$src"/sql/vector--*.sql; do cp "$sql" "$work/stage/share/extension/"; done
  # the PostgreSQL License asks for its notice in every copy; postgresql_extensions skips files
  # that are not a library, a control file or SQL, so these two never land in the server
  cp "$src/LICENSE" "$work/stage/LICENSE"
  {
    echo "pgvector ${pgv}: https://github.com/pgvector/pgvector/tree/v${pgv}, source $src_archive sha256 $(sha256_of "$work/$src_archive")"
    echo "PostgreSQL ${pg} for ${target}: theseus-rs/postgresql-binaries $pg_archive sha256 $(sha256_of "$work/$pg_archive")"
    echo "built in: ${built_in}"
    echo "make OPTFLAGS= with_llvm=no (no -march=native; no LLVM bitcode)"
  } > "$work/stage/BUILD-INFO.txt"

  find "$work/stage" -type f -exec chmod 0644 {} +
  find "$work/stage" -type f -exec env TZ=UTC touch -t "$FIXED_TOUCH" {} +
  name="pgvector-${pgv}-pg${major}-${target}.zip"
  rm -f "$out/$name"
  (cd "$work/stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | TZ=UTC zip -q -X -D "$out/$name" -@) \
    || die "zip failed for $target"
  echo "$(sha256_of "$out/$name")  $name"
}

if [ "${1:-}" = "--inside" ]; then
  # the linux leg, inside its container: /src is the repository (read-only), /out the outdir
  [ $# -eq 5 ] || usage
  build "$2" "$3" "$4" /work /out /src/inputs.sha256 "$5"
  exit 0
fi

[ $# -eq 4 ] || usage
pgv=$1 pg=$2 target=$3
echo "$pgv" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "pgvector version $pgv is not x.y.z"
echo "$pg" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "postgresql version $pg is not x.y.z (a theseus release)"
mkdir -p "$4"
outdir=$(cd "$4" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)

case "$target" in
  aarch64-apple-darwin)
    [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] || die "$target builds natively on a macOS arm64 host"
    build "$pgv" "$pg" "$target" "$outdir/.work-$target" "$outdir" "$repo/inputs.sha256" \
      "macOS $(sw_vers -productVersion), $(cc --version | head -n 1)"
    ;;
  *-unknown-linux-gnu | *-unknown-linux-musl)
    command -v docker >/dev/null 2>&1 || die "$target builds under Docker"
    case "$target" in
      x86_64-*gnu) platform=linux/amd64 image=$DEBIAN_AMD64 ;;
      aarch64-*gnu) platform=linux/arm64 image=$DEBIAN_ARM64 ;;
      x86_64-*musl) platform=linux/amd64 image=$ALPINE_AMD64 ;;
      aarch64-*musl) platform=linux/arm64 image=$ALPINE_ARM64 ;;
      *) die "unsupported target $target" ;;
    esac
    case "$target" in
      *gnu) tools='apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
          ca-certificates curl gcc make zip libc6-dev >/dev/null' ;;
      *) tools='apk add -q --no-cache build-base curl zip ca-certificates' ;;
    esac
    docker run --rm --platform "$platform" -v "$repo:/src:ro" -v "$outdir:/out" "$image" \
      sh -c "set -e; $tools; sh /src/scripts/build.sh --inside $pgv $pg $target '$image'"
    ;;
  *) die "unsupported target $target (aarch64-apple-darwin, {x86_64,aarch64}-unknown-linux-{gnu,musl})" ;;
esac
