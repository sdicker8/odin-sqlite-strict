// Source: https://github.com/sdicker8/odin-sqlite-strict (zlib license - see LICENSE)

package sqlite_strict

// Raw foreign bindings: a thin, 1:1 mirror of the subset of the SQLite C API
// this package uses. No ownership decisions and no error translation; those
// live in sqlite.odin.
//
// The library is expected next to this file. lib_build/ has scripts that
// produce it from an SQLite amalgamation; see the README for using a
// different build.
when ODIN_OS == .Windows {
	foreign import lib "sqlite3.lib"
} else {
	// Linux is tested. macOS and other Unix-likes use the same archive name
	// but have not been tested.
	foreign import lib "libsqlite3.a"
}

// Opaque handles, only ever passed back to C.
@(private)
sqlite3 :: struct {}
@(private)
sqlite3_stmt :: struct {}
@(private)
sqlite3_backup :: struct {}

// --- Primary result codes --------------------------------------------------
SQLITE_OK         :: 0
SQLITE_ERROR      :: 1
SQLITE_INTERNAL   :: 2
SQLITE_PERM       :: 3
SQLITE_ABORT      :: 4
SQLITE_BUSY       :: 5
SQLITE_LOCKED     :: 6
SQLITE_NOMEM      :: 7
SQLITE_READONLY   :: 8
SQLITE_INTERRUPT  :: 9
SQLITE_IOERR      :: 10
SQLITE_CORRUPT    :: 11
SQLITE_NOTFOUND   :: 12
SQLITE_FULL       :: 13
SQLITE_CANTOPEN   :: 14
SQLITE_PROTOCOL   :: 15
SQLITE_EMPTY      :: 16
SQLITE_SCHEMA     :: 17
SQLITE_TOOBIG     :: 18
SQLITE_CONSTRAINT :: 19
SQLITE_MISMATCH   :: 20
SQLITE_MISUSE     :: 21
SQLITE_NOLFS      :: 22
SQLITE_AUTH       :: 23
SQLITE_FORMAT     :: 24
SQLITE_RANGE      :: 25
SQLITE_NOTADB     :: 26
SQLITE_NOTICE     :: 27
SQLITE_WARNING    :: 28
SQLITE_ROW        :: 100
SQLITE_DONE       :: 101

// --- Extended result codes for SQLITE_CONSTRAINT ---------------------------
// The full extended set is in Extended_Error (sqlite.odin).
SQLITE_CONSTRAINT_CHECK      :: SQLITE_CONSTRAINT | (1 << 8)
SQLITE_CONSTRAINT_COMMITHOOK :: SQLITE_CONSTRAINT | (2 << 8)
SQLITE_CONSTRAINT_FOREIGNKEY :: SQLITE_CONSTRAINT | (3 << 8)
SQLITE_CONSTRAINT_FUNCTION   :: SQLITE_CONSTRAINT | (4 << 8)
SQLITE_CONSTRAINT_NOTNULL    :: SQLITE_CONSTRAINT | (5 << 8)
SQLITE_CONSTRAINT_PRIMARYKEY :: SQLITE_CONSTRAINT | (6 << 8)
SQLITE_CONSTRAINT_TRIGGER    :: SQLITE_CONSTRAINT | (7 << 8)
SQLITE_CONSTRAINT_UNIQUE     :: SQLITE_CONSTRAINT | (8 << 8)
SQLITE_CONSTRAINT_VTAB       :: SQLITE_CONSTRAINT | (9 << 8)
SQLITE_CONSTRAINT_ROWID      :: SQLITE_CONSTRAINT | (10 << 8)
SQLITE_CONSTRAINT_PINNED     :: SQLITE_CONSTRAINT | (11 << 8)
SQLITE_CONSTRAINT_DATATYPE   :: SQLITE_CONSTRAINT | (12 << 8)

// --- WAL checkpoint modes ----------------------------------------------------
SQLITE_CHECKPOINT_PASSIVE  :: 0
SQLITE_CHECKPOINT_FULL     :: 1
SQLITE_CHECKPOINT_RESTART  :: 2
SQLITE_CHECKPOINT_TRUNCATE :: 3

