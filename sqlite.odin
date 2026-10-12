// Source: https://github.com/sdicker8/odin-sqlite-strict (zlib license - see LICENSE)

package sqlite_strict

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// Idiomatic wrapper over bindings.odin. See README.md for the design.

ERROR_MESSAGE_CAPACITY :: 512

// Oldest SQLite this package works with (STRICT tables, changes64,
// SQLITE_CONSTRAINT_DATATYPE). Checked at runtime by open().
MIN_SQLITE_VERSION :: 3_037_000

// A connection. Statements, transactions and backups keep a pointer to it
// so failures can be recorded, so a DB must not move while any of those are
// alive.
DB :: struct {
	handle:   ^sqlite3,
	err_code: i32,
	err_len:  int,
	err_buf:  [ERROR_MESSAGE_CAPACITY]byte,
}

Stmt :: struct {
	handle: ^sqlite3_stmt,
	db:     ^DB,
}

// --- Errors --------------------------------------------------------------------

// Primary result codes, plus the CONSTRAINT subcodes so callers can tell
// which constraint failed. Every value returned by this package is a named
// member; extended codes from other families are folded into their primary
// code (BUSY_SNAPSHOT is .Busy). Use extended_errcode() for the detail.
Error :: enum i32 {
	Ok         = SQLITE_OK,
	Generic    = SQLITE_ERROR,
	Internal   = SQLITE_INTERNAL,
	Perm       = SQLITE_PERM,
	Abort      = SQLITE_ABORT,
	Busy       = SQLITE_BUSY,
	Locked     = SQLITE_LOCKED,
	No_Mem     = SQLITE_NOMEM,
	Readonly   = SQLITE_READONLY,
	Interrupt  = SQLITE_INTERRUPT,
	IO_Err     = SQLITE_IOERR,
	Corrupt    = SQLITE_CORRUPT,
	Not_Found  = SQLITE_NOTFOUND,
	Full       = SQLITE_FULL,
	Cant_Open  = SQLITE_CANTOPEN,
	Protocol   = SQLITE_PROTOCOL,
	Empty      = SQLITE_EMPTY,
	Schema     = SQLITE_SCHEMA,
	Too_Big    = SQLITE_TOOBIG,
	Constraint = SQLITE_CONSTRAINT, // a constraint failure with no known subcode
	Mismatch   = SQLITE_MISMATCH,
	Misuse     = SQLITE_MISUSE,
	No_LFS     = SQLITE_NOLFS,
	Auth       = SQLITE_AUTH,
	Format     = SQLITE_FORMAT,
	Range      = SQLITE_RANGE,
	Not_A_DB   = SQLITE_NOTADB,
	Notice     = SQLITE_NOTICE,
	Warning    = SQLITE_WARNING,

	Constraint_Check       = SQLITE_CONSTRAINT_CHECK,
	Constraint_Commit_Hook = SQLITE_CONSTRAINT_COMMITHOOK,
	Constraint_Foreign_Key = SQLITE_CONSTRAINT_FOREIGNKEY,
	Constraint_Function    = SQLITE_CONSTRAINT_FUNCTION,
	Constraint_Not_Null    = SQLITE_CONSTRAINT_NOTNULL,
	Constraint_Primary_Key = SQLITE_CONSTRAINT_PRIMARYKEY,
	Constraint_Trigger     = SQLITE_CONSTRAINT_TRIGGER,
	Constraint_Unique      = SQLITE_CONSTRAINT_UNIQUE,
	Constraint_Vtab        = SQLITE_CONSTRAINT_VTAB,
	Constraint_Row_Id      = SQLITE_CONSTRAINT_ROWID,
	Constraint_Pinned      = SQLITE_CONSTRAINT_PINNED,
	Constraint_Data_Type   = SQLITE_CONSTRAINT_DATATYPE,
}

