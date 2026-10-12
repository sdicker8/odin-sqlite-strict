package sqlite_strict

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

// Run with `odin test .` from the package root, after building the SQLite
// library (see README).

// --- Helpers -------------------------------------------------------------------

@(private)
must :: proc(t: ^testing.T, err: Error, loc := #caller_location) {
	testing.expect_value(t, err, Error.Ok, loc = loc)
}

@(private)
must_open_memory :: proc(t: ^testing.T, loc := #caller_location) -> DB {
	db, err := open(":memory:")
	testing.expect_value(t, err, Error.Ok, loc = loc)
	return db
}

@(private)
must_prepare :: proc(t: ^testing.T, db: ^DB, sql: string, loc := #caller_location) -> Stmt {
	stmt, err := prepare(db, sql)
	testing.expect_value(t, err, Error.Ok, loc = loc)
	return stmt
}

@(private)
must_step :: proc(t: ^testing.T, stmt: ^Stmt, loc := #caller_location) -> Step_Result {
	result, err := step(stmt)
	testing.expect_value(t, err, Error.Ok, loc = loc)
	return result
}

// query_int runs a query returning one integer, such as SELECT count(*).
@(private)
query_int :: proc(t: ^testing.T, db: ^DB, sql: string, loc := #caller_location) -> int {
	stmt := must_prepare(t, db, sql, loc)
	defer finalize(&stmt)
	testing.expect_value(t, must_step(t, &stmt, loc), Step_Result.Row, loc = loc)
	return column_int(&stmt, 0)
}

@(private)
_temp_file_counter: int

// open_temp_file_db opens a fresh file-backed database, for tests that need
// WAL mode or a second connection. Clean up with remove_temp_file_db after
// closing every connection to it.
@(private)
open_temp_file_db :: proc(t: ^testing.T) -> (db: DB, path: string) {
	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect_value(t, dir_err, nil)

	n := sync.atomic_add(&_temp_file_counter, 1)
	filename := fmt.tprintf("sqlite_strict_test_%d_%d.db", time.now()._nsec, n)
	path, _ = filepath.join({dir, filename})

	err: Error
	db, err = open(path)
	testing.expect_value(t, err, Error.Ok)
	return
}

// remove_temp_file_db deletes the database file and its WAL sidecars, and
// frees `path`.
@(private)
remove_temp_file_db :: proc(path: string) {
	os.remove(path)
	os.remove(fmt.tprintf("%s-wal", path))
	os.remove(fmt.tprintf("%s-shm", path))
	delete(path)
}

// --- Open / close --------------------------------------------------------------------

@(test)
test_open_close :: proc(t: ^testing.T) {
	db, err := open(":memory:")
	testing.expect_value(t, err, Error.Ok)
	testing.expect(t, db.handle != nil)
	testing.expect_value(t, close(&db), Error.Ok)
	testing.expect(t, db.handle == nil)
}

@(test)
test_open_failure_records_message :: proc(t: ^testing.T) {
	db, err := open("/nonexistent-directory-for-sqlite-strict/x.db")
	testing.expect_value(t, err, Error.Cant_Open)
	testing.expect(t, db.handle == nil)

	msg := error_string(&db)
	defer delete(msg)
	testing.expect(t, len(msg) > 0, "open failure should record a message")
}

@(test)
test_open_enforces_foreign_keys :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, `
		CREATE TABLE parent (id INTEGER PRIMARY KEY) STRICT;
		CREATE TABLE child (parent_id INTEGER REFERENCES parent(id)) STRICT;
	`))

	err := execute(&db, "INSERT INTO child VALUES (999);")
	testing.expect_value(t, err, Error.Constraint_Foreign_Key)
}

@(test)
test_open_rejects_double_quoted_string_literals :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt, err := prepare(&db, `SELECT "no_such_column";`)
	defer finalize(&stmt)
	testing.expect_value(t, err, Error.Generic)
}

// --- Error codes -------------------------------------------------------------------

