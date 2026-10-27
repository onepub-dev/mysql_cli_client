/* Copyright (C) OnePub IP Pty Ltd - All Rights Reserved
 * Unauthorized copying of this file, via any medium is strictly prohibited
 * Proprietary and confidential
 * Written by Brett Sutton <bsutton@onepub.dev>, Jan 2022
 */

import 'dart:convert';
import 'dart:io';

import 'mysql_parser.dart';

/// A redacted failure. Raw client diagnostics, SQL and credentials are omitted.
class MySQLException implements Exception {
  MySQLException(this.operation, {this.exitCode});
  final String operation;
  final int? exitCode;

  @override
  String toString() => 'MySQLException: $operation failed'
      '${exitCode == null ? '' : ' (exit code $exitCode)'}';
}

/// Receives stdout only; diagnostics are intentionally not forwarded.
/// Callbacks run after completion. [exitCode] is set even with noThrow.
class MySQLProgress {
  MySQLProgress({this.stdout});
  final void Function(String line)? stdout;
  int? exitCode;
}

/// Process boundary for synthetic testing. Implementations are trusted and can
/// see credentials and SQL. Never log requests or raw failures.
abstract class MySQLProcessRunner {
  Future<MySQLProcessResult> run(String executable, List<String> arguments,
      {required Map<String, String> environment,
      required Stream<List<int>> input});

  MySQLProcessResult runSync(String executable, List<String> arguments,
      {required Map<String, String> environment});
}

class MySQLProcessResult {
  MySQLProcessResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

class _ProcessRunner implements MySQLProcessRunner {
  const _ProcessRunner();

  @override
  Future<MySQLProcessResult> run(String executable, List<String> arguments,
      {required Map<String, String> environment,
      required Stream<List<int>> input}) async {
    final process = await Process.start(executable, arguments,
        environment: environment,
        // Explicitly retain the security boundary even though false is default.
        // ignore: avoid_redundant_argument_values
        runInShell: false);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    Future<void> writeInput() async {
      await process.stdin.addStream(input);
      await process.stdin.close();
    }

    try {
      final results = await Future.wait<Object?>([
        output,
        errors,
        process.exitCode,
        writeInput(),
      ], eagerError: true);
      return MySQLProcessResult(
          results[2]! as int, results[0]! as String, results[1]! as String);
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.stdin.close().catchError((Object _) {});
      await process.exitCode;
      await output;
      await errors;
      rethrow;
    }
  }

  @override
  MySQLProcessResult runSync(String executable, List<String> arguments,
      {required Map<String, String> environment}) {
    final result = Process.runSync(executable, arguments,
        environment: environment,
        // ignore: avoid_redundant_argument_values
        runInShell: false);
    return MySQLProcessResult(
        result.exitCode, result.stdout as String, result.stderr as String);
  }
}

class MySQL {
  MySQL(
      {required this.user,
      required this.password,
      required this.schema,
      this.host = '127.0.0.1',
      this.port = 3306,
      MySQLProcessRunner? runner})
      : _runner = runner ?? const _ProcessRunner();

  String user;
  String password;
  String schema;
  String host;
  int port;
  final MySQLProcessRunner _runner;

  // Restrict names to avoid wildcard semantics in GRANT database patterns.
  String _schemaIdentifier() {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(schema)) {
      throw ArgumentError(
          'Schema must be 1–64 ASCII letters/digits, starting with a letter.');
    }
    return '`$schema`';
  }

  static String _literal(String value) {
    // Doubled apostrophes work with and without NO_BACKSLASH_ESCAPES.
    // Reject mode-dependent backslashes and client line/control syntax.
    if (value.runes.any((c) => c < 32 || c == 127 || c == 92)) {
      throw ArgumentError(
          'Account values cannot contain backslashes or control characters.');
    }
    return "'${value.replaceAll("'", "''")}'";
  }

  List<String> _connection({bool noschema = false}) {
    if (port < 1 || port > 65535) {
      throw ArgumentError('Port must be between 1 and 65535.');
    }
    return [
      '--user=$user',
      '--host=$host',
      '--port=$port',
      if (!noschema) '--database=$schema'
    ];
  }

  Map<String, String> _environment() => {'MYSQL_PWD': password};

  Future<MySQLProcessResult> _execute(
      List<String> args, Stream<List<int>> input, String operation) async {
    try {
      return await _runner.run('mysql', List.unmodifiable(args),
          environment: Map.unmodifiable(_environment()), input: input);
    } on Object catch (_) {
      throw MySQLException(operation);
    }
  }