// Every primary and extended result code in SQLite 3.53. A library newer
// than that can report codes missing from this list.
Extended_Error :: enum i32 {
	Ok         = SQLITE_OK,
	Generic    = SQLITE_ERROR,
	Internal   = SQLITE_INTERNAL,
	Perm       = SQLITE_PERM,
	Abort      = SQLITE_ABORT,
	Busy       = SQLITE_BUSY,
	Locked     = SQLITE_LOCKED,
	No_Mem     = SQLITE_NOMEM,
	Readonly   = SQLITE_READONLY,
	Interrupt  = SQLITE_INTERRUPT,
	IO_Err     = SQLITE_IOERR,
	Corrupt    = SQLITE_CORRUPT,
	Not_Found  = SQLITE_NOTFOUND,
	Full       = SQLITE_FULL,
	Cant_Open  = SQLITE_CANTOPEN,
	Protocol   = SQLITE_PROTOCOL,
	Empty      = SQLITE_EMPTY,
	Schema     = SQLITE_SCHEMA,
	Too_Big    = SQLITE_TOOBIG,
	Constraint = SQLITE_CONSTRAINT,
	Mismatch   = SQLITE_MISMATCH,
	Misuse     = SQLITE_MISUSE,
	No_LFS     = SQLITE_NOLFS,
	Auth       = SQLITE_AUTH,
	Format     = SQLITE_FORMAT,
	Range      = SQLITE_RANGE,
	Not_A_DB   = SQLITE_NOTADB,
	Notice     = SQLITE_NOTICE,
	Warning    = SQLITE_WARNING,

	Generic_Missing_Coll_Seq   = SQLITE_ERROR | (1 << 8),
	Generic_Retry              = SQLITE_ERROR | (2 << 8),
	Generic_Snapshot           = SQLITE_ERROR | (3 << 8),
	Generic_Reserve_Size       = SQLITE_ERROR | (4 << 8),
	Generic_Key                = SQLITE_ERROR | (5 << 8),
	Generic_Unable             = SQLITE_ERROR | (6 << 8),
	IO_Err_Read                = SQLITE_IOERR | (1 << 8),
	IO_Err_Short_Read          = SQLITE_IOERR | (2 << 8),
	IO_Err_Write               = SQLITE_IOERR | (3 << 8),
	IO_Err_Fsync               = SQLITE_IOERR | (4 << 8),
	IO_Err_Dir_Fsync           = SQLITE_IOERR | (5 << 8),
	IO_Err_Truncate            = SQLITE_IOERR | (6 << 8),
	IO_Err_Fstat               = SQLITE_IOERR | (7 << 8),
	IO_Err_Unlock              = SQLITE_IOERR | (8 << 8),
	IO_Err_Rd_Lock             = SQLITE_IOERR | (9 << 8),
	IO_Err_Delete              = SQLITE_IOERR | (10 << 8),
	IO_Err_Blocked             = SQLITE_IOERR | (11 << 8),
	IO_Err_No_Mem              = SQLITE_IOERR | (12 << 8),
	IO_Err_Access              = SQLITE_IOERR | (13 << 8),
	IO_Err_Check_Reserved_Lock = SQLITE_IOERR | (14 << 8),
	IO_Err_Lock                = SQLITE_IOERR | (15 << 8),
	IO_Err_Close               = SQLITE_IOERR | (16 << 8),
	IO_Err_Dir_Close           = SQLITE_IOERR | (17 << 8),
	IO_Err_Shm_Open            = SQLITE_IOERR | (18 << 8),
	IO_Err_Shm_Size            = SQLITE_IOERR | (19 << 8),
	IO_Err_Shm_Lock            = SQLITE_IOERR | (20 << 8),
	IO_Err_Shm_Map             = SQLITE_IOERR | (21 << 8),
	IO_Err_Seek                = SQLITE_IOERR | (22 << 8),
	IO_Err_Delete_No_Ent       = SQLITE_IOERR | (23 << 8),
	IO_Err_Mmap                = SQLITE_IOERR | (24 << 8),
	IO_Err_Get_Temp_Path       = SQLITE_IOERR | (25 << 8),
	IO_Err_Conv_Path           = SQLITE_IOERR | (26 << 8),
	IO_Err_Vnode               = SQLITE_IOERR | (27 << 8),
	IO_Err_Auth                = SQLITE_IOERR | (28 << 8),
	IO_Err_Begin_Atomic        = SQLITE_IOERR | (29 << 8),
	IO_Err_Commit_Atomic       = SQLITE_IOERR | (30 << 8),
	IO_Err_Rollback_Atomic     = SQLITE_IOERR | (31 << 8),
	IO_Err_Data                = SQLITE_IOERR | (32 << 8),
	IO_Err_Corrupt_FS          = SQLITE_IOERR | (33 << 8),
	IO_Err_In_Page             = SQLITE_IOERR | (34 << 8),
	IO_Err_Bad_Key             = SQLITE_IOERR | (35 << 8),
	IO_Err_Codec               = SQLITE_IOERR | (36 << 8),
	Locked_Shared_Cache        = SQLITE_LOCKED | (1 << 8),
	Locked_Vtab                = SQLITE_LOCKED | (2 << 8),
	Busy_Recovery              = SQLITE_BUSY | (1 << 8),
	Busy_Snapshot              = SQLITE_BUSY | (2 << 8),
	Busy_Timeout               = SQLITE_BUSY | (3 << 8),
	Cant_Open_No_Temp_Dir      = SQLITE_CANTOPEN | (1 << 8),
	Cant_Open_Is_Dir           = SQLITE_CANTOPEN | (2 << 8),
	Cant_Open_Full_Path        = SQLITE_CANTOPEN | (3 << 8),
	Cant_Open_Conv_Path        = SQLITE_CANTOPEN | (4 << 8),
	Cant_Open_Dirty_WAL        = SQLITE_CANTOPEN | (5 << 8),
	Cant_Open_Symlink          = SQLITE_CANTOPEN | (6 << 8),
	Corrupt_Vtab               = SQLITE_CORRUPT | (1 << 8),
	Corrupt_Sequence           = SQLITE_CORRUPT | (2 << 8),
	Corrupt_Index              = SQLITE_CORRUPT | (3 << 8),
	Readonly_Recovery          = SQLITE_READONLY | (1 << 8),
	Readonly_Cant_Lock         = SQLITE_READONLY | (2 << 8),
	Readonly_Rollback          = SQLITE_READONLY | (3 << 8),
	Readonly_DB_Moved          = SQLITE_READONLY | (4 << 8),
	Readonly_Cant_Init         = SQLITE_READONLY | (5 << 8),
	Readonly_Directory         = SQLITE_READONLY | (6 << 8),
	Abort_Rollback             = SQLITE_ABORT | (2 << 8),
	Constraint_Check           = SQLITE_CONSTRAINT_CHECK,
	Constraint_Commit_Hook     = SQLITE_CONSTRAINT_COMMITHOOK,
	Constraint_Foreign_Key     = SQLITE_CONSTRAINT_FOREIGNKEY,
	Constraint_Function        = SQLITE_CONSTRAINT_FUNCTION,
	Constraint_Not_Null        = SQLITE_CONSTRAINT_NOTNULL,
	Constraint_Primary_Key     = SQLITE_CONSTRAINT_PRIMARYKEY,
	Constraint_Trigger         = SQLITE_CONSTRAINT_TRIGGER,
	Constraint_Unique          = SQLITE_CONSTRAINT_UNIQUE,
	Constraint_Vtab            = SQLITE_CONSTRAINT_VTAB,
	Constraint_Row_Id          = SQLITE_CONSTRAINT_ROWID,
	Constraint_Pinned          = SQLITE_CONSTRAINT_PINNED,
	Constraint_Data_Type       = SQLITE_CONSTRAINT_DATATYPE,
	Notice_Recover_WAL         = SQLITE_NOTICE | (1 << 8),
	Notice_Recover_Rollback    = SQLITE_NOTICE | (2 << 8),
	Notice_RBU                 = SQLITE_NOTICE | (3 << 8),
	Warning_Auto_Index         = SQLITE_WARNING | (1 << 8),
	Auth_User                  = SQLITE_AUTH | (1 << 8),
}