@(test)
test_to_error_folds_extended_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, _to_error(SQLITE_BUSY | (2 << 8)), Error.Busy)
	testing.expect_value(t, _to_error(SQLITE_IOERR | (1 << 8)), Error.IO_Err)
	testing.expect_value(t, _to_error(SQLITE_CONSTRAINT_UNIQUE), Error.Constraint_Unique)
	testing.expect_value(t, _to_error(SQLITE_CONSTRAINT), Error.Constraint)
	// A constraint subcode this package doesn't know about.
	testing.expect_value(t, _to_error(SQLITE_CONSTRAINT | (99 << 8)), Error.Constraint)
}

@(test)
test_not_null_violation_surfaces_extended_code :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER NOT NULL) STRICT;"))

	testing.expect_value(t, execute(&db, "INSERT INTO t (val) VALUES (NULL);"), Error.Constraint_Not_Null)
}

@(test)
test_unique_violation_surfaces_extended_code :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER UNIQUE) STRICT;"))
	must(t, execute(&db, "INSERT INTO t (val) VALUES (1);"))

	testing.expect_value(t, execute(&db, "INSERT INTO t (val) VALUES (1);"), Error.Constraint_Unique)
}

// A WAL reader whose snapshot is stale gets SQLITE_BUSY_SNAPSHOT when it
// tries to write. It must still compare equal to .Busy.
@(test)
test_busy_snapshot_is_busy :: proc(t: ^testing.T) {
	a, path := open_temp_file_db(t)
	defer remove_temp_file_db(path)
	defer close(&a)
	b, berr := open(path)
	testing.expect_value(t, berr, Error.Ok)
	defer close(&b)

	must(t, execute(&a, "PRAGMA journal_mode = WAL; CREATE TABLE t (v INTEGER) STRICT; INSERT INTO t VALUES (1);"))

	must(t, execute(&b, "BEGIN;"))
	testing.expect_value(t, query_int(t, &b, "SELECT count(*) FROM t;"), 1)

	must(t, execute(&a, "INSERT INTO t VALUES (2);"))

	err := execute(&b, "INSERT INTO t VALUES (3);")
	testing.expect_value(t, err, Error.Busy)
	testing.expect_value(t, extended_errcode(&b), Extended_Error.Busy_Snapshot)
	must(t, execute(&b, "ROLLBACK;"))
}

@(test)
test_message_survives_with_transaction_rollback :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER NOT NULL CHECK (val >= 0)) STRICT;"))

	body :: proc(tx: ^Tx, _: rawptr) -> Error {
		return execute(tx.db, "INSERT INTO t (val) VALUES (-1);")
	}
	err := with_transaction(&db, body)
	testing.expect_value(t, err, Error.Constraint_Check)
	testing.expect_value(t, extended_errcode(&db), Extended_Error.Constraint_Check)

	msg := error_string(&db)
	defer delete(msg)
	testing.expect(t, strings.contains(msg, "CHECK constraint failed"), msg)
}

@(test)
test_message_survives_deferred_finalize_and_rollback :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER UNIQUE) STRICT; INSERT INTO t VALUES (1);"))

	insert_duplicate :: proc(db: ^DB) -> Error {
		tx := begin(db) or_return
		defer rollback(&tx)
		stmt := prepare(db, "INSERT INTO t VALUES (1);") or_return
		defer finalize(&stmt)
		_ = step(&stmt) or_return
		return commit(&tx)
	}
	testing.expect_value(t, insert_duplicate(&db), Error.Constraint_Unique)

	msg := error_string(&db)
	defer delete(msg)
	testing.expect(t, strings.contains(msg, "UNIQUE constraint failed"), msg)
}

