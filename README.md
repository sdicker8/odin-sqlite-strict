# odin-sqlite-strict

Odin bindings and a small, idiomatic wrapper for SQLite, statically linked
against a trimmed SQLite build.

"Strict" refers to the defaults. Every connection enforces foreign keys,
reports which kind of constraint failed, and treats double quotes as
identifier quotes only, so a mistyped column name is an error rather than
a string. The package also recommends `STRICT` tables, which make SQLite
check column types the way Odin checks variable types.

I used an AI assistant heavily on this project, but I reviewed and directed
every design decision and every line.

```odin
import sqlite "odin-sqlite-strict"

run :: proc() -> sqlite.Error {
	db := sqlite.open("app.db") or_return
	defer sqlite.close(&db)

	sqlite.execute(&db, `
		CREATE TABLE IF NOT EXISTS accounts (
			id      INTEGER PRIMARY KEY,
			name    TEXT NOT NULL,
			balance INTEGER NOT NULL CHECK (balance >= 0)
		) STRICT;
	`) or_return

	sqlite.execute(&db, "INSERT INTO accounts (name, balance) VALUES (?1, ?2);", {"Alice", 100}) or_return
	return .Ok
}
```

`example/main.odin` is a longer walkthrough with transactions, error
messages and row scanning.

## Contents

- `bindings.odin`: the foreign declarations, one to one with the C API
  subset this package uses.
- `sqlite.odin`: the wrapper (`DB`, `Stmt`, `Tx`, `Backup`, errors,
  execution, transactions, backup, WAL checkpoints, row scanning).
- `sqlite_test.odin`: the test suite.
- `example/`: a runnable example.
- `lib_build/`: scripts that build the SQLite library from source.

## Building

The package links a static SQLite library that you build once from the
SQLite amalgamation (the `sqlite-autoconf-XXXXXXX` download on sqlite.org):

```sh
./lib_build/build_sqlite_lib.sh /path/to/sqlite-autoconf-3530400
```

On Windows, run `lib_build\build_sqlite_lib.bat` with the source path from an
"x64 Native Tools Command Prompt for VS". Both scripts place the library
(`libsqlite3.a` or `sqlite3.lib`) in the package root, where `bindings.odin`
looks for it, and both confirm afterwards that the library was built with
the expected options.

The build leaves out deprecated APIs, extension loading, JSON, Geopoly and
the progress callback, and sets `SQLITE_DQS=0` and
`SQLITE_DEFAULT_FOREIGN_KEYS=1`.

Platform status:

- Linux: the test suite and example pass.
- Windows: supported through `build_sqlite_lib.bat`. Running the whole test
  suite in one process can hit an Odin test runner bug,
  [odin-lang/Odin#7035](https://github.com/odin-lang/Odin/issues/7035), when
  more than one `expect_assert` test is present; the tests pass individually.
- macOS: untested. `build_sqlite_lib.sh` uses nothing Linux specific, so it
  is expected to work.

### Using a different SQLite build

You can link any SQLite library in place of the one the scripts build, as
long as it meets two requirements:

- It is version 3.37.0 or newer. `open()` checks this and fails with a
  clear message otherwise.
- It exports every function declared in `bindings.odin`. A missing one shows
  up as a link error.

Foreign key enforcement and the double-quoted string setting do not depend
on how the library was built, because `open()` sets both on every
connection. If the library cannot honor them (for example, it was built with
`SQLITE_OMIT_FOREIGN_KEY`), `open()` fails rather than continuing without
them.

`SQLITE_THREADSAFE` is the one build option that changes what you may do;
see [Thread safety](#thread-safety). Other options, including
`SQLITE_OMIT_AUTOINIT`, make no difference to this package.

## Connections

`open(path, flags)` opens a database (`":memory:"` for an in-memory one) and
configures the connection:

- Extended result codes are enabled, so a failed constraint reports which
  kind it was.
- Foreign keys are enforced. `PRAGMA foreign_keys = OFF` turns enforcement
  off for a connection when you need to, during some migrations for example.
- Double quotes quote identifiers only. `"first name"` works as usual, but
  a double-quoted name that matches no column is an error instead of
  silently becoming a string.

`close` is safe to call on a connection that is already closed.

Statements, transactions and backups keep a pointer to their `DB`. Keep the
`DB` at a fixed address, such as a local in the proc that owns it or a field
of a struct that does not move, while any of them are alive.

## Errors

Every proc that can fail returns an `Error` as its last result. `Error.Ok` is
zero, so results compose with `or_return`:

```odin
stmt := sqlite.prepare(&db, "SELECT id FROM accounts;") or_return
```

`Error` holds SQLite's primary result codes plus one member per kind of
constraint failure (`.Constraint_Unique`, `.Constraint_Foreign_Key`,
`.Constraint_Not_Null` and so on). Other extended codes are folded into
their primary code, so a WAL snapshot conflict (`SQLITE_BUSY_SNAPSHOT`) is
`.Busy` and an fsync failure is `.IO_Err`. Every value you receive is a named
member, and a `switch` over `Error` can stay exhaustive.

For the detail, `extended_errcode(&db)` returns an `Extended_Error`, which
lists every primary and extended code in SQLite 3.53. `error_string(&db)`
returns the message. Both describe the most recent failure on that
connection, and a later successful call does not clear them. That matters
with transactions: the deferred `ROLLBACK` that cleans up after a failure
succeeds, but the message from the failure is still there afterwards.

```odin
if err := transfer(&db, from, to, amount); err != .Ok {
	msg := sqlite.error_string(&db)
	defer delete(msg)
	log.errorf("transfer failed: %v (%s)", err, msg)
}
```

Calling a proc on a `DB`, `Stmt` or `Backup` that was never opened, or has
been closed, returns `.Misuse` instead of passing a nil pointer to SQLite.
Procs that return a plain value return its zero value in that case.

Errors that come from using the API wrongly at runtime are returned. Errors
that can only come from code that does not match its query, such as a
`row_layout` struct field of an unsupported type, panic.

Procs whose result reports an error are marked `@(require_results)`, except
the cleanup procs (`close`, `finalize`, `reset`, `rollback`, `backup_finish`),
so they can be used with `defer`.

## Statements

```odin
stmt := sqlite.prepare(&db, "SELECT name, balance FROM accounts WHERE balance > ?1;") or_return
defer sqlite.finalize(&stmt)

sqlite.bind(&stmt, 1, 50) or_return
for {
	result := sqlite.step(&stmt) or_return
	if result == .Done do break

	name := sqlite.column_text(&stmt, 0)
	defer delete(name)
	balance := sqlite.column_int(&stmt, 1)
}
```

Parameter indices start at 1 and column indices at 0, as in SQLite. Keeping
them as SQLite defines them means the index in your Odin code matches the
`?1` in the SQL next to it.

`bind` is a procedure group over `bind_null`, `bind_int`, `bind_float`,
`bind_text` and `bind_bytes`. `bind_int64` is not in the group, because an
integer literal would match both it and `bind_int`; call it by name for a
value that is already an `i64`.

Text and blobs are bound with `SQLITE_TRANSIENT`, so SQLite copies them and
the value you pass does not need to outlive the call. An empty string or
empty slice binds an empty value, not NULL; bind NULL with `bind_null` or a
`nil` parameter.

`column_text`, `column_bytes` and `column_name` return copies that you own
and free with `delete`. SQLite's own buffers are only valid until the next
`step`, `reset` or `finalize`, and Odin cannot check that lifetime for you.
For hot loops, `column_text_unsafe` and `column_bytes_unsafe` return views
into SQLite's buffer without copying; never store or `delete` those.
`column_text` returns `""` and `column_bytes` returns `nil` for both NULL and
empty values; `column_is_null` tells them apart.

A single string or blob is limited by SQLite to 1 GB by default (the
`SQLITE_MAX_LENGTH` build option, which cannot exceed 2 GiB). Binding a
larger value returns `.Too_Big`. Store large files on disk and keep their
paths in the database. `limit(&db, .Length, n)` lowers the limit for a
connection.

## execute

`execute(&db, sql, params)` runs SQL for its side effects and returns only an
`Error`. Rows produced by the SQL, such as those from `RETURNING`, are
discarded, but the statement still runs to completion, so a multi-row
`UPDATE ... RETURNING` is fully applied.

Without parameters, `sql` can contain several statements separated by
semicolons. They run in order, and execution stops at the first error.
Statements before the failing one stay applied, so put the script inside a
transaction if it has to succeed or fail as a whole.

With parameters, `sql` must be a single statement, and the number of
parameters must equal the number of placeholders:

```odin
sqlite.execute(&db, "UPDATE accounts SET balance = balance + ?1 WHERE id = ?2;", {10, 2}) or_return
```

A second statement in the same string returns `.Misuse`, and a parameter
count that does not match returns `.Range`, in both cases before anything
runs. `execute` never lets an unbound placeholder silently become NULL,
including in the no-parameter form.

`Param` is a union of `int`, `f64`, `string`, `[]byte` and `bool`. `nil`
binds NULL and `bool` binds 0 or 1. There is no `i64` variant, for the same
reason `bind_int64` is outside `bind`.

## Transactions

```odin
tx := sqlite.begin(&db) or_return
defer sqlite.rollback(&tx)

sqlite.execute(&db, "UPDATE accounts SET balance = balance - 100 WHERE id = 1;") or_return
sqlite.execute(&db, "UPDATE accounts SET balance = balance + 100 WHERE id = 2;") or_return

sqlite.commit(&tx) or_return
```

The deferred `rollback` runs on every early return and does nothing once
`commit` has succeeded. If `begin` itself fails, the returned `Tx` is
already marked finished, so a deferred `rollback` cannot end some other
transaction that was open on the connection.

Nothing makes you write the `defer`. `with_transaction` removes that risk by
owning the whole sequence:

```odin
Transfer :: struct { from, to, amount: int }

transfer_body :: proc(tx: ^sqlite.Tx, user_data: rawptr) -> sqlite.Error {
	args := (^Transfer)(user_data)^
	sqlite.execute(tx.db, "UPDATE accounts SET balance = balance - ?1 WHERE id = ?2;", {args.amount, args.from}) or_return
	sqlite.execute(tx.db, "UPDATE accounts SET balance = balance + ?1 WHERE id = ?2;", {args.amount, args.to}) or_return
	return .Ok
}

args := Transfer{from = 1, to = 2, amount = 30}
sqlite.with_transaction(&db, transfer_body, &args) or_return
```

Odin procedures do not capture variables from the enclosing scope, so the
body receives its arguments through `user_data`. Transactions do not nest;
calling `begin` while one is open fails.

## Integers

SQLite stores integers as 64-bit values. `column_int`, `bind_int`, `changes`
and `total_changes` use Odin's `int`, which is 64 bits on every target this
package supports, and use SQLite's 64-bit C functions internally.
`column_int64`, `bind_int64`, `changes64` and `total_changes64` take or
return `i64` explicitly.

`STRICT` constrains a column's type, not its width: an `INTEGER` column
accepts any 64-bit value. Reading such a value into an `i32` would truncate
it without any error, so the package offers no 32-bit reads.

## Row scanning

`row_layout` and `scan_row` fill a struct from the current row by matching
column names to field names:

```odin
Account :: struct {
	id:      int,
	name:    string,
	balance: int,
}

layout := sqlite.row_layout(&stmt, Account)
defer delete(layout.fields)

for {
	result := sqlite.step(&stmt) or_return
	if result == .Done do break
	account := sqlite.scan_row(&stmt, layout, Account)
	defer delete(account.name)
}
```

`row_layout` matches names once per statement, and `scan_row` then writes
each row through precomputed offsets. Names must match exactly, including
case; alias columns in the SQL when they differ. Columns without a matching
field, and fields without a matching column, are skipped.

Supported field types are `int`, `i64`, `f64`, `string`, `[]byte` and
`bool`. `row_layout` panics if a matched field has any other type, or if two
result columns with the same name both match a field (typically an unaliased
join column). Both mean the struct does not fit the query, which is a bug to
fix rather than a runtime condition to handle.

Text and blob fields are allocated with the `allocator` argument, and the
caller frees them, along with `layout.fields`.

## Backup and WAL checkpoints

`backup(&dest, &source)` copies a whole database between two open
connections, for example to save an in-memory database to disk. It is safe
while the source is in use. For a large database, or to handle `.Busy` and
`.Locked` from a busy source yourself, use `backup_init`, `backup_step` and
`backup_finish`; `backup_remaining` and `backup_pagecount` report progress.

`wal_checkpoint(&db, mode, db_name)` forces a checkpoint on a database in WAL
mode. Some behavior to be aware of:

- In-memory databases cannot use WAL. `PRAGMA journal_mode = WAL` on one
  quietly stays in memory mode.
- On a database not in WAL mode, the call succeeds and reports `-1` for both
  frame counts. A WAL database with nothing to do reports `0`.
- `.Truncate` is the only mode that shrinks the WAL file.
- An empty `db_name` checkpoints every attached database. Pass `"main"` for
  only the primary one.

## Thread safety

The package adds no locking of its own. What is safe depends on the
`SQLITE_THREADSAFE` setting of the linked library; the build scripts print
it in the compile options.

- `THREADSAFE=1` (serialized, SQLite's default): a connection and its
  statements may be used from several threads.
- `THREADSAFE=2` (multi-thread): different connections may be used from
  different threads, but each connection from only one thread at a time.
- `THREADSAFE=0`: single-threaded only.

`error_string` and `extended_errcode` read state stored in the `DB`. When
several threads share a connection, a failure on one thread can overwrite
the message another thread is about to read, just as with SQLite's own
`sqlite3_errmsg`.

`interrupt` may be called from another thread to stop a running statement,
but not at the same time as `close`.

## Tests

After building the library, run `odin test .` from the package root. Most
tests either check SQLite behavior the package relies on, or guard against a
specific bug.

## Not covered

- Savepoints and nested transactions
- Incremental blob I/O (`sqlite3_blob_*`)
- User-defined SQL functions
- `sqlite3_config`, which must run before `sqlite3_initialize`; `open()`
  calls `sqlite3_initialize` itself
- A prepared statement cache

## License

zlib; see `LICENSE`. SQLite itself is in the public domain.