// error_string returns the message for the most recent failure on `db`,
// copied into `allocator`. A later successful call does not clear it.
error_string :: proc(db: ^DB, allocator := context.allocator, loc := #caller_location) -> string {
	return strings.clone(string(db.err_buf[:db.err_len]), allocator, loc)
}

// extended_errcode returns the full result code of the most recent failure
// on `db`, e.g. .Busy_Snapshot where the returned Error was .Busy.
extended_errcode :: proc(db: ^DB) -> Extended_Error {
	return Extended_Error(db.err_code)
}

@(private)
_to_error :: proc "contextless" (rc: i32) -> Error {
	primary := rc & 0xff
	if primary != SQLITE_CONSTRAINT do return Error(primary)
	switch rc {
	case SQLITE_CONSTRAINT_CHECK, SQLITE_CONSTRAINT_COMMITHOOK, SQLITE_CONSTRAINT_FOREIGNKEY,
	     SQLITE_CONSTRAINT_FUNCTION, SQLITE_CONSTRAINT_NOTNULL, SQLITE_CONSTRAINT_PRIMARYKEY,
	     SQLITE_CONSTRAINT_TRIGGER, SQLITE_CONSTRAINT_UNIQUE, SQLITE_CONSTRAINT_VTAB,
	     SQLITE_CONSTRAINT_ROWID, SQLITE_CONSTRAINT_PINNED, SQLITE_CONSTRAINT_DATATYPE:
		return Error(rc)
	}
	return .Constraint
}

@(private)
_record :: proc(db: ^DB, code: i32, msg: string) {
	if db == nil do return
	db.err_code = code
	n := copy(db.err_buf[:], msg)
	if n < len(msg) {
		// Truncated: don't leave half a UTF-8 sequence at the end.
		for n > 0 && msg[n] & 0xC0 == 0x80 do n -= 1
	}
	db.err_len = n
}

// _check converts a result code and, on failure, records SQLite's message
// for it on `db`.
@(private)
_check :: proc(db: ^DB, rc: i32) -> Error {
	if rc == SQLITE_OK do return .Ok
	if db != nil {
		msg: cstring
		if db.handle != nil && sqlite3_extended_errcode(db.handle) & 0xff == rc & 0xff {
			msg = sqlite3_errmsg(db.handle)
		} else {
			msg = sqlite3_errstr(rc)
		}
		_record(db, rc, string(msg))
	}
	return _to_error(rc)
}

// _fail records a failure detected by this package rather than by SQLite.
@(private)
_fail :: proc(db: ^DB, err: Error, format: string, args: ..any) -> Error {
	if db != nil {
		buf: [ERROR_MESSAGE_CAPACITY]byte
		_record(db, i32(err), fmt.bprintf(buf[:], format, ..args))
	}
	return err
}

// --- Open / close ----------------------------------------------------------------

Open_Flag :: enum i32 {
	Read_Only  = 0, // SQLITE_OPEN_READONLY  (0x01)
	Read_Write = 1, // SQLITE_OPEN_READWRITE (0x02)
	Create     = 2, // SQLITE_OPEN_CREATE    (0x04)
}
Open_Flags :: bit_set[Open_Flag; i32]

DEFAULT_OPEN_FLAGS :: Open_Flags{.Read_Write, .Create}

// open opens `path` (":memory:" for an in-memory database) and configures
// the connection:
//   - extended result codes on, so constraint failures are distinguishable
//   - foreign key enforcement on (turn off with PRAGMA foreign_keys = OFF)
//   - double-quoted string literals off, so "name" is always an identifier
// If any of these cannot be applied, the connection is closed and open fails.
open :: proc(path: string, flags := DEFAULT_OPEN_FLAGS) -> (db: DB, err: Error) {
	// This build omits autoinit, so initialize explicitly. Idempotent.
	if rc := sqlite3_initialize(); rc != SQLITE_OK {
		err = _check(&db, rc)
		return
	}
	if v := int(sqlite3_libversion_number()); v < MIN_SQLITE_VERSION {
		err = _fail(&db, .Generic,
			"linked SQLite is %d.%d.%d; this package requires 3.37.0 or newer",
			v / 1_000_000, v / 1000 % 1000, v % 1000)
		return
	}

	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	rc := sqlite3_open_v2(cpath, &db.handle, transmute(i32)flags, nil)
	if rc != SQLITE_OK {
		err = _check(&db, rc)
		// open_v2 can allocate a handle even on failure.
		sqlite3_close_v2(db.handle)
		db.handle = nil
		return
	}

	sqlite3_extended_result_codes(db.handle, 1)

	Setting :: struct {
		op:   i32,
		want: bool,
		what: string,
	}
	settings := [?]Setting{
		{SQLITE_DBCONFIG_ENABLE_FKEY, true,  "enable foreign key enforcement"},
		{SQLITE_DBCONFIG_DQS_DML,     false, "disable double-quoted string literals in DML"},
		{SQLITE_DBCONFIG_DQS_DDL,     false, "disable double-quoted string literals in DDL"},
	}
	for s in settings {
		actual: i32 = -1
		sqlite3_db_config(db.handle, s.op, i32(s.want ? 1 : 0), &actual)
		if (actual != 0) != s.want {
			sqlite3_close_v2(db.handle)
			db.handle = nil
			err = _fail(&db, .Generic, "could not %s; check how the linked SQLite was built", s.what)
			return
		}
	}

	// The setting above reads back as on even when foreign key support is
	// compiled out. The pragma only exists when it is compiled in.
	if !_foreign_keys_enforced(&db) {
		sqlite3_close_v2(db.handle)
		db.handle = nil
		err = _fail(&db, .Generic,
			"the linked SQLite does not enforce foreign keys (built with SQLITE_OMIT_FOREIGN_KEY or SQLITE_OMIT_TRIGGER)")
	}
	return
}