  void _check(MySQLProcessResult result, String operation) {
    if (result.exitCode != 0) {
      throw MySQLException(operation, exitCode: result.exitCode);
    }
  }

  Stream<List<int>> _sqlInput(String sql) => Stream.value(utf8.encode(sql));

  Future<void> dropSchema() async {
    final identifier = _schemaIdentifier();
    await run('DROP DATABASE IF EXISTS $identifier;', noschema: true);
  }

  Future<void> createSchema() async {
    final identifier = _schemaIdentifier();
    await run('CREATE DATABASE IF NOT EXISTS $identifier;', noschema: true);
  }

  Future<void> createUser(
      {required String username, required String password}) async {
    final identifier = _schemaIdentifier();
    final account = '${_literal(username)}@${_literal(host)}';
    final secret = _literal(password);
    await run(
        'DROP USER IF EXISTS $account;\n'
        'CREATE USER $account IDENTIFIED BY $secret;\n'
        'GRANT ALL ON $identifier.* TO $account;\n'
        'FLUSH PRIVILEGES;',
        noschema: true,
        progress: MySQLProgress());
  }

  /// Streams the exact file bytes into mysql. Source failures always throw.
  Future<void> restore(String sourcePath) async {
    final result = await _execute([..._connection(), '--binary-mode'],
        File(sourcePath).openRead(), 'restore');
    _check(result, 'restore');
  }

  /// Synchronous for compatibility. Set [columnStatistics] only when supported
  /// by the installed mysqldump; no credential-bearing version probe is made.
  void backup(String savePath, {bool? columnStatistics}) {
    _schemaIdentifier();
    final args = [
      ..._connection(noschema: true),
      '--routines',
      '--result-file=$savePath',
      if (columnStatistics != null)
        '--column-statistics=${columnStatistics ? 1 : 0}',
      '--',
      schema
    ];
    MySQLProcessResult result;
    try {
      result = _runner.runSync('mysqldump', List.unmodifiable(args),
          environment: Map.unmodifiable(_environment()));
    } on Object catch (_) {
      throw MySQLException('backup');
    }
    _check(result, 'backup');
  }

  Future<List<String>> toList(String sql,
      {bool noschema = false, bool table = false}) async {
    final result = await _execute([
      ..._connection(noschema: noschema),
      '--binary-mode',
      if (table) '--table' else '--batch',
    ], _sqlInput(sql), 'query');
    _check(result, 'query');
    if (table) {
      return const LineSplitter().convert(result.stdout);
    }
    if (result.stdout.isEmpty) {
      return [];
    }
    // Batch records end at LF only: raw CR is field data, even before LF.
    final lines = result.stdout.split('\n');
    if (lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  /// Uses escaped batch output. Supply one SELECT per call. Values are strings,
  /// including SQL NULL; multiple result sets cannot be represented.
  Future<RecordSet> runMysqlQuery(String sqlQuery) async =>
      MySQLParser.parseBatch(await toList(sqlQuery));

  Future<void> run(String sql,
          {bool noschema = false,
          bool noThrow = false,
          MySQLProgress? progress}) =>
      runFromArgs(sql, const [],
          noschema: noschema, noThrow: noThrow, progress: progress);

  /// [args] is an intentional, trusted client-option interface. It is copied.
  /// SQL is intentional executable input, sent unchanged through stdin.
  Future<void> runFromArgs(String sql, List<String> args,
      {bool noschema = false,
      bool noThrow = false,
      MySQLProgress? progress}) async {
    final result = await _execute([
      ...args,
      ..._connection(noschema: noschema),
      '--binary-mode',
    ], _sqlInput(sql), 'query');
    progress?.exitCode = result.exitCode;
    if (!noThrow) {
      _check(result, 'query');
    }
    for (final line in const LineSplitter().convert(result.stdout)) {
      if (progress == null) {
        // Retained public run() output behavior; diagnostics never reach here.
        // ignore: avoid_print
        print(line);
      } else {
        progress.stdout?.call(line);
      }
    }
  }

  /// Retries failed commands; launch/I/O failures throw. Unlike 1.x, access
  /// denied does not count as a usable connection. No diagnostics are printed.
  Future<void> waitForMysql(
      {Duration retryDelay = const Duration(seconds: 10)}) async {
    while (true) {
      final progress = MySQLProgress();
      await run('SELECT 1;', noschema: true, noThrow: true, progress: progress);
      if (progress.exitCode == 0) {
        return;
      }
      await Future<void>.delayed(retryDelay);
    }
  }
}
