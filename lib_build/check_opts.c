#include "sqlite3.h"
#include <stdio.h>
int main(void) {
    sqlite3_initialize();
    sqlite3 *db;
    int rc = sqlite3_open(":memory:", &db);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "open failed: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    sqlite3_stmt *stmt;
    rc = sqlite3_prepare_v2(db, "PRAGMA compile_options;", -1, &stmt, 0);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "prepare failed: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    while (sqlite3_step(stmt) == SQLITE_ROW)
        printf("%s\n", sqlite3_column_text(stmt, 0));
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return 0;
}
