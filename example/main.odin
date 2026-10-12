package main

import "core:fmt"
import sqlite "../"

// Moves `amount` between two accounts. The CHECK (balance >= 0) constraint
// rejects an overdraft, the deferred rollback undoes any partial work, and
// the error propagates to the caller.
transfer_manual :: proc(db: ^sqlite.DB, from, to: int, amount: int) -> sqlite.Error {
	tx := sqlite.begin(db) or_return
	defer sqlite.rollback(&tx)

	debit := sqlite.prepare(db, "UPDATE accounts SET balance = balance - ?1 WHERE id = ?2;") or_return
	defer sqlite.finalize(&debit)
	sqlite.bind(&debit, 1, amount) or_return
	sqlite.bind(&debit, 2, from) or_return
	_ = sqlite.step(&debit) or_return

	credit := sqlite.prepare(db, "UPDATE accounts SET balance = balance + ?1 WHERE id = ?2;") or_return
	defer sqlite.finalize(&credit)
	sqlite.bind(&credit, 1, amount) or_return
	sqlite.bind(&credit, 2, to) or_return
	_ = sqlite.step(&credit) or_return

	return sqlite.commit(&tx)
}

// The same transfer for with_transaction, which owns begin, rollback and
// commit. Arguments arrive through user_data.
Transfer_Args :: struct {
	from, to, amount: int,
}

transfer_body :: proc(tx: ^sqlite.Tx, user_data: rawptr) -> sqlite.Error {
	args := (^Transfer_Args)(user_data)^
	sqlite.execute(tx.db, "UPDATE accounts SET balance = balance - ?1 WHERE id = ?2;", {args.amount, args.from}) or_return
	sqlite.execute(tx.db, "UPDATE accounts SET balance = balance + ?1 WHERE id = ?2;", {args.amount, args.to}) or_return
	return .Ok
}

print_balances :: proc(db: ^sqlite.DB) -> sqlite.Error {
	query := sqlite.prepare(db, "SELECT id, name, balance FROM accounts ORDER BY id;") or_return
	defer sqlite.finalize(&query)

	for {
		result := sqlite.step(&query) or_return
		if result == .Done do break

		id := sqlite.column_int(&query, 0)
		name := sqlite.column_text(&query, 1)
		defer delete(name)
		balance := sqlite.column_int(&query, 2)

		fmt.printf("  #%d %-6s balance=%d\n", id, name, balance)
	}
	return .Ok
}

// Field names match the column names in the SELECT.
Account_Row :: struct {
	id:      int,
	name:    string,
	balance: int,
}

print_balances_scanned :: proc(db: ^sqlite.DB) -> sqlite.Error {
	query := sqlite.prepare(db, "SELECT id, name, balance FROM accounts ORDER BY id;") or_return
	defer sqlite.finalize(&query)

	layout := sqlite.row_layout(&query, Account_Row)
	defer delete(layout.fields)

	for {
		result := sqlite.step(&query) or_return
		if result == .Done do break

		row := sqlite.scan_row(&query, layout, Account_Row)
		defer delete(row.name)

		fmt.printf("  #%d %-6s balance=%d\n", row.id, row.name, row.balance)
	}
	return .Ok
}

report_failure :: proc(db: ^sqlite.DB, err: sqlite.Error) {
	msg := sqlite.error_string(db)
	defer delete(msg)
	fmt.eprintfln("transfer failed and was rolled back: %v (%s)", err, msg)
}

run :: proc(db: ^sqlite.DB) -> sqlite.Error {
	sqlite.execute(db, `
		CREATE TABLE accounts (
			id      INTEGER PRIMARY KEY,
			name    TEXT NOT NULL,
			balance INTEGER NOT NULL CHECK (balance >= 0)
		) STRICT;
	`) or_return

	insert := sqlite.prepare(db, "INSERT INTO accounts (name, balance) VALUES (?1, ?2);") or_return
	defer sqlite.finalize(&insert)
	Seed :: struct {
		name:    string,
		balance: int,
	}
	for s in ([]Seed{{"Alice", 100}, {"Bob", 50}}) {
		sqlite.bind(&insert, 1, s.name) or_return
		sqlite.bind(&insert, 2, s.balance) or_return
		_ = sqlite.step(&insert) or_return
		sqlite.reset(&insert) or_return
	}

	fmt.println("starting balances:")
	print_balances(db) or_return

	fmt.println("\nbonus for Bob via execute() with params:")
	sqlite.execute(db, "UPDATE accounts SET balance = balance + ?1 WHERE id = ?2;", {10, 2}) or_return
	print_balances(db) or_return

	fmt.println("\ntransfer 30 from Alice to Bob:")
	if err := transfer_manual(db, 1, 2, 30); err != .Ok {
		report_failure(db, err)
	}
	print_balances(db) or_return

	fmt.println("\ntransfer 1000 from Alice to Bob (overdraft):")
	args := Transfer_Args{from = 1, to = 2, amount = 1000}
	if err := sqlite.with_transaction(db, transfer_body, &args); err != .Ok {
		report_failure(db, err)
	}
	print_balances(db) or_return

	fmt.println("\nsame state, read with scan_row:")
	return print_balances_scanned(db)
}

main :: proc() {
	db, err := sqlite.open(":memory:")
	defer sqlite.close(&db)
	if err == .Ok {
		err = run(&db)
	}
	if err != .Ok {
		msg := sqlite.error_string(&db)
		defer delete(msg)
		fmt.eprintfln("sqlite error: %v (%s)", err, msg)
	}
}