@(test)
test_long_message_truncates_on_utf8_boundary :: proc(t: ^testing.T) {
	db: DB
	long := strings.repeat("é", ERROR_MESSAGE_CAPACITY, context.temp_allocator) // 2 bytes each
	_record(&db, SQLITE_ERROR, fmt.tprintf("x%s", long)) // odd prefix forces a split
	testing.expect(t, db.err_len <= ERROR_MESSAGE_CAPACITY)
	testing.expect(t, utf8.valid_string(string(db.err_buf[:db.err_len])))
}

// --- Connection state ----------------------------------------------------------------

@(test)
test_changes_and_total_changes :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	must(t, execute(&db, "CREATE TABLE t (id INTEGER PRIMARY KEY, val INTEGER) STRICT;"))
	must(t, execute(&db, "INSERT INTO t (val) VALUES (1), (2), (3);"))
	testing.expect_value(t, changes(&db), 3)
	testing.expect_value(t, changes64(&db), i64(3))

	must(t, execute(&db, "UPDATE t SET val = val + 1;"))
	testing.expect_value(t, changes(&db), 3)
	testing.expect_value(t, total_changes(&db), 6)
	testing.expect_value(t, total_changes64(&db), i64(6))
}

// interrupt only affects a statement already in progress, so step once into
// a long-running query before interrupting.
@(test)
test_interrupt_fails_running_statement :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, `
		WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000)
		SELECT x FROM cnt;
	`)
	defer finalize(&stmt)
	testing.expect_value(t, must_step(t, &stmt), Step_Result.Row)

	interrupt(&db)

	_, err := step(&stmt)
	testing.expect_value(t, err, Error.Interrupt)
}

@(test)
test_limit_reads_and_sets :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	original := limit(&db, .Length)
	testing.expect(t, original > 0)
	testing.expect_value(t, limit(&db, .Length, 1000), original)
	testing.expect_value(t, limit(&db, .Length), 1000)
}

// --- execute / Param -----------------------------------------------------------------

@(test)
test_execute_runs_multiple_statements_without_params :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	must(t, execute(&db, `
		-- leading comment
		CREATE TABLE t (id INTEGER PRIMARY KEY, val INTEGER) STRICT;
		INSERT INTO t (val) VALUES (42);;
		-- trailing comment
	`))
	testing.expect_value(t, query_int(t, &db, "SELECT val FROM t;"), 42)
}

@(test)
test_execute_script_stops_at_first_error :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER NOT NULL) STRICT;"))

	err := execute(&db, `
		INSERT INTO t VALUES (1);
		INSERT INTO t VALUES (NULL);
		INSERT INTO t VALUES (3);
	`)
	testing.expect_value(t, err, Error.Constraint_Not_Null)
	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

@(test)
test_execute_binds_params :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (name TEXT, score REAL, flag INTEGER) STRICT;"))
	must(t, execute(&db, "INSERT INTO t VALUES (?1, ?2, ?3);", {"Ada", 3.5, true}))

	stmt := must_prepare(t, &db, "SELECT name, score, flag FROM t;")
	defer finalize(&stmt)
	must_step(t, &stmt)

	name := column_text(&stmt, 0)
	defer delete(name)
	testing.expect_value(t, name, "Ada")
	testing.expect_value(t, column_float(&stmt, 1), 3.5)
	testing.expect_value(t, column_int(&stmt, 2), 1)
}

// A multi-row RETURNING write is applied row by row as it steps, so execute
// must step it to completion.
@(test)
test_execute_completes_multi_row_returning_write :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, org_id INTEGER, active INTEGER) STRICT;"))
	must(t, execute(&db, "INSERT INTO accounts (org_id, active) VALUES (1, 1), (1, 1), (1, 1), (2, 1);"))

	must(t, execute(&db, "UPDATE accounts SET active = 0 WHERE org_id = ?1 RETURNING id;", {1}))
	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM accounts WHERE active = 0;"), 3)
}

@(test)
test_execute_params_reject_multi_statement_sql :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	err := execute(&db, "INSERT INTO t VALUES (?1); INSERT INTO t VALUES (2);", {1})
	testing.expect_value(t, err, Error.Misuse)
	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 0)

	// The second statement depends on the first, so it can't even be
	// compiled yet. Still a second statement.
	err = execute(&db, "CREATE TABLE u (v INTEGER) STRICT; INSERT INTO u VALUES (?1);", {1})
	testing.expect_value(t, err, Error.Misuse)
}