@(private)
_foreign_keys_enforced :: proc(db: ^DB) -> bool {
	stmt, _, err := _prepare(db, "PRAGMA foreign_keys;")
	if err != .Ok do return false
	defer finalize(&stmt)
	result, step_err := step(&stmt)
	return step_err == .Ok && result == .Row && column_int(&stmt, 0) == 1
}

close :: proc(db: ^DB) -> Error {
	if db.handle == nil do return .Ok
	rc := sqlite3_close_v2(db.handle)
	err := _check(db, rc)
	db.handle = nil
	return err
}

// --- Connection state --------------------------------------------------------------

last_insert_rowid :: proc(db: ^DB) -> i64 {
	if db.handle == nil do return 0
	return sqlite3_last_insert_rowid(db.handle)
}

// changes and total_changes use the 64-bit C functions.
changes :: proc(db: ^DB) -> int {
	if db.handle == nil do return 0
	return int(sqlite3_changes64(db.handle))
}

total_changes :: proc(db: ^DB) -> int {
	if db.handle == nil do return 0
	return int(sqlite3_total_changes64(db.handle))
}

changes64 :: proc(db: ^DB) -> i64 {
	if db.handle == nil do return 0
	return sqlite3_changes64(db.handle)
}

total_changes64 :: proc(db: ^DB) -> i64 {
	if db.handle == nil do return 0
	return sqlite3_total_changes64(db.handle)
}

// busy_timeout sets how long SQLite retries, in milliseconds, before a
// locked database returns .Busy.
@(require_results)
busy_timeout :: proc(db: ^DB, ms: int) -> Error {
	if db.handle == nil do return _fail(db, .Misuse, "database is not open")
	return _check(db, sqlite3_busy_timeout(db.handle, i32(clamp(ms, 0, int(max(i32))))))
}

// interrupt makes a statement that is currently running on `db` fail with
// .Interrupt at its next step. It may be called from another thread, but
// not concurrently with close().
interrupt :: proc(db: ^DB) {
	if db.handle == nil do return
	sqlite3_interrupt(db.handle)
}

Limit :: enum i32 {
	Length              = SQLITE_LIMIT_LENGTH,
	SQL_Length          = SQLITE_LIMIT_SQL_LENGTH,
	Column              = SQLITE_LIMIT_COLUMN,
	Expr_Depth          = SQLITE_LIMIT_EXPR_DEPTH,
	Compound_Select     = SQLITE_LIMIT_COMPOUND_SELECT,
	VDBE_Op             = SQLITE_LIMIT_VDBE_OP,
	Function_Arg        = SQLITE_LIMIT_FUNCTION_ARG,
	Attached            = SQLITE_LIMIT_ATTACHED,
	Like_Pattern_Length = SQLITE_LIMIT_LIKE_PATTERN_LENGTH,
	Variable_Number     = SQLITE_LIMIT_VARIABLE_NUMBER,
	Trigger_Depth       = SQLITE_LIMIT_TRIGGER_DEPTH,
	Worker_Threads      = SQLITE_LIMIT_WORKER_THREADS,
}

// limit sets a per-connection limit and returns its previous value. A
// negative `new_value` only reads the current value. SQLite clamps values
// above its compile-time maximum.
limit :: proc(db: ^DB, which: Limit, new_value := -1) -> int {
	if db.handle == nil do return -1
	return int(sqlite3_limit(db.handle, i32(which), i32(clamp(new_value, -1, int(max(i32))))))
}

// --- Prepare / execute ---------------------------------------------------------------

// prepare compiles the first statement in `sql`; anything after it is
// ignored. SQL containing no statement (only whitespace or comments) gives
// a Stmt with a nil handle and .Ok.
@(require_results)
prepare :: proc(db: ^DB, sql: string) -> (stmt: Stmt, err: Error) {
	if db.handle == nil {
		err = _fail(db, .Misuse, "database is not open")
		return
	}
	stmt, _, err = _prepare(db, sql)
	return
}

@(private)
_prepare :: proc(db: ^DB, sql: string) -> (stmt: Stmt, tail: string, err: Error) {
	stmt.db = db
	if len(sql) > int(max(i32)) {
		err = _fail(db, .Too_Big, "SQL text is longer than 2 GiB")
		return
	}
	start := raw_data(sql)
	end: [^]byte
	rc := sqlite3_prepare_v2(db.handle, start, i32(len(sql)), &stmt.handle, &end)
	if rc != SQLITE_OK {
		err = _check(db, rc)
		return
	}
	consumed := len(sql) if end == nil else int(uintptr(end) - uintptr(start))
	tail = sql[consumed:]
	return
}

// _has_statement reports whether `sql` contains anything besides
// whitespace, comments and semicolons. SQL that fails to compile counts as
// a statement.
@(private)
_has_statement :: proc(db: ^DB, sql: string) -> bool {
	rest := sql
	for len(rest) > 0 {
		h: ^sqlite3_stmt
		start := raw_data(rest)
		end: [^]byte
		if sqlite3_prepare_v2(db.handle, start, i32(min(len(rest), int(max(i32)))), &h, &end) != SQLITE_OK {
			return true
		}
		if h != nil {
			sqlite3_finalize(h)
			return true
		}
		consumed := len(rest) if end == nil else int(uintptr(end) - uintptr(start))
		if consumed == 0 do break
		rest = rest[consumed:]
	}
	return false
}

@(private)
_drain :: proc(stmt: ^Stmt) -> Error {
	for {
		result := step(stmt) or_return
		if result == .Done do return .Ok
	}
}

// Param is a value execute() can bind. nil binds NULL; bool binds 0 or 1.
// There is no i64 variant because an untyped integer literal could not
// choose between int and i64; use bind_int64 for an i64 value.
Param :: union {
	int,
	f64,
	string,
	[]byte,
	bool,
}

