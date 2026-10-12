# Contributing

Thanks for your interest. This is a small package with a narrow scope, and
that shapes how contributions work.

## Open an issue first

For anything beyond a small, obvious fix, please open an issue describing
the change before writing a pull request. Most of what might look like a gap
was decided on purpose, and the README usually explains why. Talking it
through first saves both of us time.

The README's "Not covered" section lists features that are out of scope for
now but could be added if there is a real need.

## Running the tests

The package links a static SQLite library, so build that first:

1. Run `lib_build/build_sqlite_lib.sh` (Linux and macOS) or
   `lib_build\build_sqlite_lib.bat` (Windows, from an x64 Native Tools
   Command Prompt for VS) with the path to an extracted SQLite amalgamation.
   See "Building" in the README.
2. Run `odin test .` from the package root. Also check that
   `odin check . -no-entry-point -vet -strict-style` reports nothing.

A pull request that changes behavior should include a test that fails
without the change. Tests are grouped under section comments in
`sqlite_test.odin`.

## Code style

- Follow the existing conventions rather than adding a second way to do the
  same thing: errors are returned as `Error` and composed with `or_return`;
  memory the package hands back is owned by the caller and freed with
  `delete`; a closed or unopened handle gives `.Misuse`; code that cannot
  match its query (such as an unsupported `scan_row` field) panics.
- Allocating procs take `allocator := context.allocator` and
  `loc := #caller_location` and pass both through.
- Comments explain why code is the way it is: an SQLite quirk, an Odin
  constraint, a rejected alternative. Keep them short, and leave out the
  history of how the code got there.

## Scope

The package aims to stay a thin wrapper over the SQLite API. Something that
adds a layer on top, such as an ORM, a query builder or a connection pool,
is a better fit for a separate package built on this one.