@(test)
test_execute_params_allow_trailing_semicolons_and_comments :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	must(t, execute(&db, "INSERT INTO t VALUES (?1); ; -- done", {1}))
	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

@(test)
test_execute_param_count_must_match :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (a INTEGER, b INTEGER) STRICT;"))

	testing.expect_value(t, execute(&db, "INSERT INTO t VALUES (?1, ?2);", {1}), Error.Range)
	testing.expect_value(t, execute(&db, "INSERT INTO t VALUES (?1, ?2);", {1, 2, 3}), Error.Range)
	testing.expect_value(t, execute(&db, "INSERT INTO t VALUES (?1, ?2);"), Error.Range)
	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 0)

	msg := error_string(&db)
	defer delete(msg)
	testing.expect_value(t, msg, "statement expects 2 parameter(s), got 0")
}

@(test)
test_execute_does_not_grow_temp_allocator :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (v TEXT) STRICT;"))

	free_all(context.temp_allocator)
	arena := (^runtime.Arena)(context.temp_allocator.data)
	before := arena.total_used
	for _ in 0 ..< 1000 {
		must(t, execute(&db, "INSERT INTO t VALUES (?1);", {"x"}))
	}
	testing.expect_value(t, arena.total_used, before)
}

// --- Transactions --------------------------------------------------------------------

@(test)
test_tx_commit_persists :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	tx, err := begin(&db)
	must(t, err)
	must(t, execute(&db, "INSERT INTO t (val) VALUES (1);"))
	must(t, commit(&tx))

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

@(test)
test_tx_rollback_discards :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	tx, err := begin(&db)
	must(t, err)
	must(t, execute(&db, "INSERT INTO t (val) VALUES (1);"))
	must(t, rollback(&tx))

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 0)
}

@(test)
test_tx_rollback_after_commit_is_a_noop :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	tx, err := begin(&db)
	must(t, err)
	must(t, execute(&db, "INSERT INTO t (val) VALUES (1);"))
	must(t, commit(&tx))
	must(t, rollback(&tx))

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

// A begin() that fails inside an open transaction must not let a deferred
// rollback end the outer transaction.
@(test)
test_failed_begin_does_not_roll_back_outer_transaction :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	outer, err := begin(&db)
	must(t, err)
	must(t, execute(&db, "INSERT INTO t VALUES (1);"))
	{
		inner, inner_err := begin(&db)
		defer rollback(&inner)
		testing.expect_value(t, inner_err, Error.Generic)
		testing.expect(t, inner.done)
	}
	must(t, commit(&outer))

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

@(test)
test_with_transaction_commits_on_success :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	body :: proc(tx: ^Tx, _: rawptr) -> Error {
		return execute(tx.db, "INSERT INTO t (val) VALUES (1);")
	}
	must(t, with_transaction(&db, body))

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 1)
}

@(test)
test_with_transaction_rolls_back_partial_work :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER NOT NULL CHECK (val >= 0)) STRICT;"))

	body :: proc(tx: ^Tx, _: rawptr) -> Error {
		execute(tx.db, "INSERT INTO t (val) VALUES (1);") or_return
		return execute(tx.db, "INSERT INTO t (val) VALUES (-1);")
	}
	testing.expect_value(t, with_transaction(&db, body), Error.Constraint_Check)

	testing.expect_value(t, query_int(t, &db, "SELECT count(*) FROM t;"), 0)
}

// --- Binding -------------------------------------------------------------------------