// execute runs SQL for its side effects and discards any rows it produces.
//
// Without params, `sql` may hold several statements. They run in order and
// execution stops at the first error; earlier statements stay applied, so
// wrap the script in a transaction if it must be all or nothing. A statement
// with parameter placeholders fails with .Range.
//
// With params, `sql` must be exactly one statement (.Misuse otherwise) and
// len(params) must equal its parameter count (.Range otherwise).
@(require_results)
execute :: proc(db: ^DB, sql: string, params: []Param = nil) -> Error {
	if db.handle == nil do return _fail(db, .Misuse, "database is not open")

	if len(params) > 0 {
		stmt, tail := _prepare(db, sql) or_return
		if stmt.handle == nil do return _fail(db, .Misuse, "SQL contains no statement")
		defer finalize(&stmt)
		if _has_statement(db, tail) {
			return _fail(db, .Misuse,
				"parameters can only be bound to a single statement; run the statements separately")
		}
		if n := bind_parameter_count(&stmt); n != len(params) {
			return _fail(db, .Range, "statement expects %d parameter(s), got %d", n, len(params))
		}
		for p, i in params {
			idx := i + 1
			switch v in p {
			case int:    bind_int(&stmt, idx, v) or_return
			case f64:    bind_float(&stmt, idx, v) or_return
			case string: bind_text(&stmt, idx, v) or_return
			case []byte: bind_bytes(&stmt, idx, v) or_return
			case bool:   bind_int(&stmt, idx, v ? 1 : 0) or_return
			case nil:    bind_null(&stmt, idx) or_return
			}
		}
		return _drain(&stmt)
	}

	rest := sql
	for len(rest) > 0 {
		stmt, tail := _prepare(db, rest) or_return
		if stmt.handle == nil {
			if len(tail) == len(rest) do break
			rest = tail
			continue
		}
		rest = tail
		defer finalize(&stmt)
		if n := bind_parameter_count(&stmt); n != 0 {
			return _fail(db, .Range, "statement expects %d parameter(s), got 0", n)
		}
		_drain(&stmt) or_return
	}
	return .Ok
}

// --- Transactions ------------------------------------------------------------------
//
//   tx := sqlite.begin(&db) or_return
//   defer sqlite.rollback(&tx) // no-op after a successful commit
//   ...
//   sqlite.commit(&tx) or_return
//
// Transactions do not nest; begin() inside an open transaction fails.

Transaction_Mode :: enum {
	Deferred,  // no lock until the first read or write
	Immediate, // take the write lock now
	Exclusive, // take the write lock now and block other readers
}

Tx :: struct {
	db:   ^DB,
	done: bool, // set once the transaction has ended or failed to start
}

@(require_results)
begin :: proc(db: ^DB, mode := Transaction_Mode.Deferred) -> (tx: Tx, err: Error) {
	sql: string
	switch mode {
	case .Deferred:  sql = "BEGIN DEFERRED"
	case .Immediate: sql = "BEGIN IMMEDIATE"
	case .Exclusive: sql = "BEGIN EXCLUSIVE"
	}
	err = execute(db, sql)
	tx.db = db
	// A Tx that never started must not roll back a transaction it doesn't own.
	tx.done = err != .Ok
	return
}

@(require_results)
commit :: proc(tx: ^Tx) -> Error {
	if tx.done do return .Ok
	err := execute(tx.db, "COMMIT")
	if err == .Ok do tx.done = true
	return err
}

// rollback is a no-op once the transaction has ended, so it is safe to defer
// right after begin().
rollback :: proc(tx: ^Tx) -> Error {
	if tx.done do return .Ok
	tx.done = true
	return execute(tx.db, "ROLLBACK")
}

// with_transaction runs `body` inside a transaction, committing if it
// returns .Ok and rolling back otherwise. Odin procs don't capture their
// enclosing scope, so pass anything `body` needs through `user_data`.
@(require_results)
with_transaction :: proc(
	db: ^DB,
	body: proc(tx: ^Tx, user_data: rawptr) -> Error,
	user_data: rawptr = nil,
	mode := Transaction_Mode.Deferred,
) -> Error {
	tx := begin(db, mode) or_return
	defer rollback(&tx)
	body(&tx, user_data) or_return
	return commit(&tx)
}

// --- Binding -------------------------------------------------------------------------
// Parameter indices are 1-based, as in the SQL text (?1, ?2, ...).
// Text and blobs are bound with SQLITE_TRANSIENT, so SQLite copies them and
// the argument need not outlive the call. Values larger than SQLite's
// length limit (1 GB by default) fail with .Too_Big.

@(require_results)
bind_null :: proc(stmt: ^Stmt, idx: int) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _check(stmt.db, sqlite3_bind_null(stmt.handle, i32(idx)))
}

@(require_results)
bind_int :: proc(stmt: ^Stmt, idx: int, val: int) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _check(stmt.db, sqlite3_bind_int64(stmt.handle, i32(idx), i64(val)))
}

@(require_results)
bind_int64 :: proc(stmt: ^Stmt, idx: int, val: i64) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _check(stmt.db, sqlite3_bind_int64(stmt.handle, i32(idx), val))
}

@(require_results)
bind_float :: proc(stmt: ^Stmt, idx: int, val: f64) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _check(stmt.db, sqlite3_bind_double(stmt.handle, i32(idx), val))
}

// SQLite binds NULL when given a nil data pointer, whatever the length, and
// raw_data() of an empty string or slice is nil. Empty values point here
// instead so they bind as '' and X'' rather than NULL.
@(private)
_empty_byte: byte

@(require_results)
bind_text :: proc(stmt: ^Stmt, idx: int, val: string) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	ptr: [^]byte = len(val) > 0 ? raw_data(val) : &_empty_byte
	return _check(stmt.db, sqlite3_bind_text64(stmt.handle, i32(idx), ptr, u64(len(val)), SQLITE_TRANSIENT, SQLITE_UTF8))
}

