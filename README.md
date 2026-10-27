# mysql_cli_client

A Dart wrapper for installed `mysql` and `mysqldump` command-line clients.
Version 2.0.0 requires Dart 3.13.0 or later and has no runtime package dependencies.

```dart
import 'package:mysql_cli_client/mysql_cli_client.dart';

final mysql = MySQL(
  user: 'root', password: adminPassword, schema: 'exampledb', port: 3306,
);
await mysql.waitForMysql();
mysql.backup('backup folder/database.sql'); // synchronous
await mysql.createSchema();
await mysql.restore('backup folder/database.sql');
await mysql.createUser(username: 'appuser', password: newAccountPassword);
final records = await mysql.runMysqlQuery('SELECT id, name FROM users;');
```

## Migrating from 1.x

- Replace dcli `Progress` with `MySQLProgress(stdout: (line) { ... })`. Callbacks receive stdout lines after the child completes. The `exitCode` is recorded; an empty `MySQLProgress()` discards stdout. Raw stderr is never forwarded. `run` still prints stdout by default. `noThrow: true` suppresses only nonzero child exits, not startup or I/O failures.
- SQL now travels unchanged as UTF-8 stdin, with `--binary-mode`, rather than through `-e` arguments. SQL and passwords are absent from wrapper logs and exceptions. Exceptions expose only operation and exit code; they intentionally omit raw diagnostics. A client can still echo sensitive data to stdout, which callers must handle appropriately.
- `backup` remains synchronous. Version detection was removed. For a compatible MySQL 8 client, request `backup(path, columnStatistics: false)` to disable column statistics explicitly. The default omits that option for compatibility with clients that do not support it.
- Provisioning helpers (`createSchema`, `dropSchema`, `createUser`) and `backup` accept schema names matching `[A-Za-z][A-Za-z0-9]{0,63}`. Helpers quote identifiers with backticks. Underscores and percent signs are deliberately excluded because database names in `GRANT` can act as wildcard patterns. Existing schemas outside this policy can still be selected by query/restore APIs; use explicitly trusted SQL/options for other administrative operations.
- Account names, account hosts and new passwords support spaces, apostrophes (doubled in SQL), Unicode and common punctuation. Backslashes, ASCII control characters and DEL are rejected without echoing the rejected value. This avoids dependence on `NO_BACKSLASH_ESCAPES`; choose a compatible strong password. Authentication passwords are passed unchanged in the child environment and do not have these SQL-literal restrictions.
- `waitForMysql` waits for successful authenticated `SELECT 1`, indefinitely retrying nonzero exits. Access denied no longer means ready. Missing executables and I/O failures throw. `retryDelay` defaults to ten seconds.
- `runMysqlQuery` uses escaped tab-separated batch output instead of visual tables. `toList(table: true)` still requests human-readable tables. Legacy `MySQLParser.parseResults` rejects malformed tables and multiple tables with a generic `FormatException`; it never prints diagnostic lines.

## Execution and trust boundaries

Arguments are literal `dart:io` argument lists with `runInShell: false`. There is no dcli splitting, glob/tilde expansion, trimming or quote removal. Connection values use single `--option=value` arguments. Backup validates the schema and uses an option terminator. Paths containing spaces or starting with a dash remain literal; restore reads the selected file directly and streams its exact bytes to stdin. Both operations use the configured port. Restore source errors and child failures propagate as redacted exceptions; a failed restore can already have applied some SQL. A failed backup may leave a partial destination file.

Every child gets a separate `MYSQL_PWD` override containing the connection password. The library never changes ambient environment maps and performs no version probe. Other environment variables and normal client configuration files are inherited. Use trusted installed executables, PATH and client defaults. Child environment credentials remain accessible to sufficiently privileged OS observers and the client itself; this wrapper does not provide a secret vault. A custom `MySQLProcessRunner` is a trusted testing boundary with access to SQL and credentials.

`run`, `toList`, `runMysqlQuery` and restore intentionally execute supplied SQL. `runFromArgs` intentionally permits trusted client options and copies its argument list. Neither interface is a sandbox for hostile SQL, options or dump contents. `createUser` retains its destructive drop/recreate behavior and grants all privileges on the selected schema; it is not atomic.

MySQL documents that [`--binary-mode`](https://dev.mysql.com/doc/refman/8.0/en/mysql-command-options.html) disables most client commands in noninteractive input, with exceptions including `charset` and `delimiter`. The generated account SQL rejects line/control characters and backslashes so values cannot become such commands. [MySQL string literal rules](https://dev.mysql.com/doc/refman/8.0/en/string-literals.html) permit doubled apostrophes; rejecting backslashes avoids SQL-mode-dependent interpretation. Compatibility with all MariaDB/MySQL versions is not guaranteed.

## Result limitations

Batch parsing preserves whitespace, empty fields and embedded pipes, decoding MySQL's `\n`, `\t`, `\0` and `\\` escapes. It validates column counts and rejects malformed escapes without including source data in errors. All values are strings: SQL NULL and literal `NULL` cannot be distinguished. Submit one result-producing statement per `runMysqlQuery` call: batch output has no unambiguous result-set delimiter, so another same-width header cannot reliably be detected. Client notices and unsupported output formats are not structured results.

Legacy visual-table parsing trims presentation padding and cannot recover significant surrounding whitespace or embedded pipes reliably. Use batch parsing for data. Query stdout is buffered in memory; restore input is streamed. Output callbacks are not live progress notifications, and the API does not provide cancellation/timeouts.

## Development

Tests inject a synthetic `MySQLProcessRunner`; they never launch `mysql` or `mysqldump`, interpret test SQL or connect to a database. They verify argv, stdin, environment isolation, helper encoding, failures and parser fixtures. This verifies the wrapper boundary, not every installed client's interpretation of options.

```console
dart pub get
dart analyze
dart test
```