@(test)
test_bind_text_empty_string_is_not_null :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (s TEXT) STRICT;"))
	must(t, execute(&db, "INSERT INTO t (s) VALUES (?1);", {""}))

	stmt := must_prepare(t, &db, "SELECT s, typeof(s) FROM t;")
	defer finalize(&stmt)
	must_step(t, &stmt)

	testing.expect(t, !column_is_null(&stmt, 0))
	kind := column_text(&stmt, 1)
	defer delete(kind)
	testing.expect_value(t, kind, "text")
}

@(test)
test_bind_bytes_empty_blob_is_not_null :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (b BLOB) STRICT;"))

	stmt := must_prepare(t, &db, "INSERT INTO t (b) VALUES (?1);")
	defer finalize(&stmt)
	must(t, bind_bytes(&stmt, 1, []byte{}))
	must_step(t, &stmt)

	q := must_prepare(t, &db, "SELECT b, typeof(b) FROM t;")
	defer finalize(&q)
	must_step(t, &q)

	testing.expect(t, !column_is_null(&q, 0))
	kind := column_text(&q, 1)
	defer delete(kind)
	testing.expect_value(t, kind, "blob")
}

@(test)
test_bind_null_param_is_null :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (s TEXT, b BLOB) STRICT;"))
	must(t, execute(&db, "INSERT INTO t (s, b) VALUES (?1, ?2);", {nil, nil}))

	stmt := must_prepare(t, &db, "SELECT s, b FROM t;")
	defer finalize(&stmt)
	must_step(t, &stmt)
	testing.expect(t, column_is_null(&stmt, 0))
	testing.expect(t, column_is_null(&stmt, 1))
}

// bind() must accept an untyped integer literal, which is why bind_int64 is
// not in the group.
@(test)
test_bind_group_accepts_int_literal :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (a INTEGER, b INTEGER) STRICT;"))

	stmt := must_prepare(t, &db, "INSERT INTO t (a, b) VALUES (?1, ?2);")
	defer finalize(&stmt)
	must(t, bind(&stmt, 1, 42))
	big: i64 = 9_000_000_000
	must(t, bind_int64(&stmt, 2, big))
	must_step(t, &stmt)

	q := must_prepare(t, &db, "SELECT a, b FROM t;")
	defer finalize(&q)
	must_step(t, &q)
	testing.expect_value(t, column_int(&q, 0), 42)
	testing.expect_value(t, column_int64(&q, 1), big)
}

@(test)
test_bind_over_length_limit_is_too_big :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	limit(&db, .Length, 100)

	stmt := must_prepare(t, &db, "SELECT ?1, ?2;")
	defer finalize(&stmt)

	text := strings.repeat("x", 101, context.temp_allocator)
	testing.expect_value(t, bind_text(&stmt, 1, text), Error.Too_Big)
	testing.expect_value(t, bind_bytes(&stmt, 2, transmute([]byte)text), Error.Too_Big)
	must(t, bind_text(&stmt, 1, text[:100]))
}

@(test)
test_bind_parameter_name_and_index :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, "SELECT :amount, ?;")
	defer finalize(&stmt)
	testing.expect_value(t, bind_parameter_count(&stmt), 2)

	name := bind_parameter_name(&stmt, 1)
	defer delete(name)
	testing.expect_value(t, name, ":amount")
	testing.expect_value(t, bind_parameter_index(&stmt, ":amount"), 1)
	testing.expect_value(t, bind_parameter_index(&stmt, ":nonexistent"), 0)

	unnamed := bind_parameter_name(&stmt, 2)
	testing.expect_value(t, unnamed, "")
	out_of_range := bind_parameter_name(&stmt, 99)
	testing.expect_value(t, out_of_range, "")
}

// --- Statement introspection -------------------------------------------------------

@(test)
test_sql_and_expanded_sql :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, "SELECT ?1;")
	defer finalize(&stmt)
	must(t, bind(&stmt, 1, 42))

	original := sql(&stmt)
	defer delete(original)
	testing.expect_value(t, original, "SELECT ?1;")

	expanded := expanded_sql(&stmt)
	defer delete(expanded)
	testing.expect_value(t, expanded, "SELECT 42;")
}