@(require_results)
bind_bytes :: proc(stmt: ^Stmt, idx: int, val: []byte) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	ptr: rawptr = len(val) > 0 ? raw_data(val) : &_empty_byte
	return _check(stmt.db, sqlite3_bind_blob64(stmt.handle, i32(idx), ptr, u64(len(val)), SQLITE_TRANSIENT))
}

// bind covers the common cases. bind_int64 is left out because an untyped
// integer literal would match both it and bind_int.
bind :: proc {
	bind_null,
	bind_int,
	bind_float,
	bind_text,
	bind_bytes,
}

// --- Parameter introspection -----------------------------------------------------------

// bind_parameter_count returns the largest parameter index in the statement,
// which is not always the number of distinct parameters (?3 alone gives 3).
bind_parameter_count :: proc(stmt: ^Stmt) -> int {
	if stmt.handle == nil do return 0
	return int(sqlite3_bind_parameter_count(stmt.handle))
}

// bind_parameter_index returns the index of a named parameter such as
// ":amount", or 0 if there is none.
bind_parameter_index :: proc(stmt: ^Stmt, name: string) -> int {
	if stmt.handle == nil do return 0
	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	return int(sqlite3_bind_parameter_index(stmt.handle, cname))
}

// bind_parameter_name returns the name of parameter `idx`, such as ":amount"
// or "?1". A bare "?" has no name, and an out-of-range index also gives "".
bind_parameter_name :: proc(stmt: ^Stmt, idx: int, allocator := context.allocator, loc := #caller_location) -> string {
	if stmt.handle == nil do return ""
	cname := sqlite3_bind_parameter_name(stmt.handle, i32(idx))
	if cname == nil do return ""
	return strings.clone_from_cstring(cname, allocator, loc)
}

// --- Stepping ----------------------------------------------------------------------------

Step_Result :: enum {
	Row,  // a row is available
	Done, // the statement has finished
}

@(require_results)
step :: proc(stmt: ^Stmt) -> (result: Step_Result, err: Error) {
	if stmt.handle == nil {
		return .Done, _fail(stmt.db, .Misuse, "statement is not prepared")
	}
	rc := sqlite3_step(stmt.handle)
	switch rc {
	case SQLITE_ROW:  return .Row, .Ok
	case SQLITE_DONE: return .Done, .Ok
	}
	return .Done, _check(stmt.db, rc)
}

// reset and finalize return the error from the statement's last step, if
// any. That failure was already recorded when step() returned it, so these
// leave the recorded message alone.
reset :: proc(stmt: ^Stmt) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _to_error(sqlite3_reset(stmt.handle))
}

@(require_results)
clear_bindings :: proc(stmt: ^Stmt) -> Error {
	if stmt.handle == nil do return _fail(stmt.db, .Misuse, "statement is not prepared")
	return _check(stmt.db, sqlite3_clear_bindings(stmt.handle))
}

finalize :: proc(stmt: ^Stmt) -> Error {
	if stmt.handle == nil do return .Ok
	rc := sqlite3_finalize(stmt.handle)
	stmt.handle = nil
	return _to_error(rc)
}

// --- Reading columns -------------------------------------------------------------------
// Column indices are 0-based. column_text, column_bytes and column_name
// return copies owned by the caller. The *_unsafe variants return views into
// SQLite's row buffer that are valid only until the next step, reset or
// finalize; never store or delete them.

Column_Type :: enum i32 {
	Integer = SQLITE_INTEGER,
	Float   = SQLITE_FLOAT,
	Text    = SQLITE_TEXT,
	Blob    = SQLITE_BLOB,
	Null    = SQLITE_NULL,
}

column_count :: proc(stmt: ^Stmt) -> int {
	if stmt.handle == nil do return 0
	return int(sqlite3_column_count(stmt.handle))
}

column_type :: proc(stmt: ^Stmt, col: int) -> Column_Type {
	if stmt.handle == nil do return .Null
	return Column_Type(sqlite3_column_type(stmt.handle, i32(col)))
}

column_is_null :: proc(stmt: ^Stmt, col: int) -> bool {
	return column_type(stmt, col) == .Null
}

column_name :: proc(stmt: ^Stmt, col: int, allocator := context.allocator, loc := #caller_location) -> string {
	if stmt.handle == nil do return ""
	return strings.clone_from_cstring(sqlite3_column_name(stmt.handle, i32(col)), allocator, loc)
}

// column_int assumes a 64-bit int, as on every target this package supports.
column_int :: proc(stmt: ^Stmt, col: int) -> int {
	if stmt.handle == nil do return 0
	return int(sqlite3_column_int64(stmt.handle, i32(col)))
}

column_int64 :: proc(stmt: ^Stmt, col: int) -> i64 {
	if stmt.handle == nil do return 0
	return sqlite3_column_int64(stmt.handle, i32(col))
}

column_float :: proc(stmt: ^Stmt, col: int) -> f64 {
	if stmt.handle == nil do return 0
	return sqlite3_column_double(stmt.handle, i32(col))
}

// column_text returns "" for both NULL and empty text; use column_is_null to
// tell them apart. SQLite requires the text call before the length call.
column_text :: proc(stmt: ^Stmt, col: int, allocator := context.allocator, loc := #caller_location) -> string {
	src := column_text_unsafe(stmt, col)
	if len(src) == 0 do return ""
	return strings.clone(src, allocator, loc)
}

// column_bytes returns nil for both NULL and an empty blob.
column_bytes :: proc(stmt: ^Stmt, col: int, allocator := context.allocator, loc := #caller_location) -> []byte {
	src := column_bytes_unsafe(stmt, col)
	if len(src) == 0 do return nil
	dst := make([]byte, len(src), allocator, loc)
	copy(dst, src)
	return dst
}

