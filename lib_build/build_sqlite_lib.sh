#!/usr/bin/env bash
#
# build_sqlite_lib.sh: build the static libsqlite3.a this package links against.
#
# Expects an extracted sqlite-autoconf-XXXXXXX tree from sqlite.org (the
# amalgamation package: sqlite3.c, sqlite3.h and a configure script). It does
# not download anything.
#
# Usage, from the package root:
#   ./lib_build/build_sqlite_lib.sh /path/to/sqlite-autoconf-XXXXXXX
#   SQLITE_SRC_DIR=/path/to/sqlite-autoconf-XXXXXXX ./lib_build/build_sqlite_lib.sh
#
# Environment:
#   CC           C compiler (default: clang). Its path and version are printed
#                first so a different compiler earlier on PATH is easy to spot.
#   OUTPUT_DIR   Where to put libsqlite3.a (default: the package root, where
#                bindings.odin expects it).
#   SKIP_VERIFY  Set to 1 to skip the compile_options check.
#
# The check compiles check_opts.c (shared with build_sqlite_lib.bat) against
# the new library and confirms the expected options are actually compiled in.

set -euo pipefail

# --- source directory ---------------------------------------------------------

SQLITE_SRC_DIR="${1:-${SQLITE_SRC_DIR:-}}"

if [[ -z "$SQLITE_SRC_DIR" ]]; then
	echo "error: no SQLite source directory given." >&2
	echo "usage: $0 /path/to/sqlite-autoconf-XXXXXXX" >&2
	echo "   or: SQLITE_SRC_DIR=/path/to/sqlite-autoconf-XXXXXXX $0" >&2
	exit 1
fi

if [[ ! -d "$SQLITE_SRC_DIR" ]]; then
	echo "error: '$SQLITE_SRC_DIR' is not a directory." >&2
	exit 1
fi

if [[ ! -f "$SQLITE_SRC_DIR/configure" || ! -f "$SQLITE_SRC_DIR/sqlite3.c" ]]; then
	echo "error: '$SQLITE_SRC_DIR' doesn't look like an extracted sqlite-autoconf" >&2
	echo "       tree; expected 'configure' and 'sqlite3.c' directly inside it." >&2
	exit 1
fi

SQLITE_SRC_DIR="$(cd "$SQLITE_SRC_DIR" && pwd)"

# --- output location ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
mkdir -p "$OUTPUT_DIR"

# --- toolchain ------------------------------------------------------------------

CC="${CC:-clang}"

CC_PATH="$(command -v "$CC" || true)"
if [[ -z "$CC_PATH" ]]; then
	echo "error: '$CC' not found on \$PATH." >&2
	exit 1
fi

echo "== Toolchain =="
echo "CC         : $CC"
echo "resolves to: $CC_PATH"
"$CC" --version | head -1
echo

# --- build ------------------------------------------------------------------------

echo "== Building in $SQLITE_SRC_DIR =="
cd "$SQLITE_SRC_DIR"

# OMIT_* trims unused subsystems (see bindings.odin). DQS=0 and
# DEFAULT_FOREIGN_KEYS=1 match what open() configures on every connection,
# so other code linking this library gets the same behavior.
CFLAGS="-O2 \
  -DSQLITE_OMIT_DEPRECATED \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_OMIT_JSON \
  -DSQLITE_OMIT_GEOPOLY \
  -DSQLITE_OMIT_PROGRESS_CALLBACK \
  -DSQLITE_OMIT_AUTOINIT \
  -DSQLITE_DQS=0 \
  -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
  -ffunction-sections -fdata-sections"

CC="$CC" CFLAGS="$CFLAGS" ./configure --disable-shared --enable-static

# Clears objects from any earlier build with different flags.
make clean
make

# --- locate the archive -----------------------------------------------------------

# Older autotools trees put the archive in .libs/; newer ones at the top level.
BUILT_LIB=""
for candidate in ".libs/libsqlite3.a" "libsqlite3.a"; do
	if [[ -f "$candidate" ]]; then
		BUILT_LIB="$SQLITE_SRC_DIR/$candidate"
		break
	fi
done

if [[ -z "$BUILT_LIB" ]]; then
	echo "error: build finished but no libsqlite3.a found in" >&2
	echo "       '$SQLITE_SRC_DIR' or '$SQLITE_SRC_DIR/.libs'." >&2
	exit 1
fi

echo
echo "== Built: $BUILT_LIB =="
ls -la "$BUILT_LIB"

# --- verify -----------------------------------------------------------------------
#
# Neither configure's summary nor the sqlite3 shell's PRAGMA compile_options
# reflects what is in the library itself (the shell adds its own options),
# so link a small probe against the archive and ask it directly.

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
	echo
	echo "== Verifying compile_options against the built library =="

	if [[ ! -f "$SCRIPT_DIR/check_opts.c" ]]; then
		echo "error: check_opts.c not found at $SCRIPT_DIR/check_opts.c." >&2
		exit 1
	fi

	PROBE_DIR="$(mktemp -d)"
	trap 'rm -rf "$PROBE_DIR"' EXIT

	"$CC" "$SCRIPT_DIR/check_opts.c" -I"$SQLITE_SRC_DIR" "$BUILT_LIB" \
		-lpthread -ldl -lm -o "$PROBE_DIR/check_opts"

	ACTUAL_OPTS="$("$PROBE_DIR/check_opts")"

	echo "Actual compile_options from the built library:"
	while IFS= read -r line; do
		printf '  %s\n' "$line"
	done <<< "$ACTUAL_OPTS"
	echo

	# Only the on/off choices this build makes; DEFAULT_* and MAX_* values
	# vary between SQLite versions.
	EXPECT_PRESENT=(OMIT_DEPRECATED OMIT_LOAD_EXTENSION OMIT_JSON OMIT_PROGRESS_CALLBACK OMIT_AUTOINIT DQS=0 DEFAULT_FOREIGN_KEYS)
	EXPECT_ABSENT=(ENABLE_RTREE ENABLE_FTS3 ENABLE_FTS4 ENABLE_DBSTAT_VTAB HAVE_ZLIB)

	FAILED=0

	for opt in "${EXPECT_PRESENT[@]}"; do
		if ! grep -q "^${opt}" <<< "$ACTUAL_OPTS"; then
			echo "  MISSING expected option: $opt" >&2
			FAILED=1
		fi
	done

	for opt in "${EXPECT_ABSENT[@]}"; do
		if grep -q "^${opt}" <<< "$ACTUAL_OPTS"; then
			echo "  UNEXPECTEDLY PRESENT: $opt" >&2
			FAILED=1
		fi
	done

	if [[ "$FAILED" -eq 1 ]]; then
		echo >&2
		echo "error: the built library's compile_options (listed above) don't match" >&2
		echo "       what this script is supposed to produce." >&2
		exit 1
	fi

	echo "  OK: expected options present, excluded subsystems absent."
fi

# --- install ----------------------------------------------------------------------

cp "$BUILT_LIB" "$OUTPUT_DIR/libsqlite3.a"
echo
echo "== Installed =="
ls -la "$OUTPUT_DIR/libsqlite3.a"