@(test)
test_stmt_readonly :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	must(t, execute(&db, "CREATE TABLE t (val INTEGER) STRICT;"))

	select_stmt := must_prepare(t, &db, "SELECT val FROM t;")
	defer finalize(&select_stmt)
	testing.expect(t, stmt_readonly(&select_stmt))

	insert_stmt := must_prepare(t, &db, "INSERT INTO t (val) VALUES (1);")
	defer finalize(&insert_stmt)
	testing.expect(t, !stmt_readonly(&insert_stmt))
}

// --- int / i64 ---------------------------------------------------------------------

@(test)
test_column_int_and_int64_agree :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, "SELECT 9000, 5000000000;")
	defer finalize(&stmt)
	must_step(t, &stmt)
	testing.expect_value(t, column_int(&stmt, 0), 9000)
	testing.expect_value(t, column_int64(&stmt, 0), i64(9000))
	testing.expect_value(t, column_int(&stmt, 1), 5_000_000_000)
}

// Documents why scan_row has no i32 support: STRICT allows any 64-bit value
// in an INTEGER column, and the 32-bit read truncates it silently.
@(test)
test_i32_column_read_truncates_silently :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, "SELECT 5000000000;")
	defer finalize(&stmt)
	must_step(t, &stmt)
	testing.expect_value(t, column_int64(&stmt, 0), i64(5_000_000_000))
	testing.expect_value(t, sqlite3_column_int(stmt.handle, 0), i32(705_032_704))
}

// --- Backup --------------------------------------------------------------------------

@(test)
test_backup_one_shot :: proc(t: ^testing.T) {
	source := must_open_memory(t)
	defer close(&source)
	must(t, execute(&source, "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT) STRICT;"))
	must(t, execute(&source, "INSERT INTO t (val) VALUES ('a'), ('b'), ('c');"))

	dest := must_open_memory(t)
	defer close(&dest)
	must(t, backup(&dest, &source))

	testing.expect_value(t, query_int(t, &dest, "SELECT count(*) FROM t;"), 3)
}

@(test)
test_backup_step_loop_reports_progress :: proc(t: ^testing.T) {
	source := must_open_memory(t)
	defer close(&source)
	must(t, execute(&source, `
		CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT) STRICT;
		WITH RECURSIVE n(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM n WHERE x < 499)
		INSERT INTO t (val) SELECT 'row-' || x FROM n;
	`))

	dest := must_open_memory(t)
	defer close(&dest)

	b, init_err := backup_init(&dest, "main", &source, "main")
	defer backup_finish(&b)
	must(t, init_err)

	last_remaining := -1
	for steps := 0; ; steps += 1 {
		result, err := backup_step(&b, 1)
		must(t, err)

		remaining := backup_remaining(&b)
		if last_remaining != -1 {
			testing.expect(t, remaining < last_remaining, "remaining should decrease each step")
		}
		last_remaining = remaining

		if result == .Done do break
		if steps > 10_000 do testing.fail_now(t, "backup_step never reported .Done")
	}

	testing.expect_value(t, backup_remaining(&b), 0)
	testing.expect(t, backup_pagecount(&b) > 1, "500 rows should span more than one page")
	testing.expect_value(t, query_int(t, &dest, "SELECT count(*) FROM t;"), 500)
}

@(test)
test_backup_init_failure_reports_error :: proc(t: ^testing.T) {
	source := must_open_memory(t)
	defer close(&source)
	dest := must_open_memory(t)
	defer close(&dest)

	b, err := backup_init(&dest, "main", &source, "nonexistent")
	defer backup_finish(&b)
	testing.expect(t, b.handle == nil)
	testing.expect_value(t, err, Error.Generic)

	msg := error_string(&dest)
	defer delete(msg)
	testing.expect(t, strings.contains(msg, "nonexistent"), msg)
}

// --- WAL checkpointing ---------------------------------------------------------------