column_text_unsafe :: proc(stmt: ^Stmt, col: int) -> string {
	if stmt.handle == nil do return ""
	ptr := sqlite3_column_text(stmt.handle, i32(col))
	n := int(sqlite3_column_bytes(stmt.handle, i32(col)))
	if ptr == nil || n == 0 do return ""
	return string(ptr[:n])
}

column_bytes_unsafe :: proc(stmt: ^Stmt, col: int) -> []byte {
	if stmt.handle == nil do return nil
	ptr := sqlite3_column_blob(stmt.handle, i32(col))
	n := int(sqlite3_column_bytes(stmt.handle, i32(col)))
	if ptr == nil || n == 0 do return nil
	return ([^]byte)(ptr)[:n]
}

// --- Statement introspection ---------------------------------------------------------

// sql returns the statement's original SQL text.
sql :: proc(stmt: ^Stmt, allocator := context.allocator, loc := #caller_location) -> string {
	if stmt.handle == nil do return ""
	cstr := sqlite3_sql(stmt.handle)
	if cstr == nil do return ""
	return strings.clone_from_cstring(cstr, allocator, loc)
}

// expanded_sql returns the SQL text with bound values substituted in, for
// logging. Returns "" if SQLite could not allocate the expansion.
expanded_sql :: proc(stmt: ^Stmt, allocator := context.allocator, loc := #caller_location) -> string {
	if stmt.handle == nil do return ""
	cstr := sqlite3_expanded_sql(stmt.handle)
	if cstr == nil do return ""
	defer sqlite3_free(rawptr(cstr))
	return strings.clone_from_cstring(cstr, allocator, loc)
}

// stmt_readonly reports whether the statement makes no direct changes to
// the database.
stmt_readonly :: proc(stmt: ^Stmt) -> bool {
	if stmt.handle == nil do return false
	return sqlite3_stmt_readonly(stmt.handle) != 0
}

// --- Backup ------------------------------------------------------------------------------
// Copies a live database between two connections, for example ":memory:"
// to disk. Safe while the source is in use; pages changed mid-backup are
// copied again.

Backup :: struct {
	handle: ^sqlite3_backup,
	dest:   ^DB, // failures are recorded here, where SQLite reports them
}

Backup_Result :: enum {
	More, // call backup_step again
	Done, // the backup is complete
}

// backup_init starts copying database `source_name` (usually "main") of
// `source` into `dest_name` of `dest`. Always call backup_finish afterwards.
@(require_results)
backup_init :: proc(dest: ^DB, dest_name: string, source: ^DB, source_name: string) -> (backup: Backup, err: Error) {
	backup.dest = dest
	if dest.handle == nil || source.handle == nil {
		err = _fail(dest, .Misuse, "database is not open")
		return
	}
	cdest := strings.clone_to_cstring(dest_name)
	defer delete(cdest)
	csource := strings.clone_to_cstring(source_name)
	defer delete(csource)
	backup.handle = sqlite3_backup_init(dest.handle, cdest, source.handle, csource)
	if backup.handle == nil {
		err = _check(dest, sqlite3_extended_errcode(dest.handle))
	}
	return
}

// backup_step copies up to `n_pages` pages, or everything left if negative.
// .Busy and .Locked mean the source was locked for this attempt; they are
// not fatal, so the caller can wait and call backup_step again.
@(require_results)
backup_step :: proc(backup: ^Backup, n_pages: int = -1) -> (result: Backup_Result, err: Error) {
	if backup.handle == nil {
		return .Done, _fail(backup.dest, .Misuse, "backup is not initialized")
	}
	rc := sqlite3_backup_step(backup.handle, i32(clamp(n_pages, -1, int(max(i32)))))
	switch rc {
	case SQLITE_OK:   return .More, .Ok
	case SQLITE_DONE: return .Done, .Ok
	}
	return .More, _check(backup.dest, rc)
}

// backup_finish releases the backup. It returns the error from the last
// step, if any, without recording it again.
backup_finish :: proc(backup: ^Backup) -> Error {
	if backup.handle == nil do return .Ok
	rc := sqlite3_backup_finish(backup.handle)
	backup.handle = nil
	return _to_error(rc)
}

// backup_remaining and backup_pagecount reflect the most recent backup_step
// and can change between steps while the source is being written to.
backup_remaining :: proc(backup: ^Backup) -> int {
	if backup.handle == nil do return 0
	return int(sqlite3_backup_remaining(backup.handle))
}

backup_pagecount :: proc(backup: ^Backup) -> int {
	if backup.handle == nil do return 0
	return int(sqlite3_backup_pagecount(backup.handle))
}

// backup copies all of "main" from `source` into `dest` in one step. It does
// not retry on .Busy or .Locked; use the step API for that or for progress.
@(require_results)
backup :: proc(dest: ^DB, source: ^DB) -> Error {
	b := backup_init(dest, "main", source, "main") or_return
	defer backup_finish(&b)
	for {
		result := backup_step(&b, -1) or_return
		if result == .Done do return .Ok
	}
}

// --- WAL checkpointing ---------------------------------------------------------------
// Only meaningful for a file-backed database in WAL mode
// (PRAGMA journal_mode = WAL). An in-memory database cannot use WAL.

Checkpoint_Mode :: enum i32 {
	// Checkpoint what it can without waiting on other connections.
	Passive  = SQLITE_CHECKPOINT_PASSIVE,
	// Wait (up to the busy timeout) for writers, then checkpoint everything.
	Full     = SQLITE_CHECKPOINT_FULL,
	// Like Full, then also wait for readers so the next writer restarts the WAL.
	Restart  = SQLITE_CHECKPOINT_RESTART,
	// Like Restart, then truncate the WAL file to zero bytes.
	Truncate = SQLITE_CHECKPOINT_TRUNCATE,
}