// --- Fundamental datatypes -----------------------------------------------------
SQLITE_INTEGER :: 1
SQLITE_FLOAT   :: 2
SQLITE_TEXT    :: 3
SQLITE_BLOB    :: 4
SQLITE_NULL    :: 5

// --- Text encodings ------------------------------------------------------------
SQLITE_UTF8 :: 1

// --- Open flags --------------------------------------------------------------
SQLITE_OPEN_READONLY  :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE    :: 0x00000004

// --- sqlite3_db_config options -------------------------------------------------
SQLITE_DBCONFIG_ENABLE_FKEY :: 1002
SQLITE_DBCONFIG_DQS_DML     :: 1013
SQLITE_DBCONFIG_DQS_DDL     :: 1014

// --- sqlite3_limit categories --------------------------------------------------
SQLITE_LIMIT_LENGTH              :: 0
SQLITE_LIMIT_SQL_LENGTH          :: 1
SQLITE_LIMIT_COLUMN              :: 2
SQLITE_LIMIT_EXPR_DEPTH          :: 3
SQLITE_LIMIT_COMPOUND_SELECT     :: 4
SQLITE_LIMIT_VDBE_OP             :: 5
SQLITE_LIMIT_FUNCTION_ARG        :: 6
SQLITE_LIMIT_ATTACHED            :: 7
SQLITE_LIMIT_LIKE_PATTERN_LENGTH :: 8
SQLITE_LIMIT_VARIABLE_NUMBER     :: 9
SQLITE_LIMIT_TRIGGER_DEPTH       :: 10
SQLITE_LIMIT_WORKER_THREADS      :: 11

// Destructor sentinels for the bind_text/bind_blob family. SQLITE_TRANSIENT
// makes SQLite copy the bytes before the call returns.
SQLITE_STATIC    :: rawptr(uintptr(0))
SQLITE_TRANSIENT :: rawptr(~uintptr(0)) // (sqlite3_destructor_type)-1