@(test)
test_wal_checkpoint_without_wal_reports_minus_one :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	n_log, n_ckpt, err := wal_checkpoint(&db)
	must(t, err)
	testing.expect_value(t, n_log, -1)
	testing.expect_value(t, n_ckpt, -1)
}

@(private)
_fill_wal :: proc(t: ^testing.T, db: ^DB) {
	must(t, execute(db, "PRAGMA journal_mode = WAL;"))
	must(t, execute(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT) STRICT;"))
	for i in 0 ..< 50 {
		must(t, execute(db, "INSERT INTO t (val) VALUES (?1);", {fmt.tprintf("row-%d", i)}))
	}
}

@(test)
test_wal_checkpoint_full_checkpoints_everything :: proc(t: ^testing.T) {
	db, path := open_temp_file_db(t)
	defer remove_temp_file_db(path)
	defer close(&db)
	_fill_wal(t, &db)

	n_log, n_ckpt, err := wal_checkpoint(&db, .Full)
	must(t, err)
	testing.expect(t, n_log > 0)
	testing.expect_value(t, n_ckpt, n_log)
}

// Full leaves the WAL file at its size; Truncate resets it, so a following
// checkpoint sees zero frames.
@(test)
test_wal_checkpoint_truncate_resets_wal :: proc(t: ^testing.T) {
	db, path := open_temp_file_db(t)
	defer remove_temp_file_db(path)
	defer close(&db)
	_fill_wal(t, &db)

	_, _, trunc_err := wal_checkpoint(&db, .Truncate)
	must(t, trunc_err)

	n_log, n_ckpt, err := wal_checkpoint(&db, .Truncate)
	must(t, err)
	testing.expect_value(t, n_log, 0)
	testing.expect_value(t, n_ckpt, 0)
}

@(test)
test_wal_checkpoint_unknown_db_name_errors :: proc(t: ^testing.T) {
	db, path := open_temp_file_db(t)
	defer remove_temp_file_db(path)
	defer close(&db)
	must(t, execute(&db, "PRAGMA journal_mode = WAL;"))

	_, _, err := wal_checkpoint(&db, .Passive, "nonexistent")
	testing.expect(t, err != .Ok)
}

// --- scan_row / row_layout -----------------------------------------------------------

Scan_Test_Row :: struct {
	id:      int,
	name:    string,
	balance: i64,
	ratio:   f64,
	active:  bool,
	data:    []byte,
}

@(test)
test_scan_row_fills_every_supported_kind :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db,
		"SELECT 1 AS id, 'Grace' AS name, 5000000000 AS balance, 0.5 AS ratio, 1 AS active, X'0102' AS data, 'x' AS extra;")
	defer finalize(&stmt)
	layout := row_layout(&stmt, Scan_Test_Row)
	defer delete(layout.fields)
	testing.expect_value(t, len(layout.fields), 6)

	must_step(t, &stmt)
	row := scan_row(&stmt, layout, Scan_Test_Row)
	defer delete(row.name)
	defer delete(row.data)

	testing.expect_value(t, row.id, 1)
	testing.expect_value(t, row.name, "Grace")
	testing.expect_value(t, row.balance, i64(5_000_000_000))
	testing.expect_value(t, row.ratio, 0.5)
	testing.expect_value(t, row.active, true)
	testing.expect_value(t, len(row.data), 2)
}

// Writes must stay inside their field.
Padded_Row :: struct {
	padding1: [16]u8,
	a:        int,
	b:        i64,
	padding2: [16]u8,
}

@(test)
test_scan_row_does_not_corrupt_neighboring_fields :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)

	stmt := must_prepare(t, &db, "SELECT -1 AS a, -1 AS b;")
	defer finalize(&stmt)
	layout := row_layout(&stmt, Padded_Row)
	defer delete(layout.fields)

	must_step(t, &stmt)
	row := scan_row(&stmt, layout, Padded_Row)

	testing.expect_value(t, row.a, -1)
	testing.expect_value(t, row.b, i64(-1))
	for b in row.padding1 do testing.expect_value(t, b, 0)
	for b in row.padding2 do testing.expect_value(t, b, 0)
}

