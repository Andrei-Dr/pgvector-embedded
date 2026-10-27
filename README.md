# pgvector-embedded

Prebuilt [pgvector](https://github.com/pgvector/pgvector) for embedded PostgreSQL: stock
pgvector, compiled unmodified against the exact
[theseus-rs/postgresql-binaries](https://github.com/theseus-rs/postgresql-binaries) builds that
[postgresql_embedded](https://github.com/theseus-rs/postgresql-embedded) installs, packaged in
the zip layout of PortalCorp's `pgvector_compiled` (which stops at PostgreSQL 16).

## The archives

Each release is tagged `v<pgvector version>-pg<theseus PostgreSQL version>`, for example
`v0.8.7-pg17.11.1` (pgvector 0.8.7, PostgreSQL 17.11, theseus build 1), and holds one zip per
target plus `SHA256SUMS`:

| Target | Asset |
| --- | --- |
| `aarch64-apple-darwin` | `pgvector-0.8.7-pg17-aarch64-apple-darwin.zip` |
| `x86_64-unknown-linux-gnu` | `pgvector-0.8.7-pg17-x86_64-unknown-linux-gnu.zip` |
| `aarch64-unknown-linux-gnu` | `pgvector-0.8.7-pg17-aarch64-unknown-linux-gnu.zip` |
| `x86_64-unknown-linux-musl` | `pgvector-0.8.7-pg17-x86_64-unknown-linux-musl.zip` |
| `aarch64-unknown-linux-musl` | `pgvector-0.8.7-pg17-aarch64-unknown-linux-musl.zip` |

The target is the server's: a binary built for musl gets theseus's musl PostgreSQL from
postgresql_embedded, and only the musl archive loads into it.

Inside a zip:

```text
BUILD-INFO.txt                    versions, input sha256s, the build image or toolchain
LICENSE                           pgvector's (the PostgreSQL License)
lib/vector.so                     lib/vector.dylib on macOS
share/extension/vector.control
share/extension/vector--*.sql     the install script and every upgrade script
```

The module is built without `-march=native` and without LLVM bitcode, so it runs on any CPU of
the target architecture and needs no JIT.

## Verify

```sh
gh release download v0.8.7-pg17.11.1 -R Andrei-Dr/pgvector-embedded
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
```

The linux archives are reproducible: `scripts/build.sh` at the tag gives the same bytes on any
host with Docker (pinned image digests, pinned inputs in `inputs.sha256`). The macOS archive
depends on the Xcode toolchain of the machine that built it; its `BUILD-INFO.txt` names it.

## Use

With the server stopped, copy the library into the server's `pkglibdir` and the control and SQL
files into its `sharedir/extension`, then create the extension in each database:

```sh
unzip pgvector-0.8.7-pg17-x86_64-unknown-linux-gnu.zip -d pgvector
cp pgvector/lib/vector.* "$(pg_config --pkglibdir)/"
cp pgvector/share/extension/* "$(pg_config --sharedir)/extension/"
# start the server, then:
psql -c 'CREATE EXTENSION vector'
```

From Rust with postgresql_embedded: after `PostgreSQL::setup()` installs the server and before
`start()`, extract the archive the same way into the installation's `lib` and
`share/extension` (the directories `pg_config` reports for it). The zip has the layout
postgresql_extensions' PortalCorp installer expects (it maps `.so`/`.dylib` to the library
directory and `.control`/`.sql` to the extension directory, and skips the other files), and
the asset names carry `pg<major>` and the full target triple, which postgresql_extensions'
`zip_matcher` matches. Pin the sha256 from `SHA256SUMS` in your code and check the bytes
before installing them.

An archive works with the theseus build of the same PostgreSQL major it was compiled against;
the release tag names the exact build.

## Build

```sh
scripts/build.sh 0.8.7 17.11.1 x86_64-unknown-linux-musl dist
```

`scripts/build.sh <pgvector-version> <postgresql-version> <target> <outdir>` builds one target:
`aarch64-apple-darwin` natively on a macOS arm64 host, the linux targets under Docker
(`--platform` of the target's architecture; emulated on a host of the other one). Every input
must be listed in `inputs.sha256`; a new pgvector or PostgreSQL version starts with adding its
lines there (the script prints them on the first run and stops).

Releases are built by `.github/workflows/release.yml` on a pushed tag: each target on a runner
of its own architecture, then `SHA256SUMS` and the GitHub release.

## License

The scripts and workflows here are Apache-2.0 (`LICENSE`). The archives contain pgvector, under
the PostgreSQL License, with its LICENSE file in each zip; see `NOTICE`.