@(default_calling_convention = "c")
foreign lib {
	// --- library -------------------------------------------------------------
	sqlite3_initialize         :: proc() -> i32 ---
	sqlite3_shutdown           :: proc() -> i32 ---
	sqlite3_libversion_number  :: proc() -> i32 ---

	// --- open / close / configure ----------------------------------------------
	sqlite3_open_v2   :: proc(filename: cstring, db: ^^sqlite3, flags: i32, vfs: cstring) -> i32 ---
	sqlite3_close_v2  :: proc(db: ^sqlite3) -> i32 ---
	sqlite3_db_config :: proc(db: ^sqlite3, op: i32, #c_vararg args: ..any) -> i32 ---
	sqlite3_limit     :: proc(db: ^sqlite3, id: i32, new_val: i32) -> i32 ---

	// --- errors ----------------------------------------------------------------
	sqlite3_errmsg                :: proc(db: ^sqlite3) -> cstring ---
	sqlite3_errstr                :: proc(rc: i32) -> cstring ---
	sqlite3_errcode               :: proc(db: ^sqlite3) -> i32 ---
	sqlite3_extended_errcode      :: proc(db: ^sqlite3) -> i32 ---
	sqlite3_extended_result_codes :: proc(db: ^sqlite3, onoff: i32) -> i32 ---

	// --- prepare ---------------------------------------------------------------
	// `sql` need not be NUL-terminated when n_bytes >= 0.
	sqlite3_prepare_v2 :: proc(
		db:      ^sqlite3,
		sql:     [^]byte,
		n_bytes: i32,
		stmt:    ^^sqlite3_stmt,
		tail:    ^[^]byte,
	) -> i32 ---

	// --- parameter introspection -----------------------------------------------
	sqlite3_bind_parameter_count :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_bind_parameter_index :: proc(stmt: ^sqlite3_stmt, name: cstring) -> i32 ---
	sqlite3_bind_parameter_name  :: proc(stmt: ^sqlite3_stmt, idx: i32) -> cstring ---

	// --- bind ------------------------------------------------------------------
	sqlite3_bind_null   :: proc(stmt: ^sqlite3_stmt, idx: i32) -> i32 ---
	sqlite3_bind_int    :: proc(stmt: ^sqlite3_stmt, idx: i32, val: i32) -> i32 ---
	sqlite3_bind_int64  :: proc(stmt: ^sqlite3_stmt, idx: i32, val: i64) -> i32 ---
	sqlite3_bind_double :: proc(stmt: ^sqlite3_stmt, idx: i32, val: f64) -> i32 ---
	sqlite3_bind_text64 :: proc(
		stmt:       ^sqlite3_stmt,
		idx:        i32,
		text:       [^]byte,
		n_bytes:    u64,
		destructor: rawptr,
		encoding:   u8,
	) -> i32 ---
	sqlite3_bind_blob64 :: proc(
		stmt:       ^sqlite3_stmt,
		idx:        i32,
		data:       rawptr,
		n_bytes:    u64,
		destructor: rawptr,
	) -> i32 ---

	// --- step / reset / finalize -----------------------------------------------
	sqlite3_step           :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_reset          :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_finalize       :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_clear_bindings :: proc(stmt: ^sqlite3_stmt) -> i32 ---

	// --- columns ---------------------------------------------------------------
	sqlite3_column_count  :: proc(stmt: ^sqlite3_stmt) -> i32 ---
	sqlite3_column_type   :: proc(stmt: ^sqlite3_stmt, col: i32) -> i32 ---
	sqlite3_column_name   :: proc(stmt: ^sqlite3_stmt, col: i32) -> cstring ---
	sqlite3_column_int    :: proc(stmt: ^sqlite3_stmt, col: i32) -> i32 ---
	sqlite3_column_int64  :: proc(stmt: ^sqlite3_stmt, col: i32) -> i64 ---
	sqlite3_column_double :: proc(stmt: ^sqlite3_stmt, col: i32) -> f64 ---
	sqlite3_column_text   :: proc(stmt: ^sqlite3_stmt, col: i32) -> [^]byte ---
	sqlite3_column_blob   :: proc(stmt: ^sqlite3_stmt, col: i32) -> rawptr ---
	sqlite3_column_bytes  :: proc(stmt: ^sqlite3_stmt, col: i32) -> i32 ---

	// --- connection state ------------------------------------------------------
	sqlite3_last_insert_rowid :: proc(db: ^sqlite3) -> i64 ---
	sqlite3_changes64         :: proc(db: ^sqlite3) -> i64 ---
	sqlite3_total_changes64   :: proc(db: ^sqlite3) -> i64 ---
	sqlite3_busy_timeout      :: proc(db: ^sqlite3, ms: i32) -> i32 ---
	sqlite3_interrupt         :: proc(db: ^sqlite3) ---

	// --- statement introspection -----------------------------------------------
	sqlite3_sql           :: proc(stmt: ^sqlite3_stmt) -> cstring ---
	sqlite3_expanded_sql  :: proc(stmt: ^sqlite3_stmt) -> cstring ---
	sqlite3_stmt_readonly :: proc(stmt: ^sqlite3_stmt) -> i32 ---

	// --- backup ----------------------------------------------------------------
	sqlite3_backup_init      :: proc(dest: ^sqlite3, dest_name: cstring, source: ^sqlite3, source_name: cstring) -> ^sqlite3_backup ---
	sqlite3_backup_step      :: proc(backup: ^sqlite3_backup, n_page: i32) -> i32 ---
	sqlite3_backup_finish    :: proc(backup: ^sqlite3_backup) -> i32 ---
	sqlite3_backup_remaining :: proc(backup: ^sqlite3_backup) -> i32 ---
	sqlite3_backup_pagecount :: proc(backup: ^sqlite3_backup) -> i32 ---

	// --- WAL checkpointing -----------------------------------------------------
	sqlite3_wal_checkpoint_v2 :: proc(db: ^sqlite3, db_name: cstring, mode: i32, n_log: ^i32, n_ckpt: ^i32) -> i32 ---

	// --- misc --------------------------------------------------------------------
	// Not used by the wrapper; kept as an escape hatch for callers.
	sqlite3_exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> i32 ---
	sqlite3_free :: proc(ptr: rawptr) ---
}