Bad_Field_Row :: struct {
	value: i32,
}

@(test)
test_row_layout_panics_on_unsupported_field_type :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, _unsupported_field_message("value", typeid_of(Bad_Field_Row)))

	db := must_open_memory(t)
	defer close(&db)
	stmt := must_prepare(t, &db, "SELECT 1 AS value;")
	defer finalize(&stmt)

	row_layout(&stmt, Bad_Field_Row)
}

Ambiguous_Id_Row :: struct {
	id: int,
}

@(test)
test_row_layout_panics_on_ambiguous_column :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, _ambiguous_column_message("id", typeid_of(Ambiguous_Id_Row)))

	db := must_open_memory(t)
	defer close(&db)
	stmt := must_prepare(t, &db, "SELECT 1 AS id, 2 AS id;")
	defer finalize(&stmt)

	row_layout(&stmt, Ambiguous_Id_Row)
}

Name_Only_Row :: struct {
	name: string,
}

// Duplicate column names only matter if a field uses them.
@(test)
test_row_layout_ignores_duplicate_unmatched_columns :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	stmt := must_prepare(t, &db, "SELECT 1 AS id, 2 AS id, 'Ada' AS name;")
	defer finalize(&stmt)

	layout := row_layout(&stmt, Name_Only_Row)
	defer delete(layout.fields)
	testing.expect_value(t, len(layout.fields), 1)
}

// --- Nil-handle safety ---------------------------------------------------------------
// Wrappers return .Misuse, or a zero value, on a handle that was never
// opened or has been closed, instead of passing nil to SQLite.

@(test)
test_prepare_on_unopened_db_returns_misuse :: proc(t: ^testing.T) {
	db: DB
	stmt, err := prepare(&db, "SELECT 1;")
	testing.expect_value(t, err, Error.Misuse)
	testing.expect(t, stmt.handle == nil)
}

@(test)
test_execute_on_closed_db_returns_misuse :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	must(t, close(&db))
	testing.expect_value(t, execute(&db, "SELECT 1;"), Error.Misuse)
}

@(test)
test_bind_and_step_on_finalized_stmt_return_misuse :: proc(t: ^testing.T) {
	db := must_open_memory(t)
	defer close(&db)
	stmt := must_prepare(t, &db, "SELECT ?1;")
	must(t, finalize(&stmt))

	testing.expect_value(t, bind_int(&stmt, 1, 42), Error.Misuse)
	_, err := step(&stmt)
	testing.expect_value(t, err, Error.Misuse)
}

@(test)
test_backup_init_with_unopened_source_returns_misuse :: proc(t: ^testing.T) {
	dest := must_open_memory(t)
	defer close(&dest)
	source: DB

	b, err := backup_init(&dest, "main", &source, "main")
	testing.expect_value(t, err, Error.Misuse)
	testing.expect(t, b.handle == nil)
}

@(test)
test_value_returning_procs_are_nil_safe :: proc(t: ^testing.T) {
	db: DB
	stmt: Stmt
	b: Backup

	testing.expect_value(t, changes(&db), 0)
	testing.expect_value(t, last_insert_rowid(&db), i64(0))
	testing.expect_value(t, limit(&db, .Length), -1)
	testing.expect_value(t, error_string(&db), "")

	testing.expect_value(t, column_count(&stmt), 0)
	testing.expect_value(t, column_type(&stmt, 0), Column_Type.Null)
	testing.expect_value(t, column_int(&stmt, 0), 0)
	testing.expect_value(t, column_text(&stmt, 0), "")
	testing.expect(t, column_bytes(&stmt, 0) == nil)
	testing.expect(t, !stmt_readonly(&stmt))

	testing.expect_value(t, backup_remaining(&b), 0)
	testing.expect_value(t, backup_pagecount(&b), 0)

	interrupt(&db)
}