// wal_checkpoint checkpoints `db_name` ("main", an attached name, or "" for
// all attached databases). It returns the number of frames in the WAL and
// the number checkpointed. On a database not in WAL mode both are -1 and
// err is .Ok.
@(require_results)
wal_checkpoint :: proc(db: ^DB, mode := Checkpoint_Mode.Passive, db_name: string = "") -> (n_log: int, n_checkpointed: int, err: Error) {
	if db.handle == nil {
		return 0, 0, _fail(db, .Misuse, "database is not open")
	}
	cname: cstring
	if db_name != "" {
		cname = strings.clone_to_cstring(db_name)
	}
	defer delete(cname)
	n_log32, n_ckpt32: i32
	rc := sqlite3_wal_checkpoint_v2(db.handle, cname, i32(mode), &n_log32, &n_ckpt32)
	return int(n_log32), int(n_ckpt32), _check(db, rc)
}

// --- Reflection-based row scanning ---------------------------------------------------
//
//   layout := sqlite.row_layout(&stmt, Account)
//   defer delete(layout.fields)
//   for {
//       result := sqlite.step(&stmt) or_return
//       if result == .Done do break
//       acct := sqlite.scan_row(&stmt, layout, Account)
//   }
//
// Columns are matched to struct fields by exact, case-sensitive name.
// Unmatched columns and fields are left alone. Supported field types are
// int, i64, f64, string, []byte and bool; nothing narrower than 64 bits,
// because STRICT does not limit integer width and a narrower field would
// silently truncate. A matched field of another type, or two result columns
// with the same matched name, is a programmer error and row_layout panics.

Field_Kind :: enum {
	Int,
	Int64,
	Float,
	Text,
	Blob,
	Bool,
}

Layout_Field :: struct {
	column: int,
	offset: uintptr,
	kind:   Field_Kind,
}

Row_Layout :: struct {
	type:   typeid,
	fields: []Layout_Field, // owned by the caller
}

// Exact type matches only: matching on Type_Info variant would accept i32
// or f32 fields, which the 8-byte writers in scan_row would overrun.
@(private)
_field_kind_of :: proc(info: ^runtime.Type_Info) -> (kind: Field_Kind, ok: bool) {
	switch info.id {
	case typeid_of(int):    return .Int, true
	case typeid_of(i64):    return .Int64, true
	case typeid_of(f64):    return .Float, true
	case typeid_of(string): return .Text, true
	case typeid_of([]byte): return .Blob, true
	case typeid_of(bool):   return .Bool, true
	}
	return {}, false
}

// row_layout maps a prepared statement's columns onto the fields of T.
// Build it once per statement and reuse it for every row; free it with
// delete(layout.fields).
row_layout :: proc(stmt: ^Stmt, $T: typeid, allocator := context.allocator, loc := #caller_location) -> Row_Layout {
	return _row_layout(stmt, T, allocator, loc)
}

@(private)
_row_layout :: proc(stmt: ^Stmt, T: typeid, allocator: runtime.Allocator, loc: runtime.Source_Code_Location) -> Row_Layout {
	names   := reflect.struct_field_names(T)
	offsets := reflect.struct_field_offsets(T)
	types   := reflect.struct_field_types(T)

	col_count := column_count(stmt)
	col_name :: proc(stmt: ^Stmt, col: int) -> string {
		return string(sqlite3_column_name(stmt.handle, i32(col)))
	}

	// Validate before allocating, so a panic can't strand the allocation
	// (relevant under testing.expect_assert).
	for col in 0 ..< col_count {
		name := col_name(stmt, col)
		for field_name, i in names {
			if name != field_name do continue
			if _, ok := _field_kind_of(types[i]); !ok {
				panic(_unsupported_field_message(field_name, T))
			}
			for col2 in 0 ..< col_count {
				if col2 != col && col_name(stmt, col2) == name {
					panic(_ambiguous_column_message(name, T))
				}
			}
			break
		}
	}

	fields := make([dynamic]Layout_Field, 0, col_count, allocator, loc)
	for col in 0 ..< col_count {
		name := col_name(stmt, col)
		for field_name, i in names {
			if name != field_name do continue
			kind, _ := _field_kind_of(types[i])
			append(&fields, Layout_Field{column = col, offset = offsets[i], kind = kind})
			break
		}
	}
	return Row_Layout{type = T, fields = fields[:]}
}

@(private)
_unsupported_field_message :: proc(field_name: string, T: typeid) -> string {
	return fmt.tprintf(
		"sqlite.row_layout: field %q of %v has a type scan_row doesn't support " +
		"(only int/i64/f64/string/[]byte/bool); retype the field or drop the column from the SELECT",
		field_name, T,
	)
}

@(private)
_ambiguous_column_message :: proc(col_name: string, T: typeid) -> string {
	return fmt.tprintf(
		"sqlite.row_layout: column %q appears more than once in the result set and matches " +
		"a field of %v; alias one of them in the SQL (e.g. `SELECT a.id, b.id AS b_id ...`)",
		col_name, T,
	)
}

// scan_row reads the current row into a T using a layout built by
// row_layout for the same statement and type. Text and blob fields are
// allocated with `allocator` and owned by the caller.
scan_row :: proc(stmt: ^Stmt, layout: Row_Layout, $T: typeid, allocator := context.allocator, loc := #caller_location) -> T {
	assert(layout.type == typeid_of(T), "sqlite.scan_row: layout was built for a different type", loc)

	result: T
	base := uintptr(&result)
	for f in layout.fields {
		field_ptr := rawptr(base + f.offset)
		switch f.kind {
		case .Int:   (^int)(field_ptr)^    = column_int(stmt, f.column)
		case .Int64: (^i64)(field_ptr)^    = column_int64(stmt, f.column)
		case .Float: (^f64)(field_ptr)^    = column_float(stmt, f.column)
		case .Text:  (^string)(field_ptr)^ = column_text(stmt, f.column, allocator, loc)
		case .Blob:  (^[]byte)(field_ptr)^ = column_bytes(stmt, f.column, allocator, loc)
		case .Bool:  (^bool)(field_ptr)^   = column_int(stmt, f.column) != 0
		}
	}
	return result
}
