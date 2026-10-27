import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mysql_cli_client/mysql_cli_client.dart';
import 'package:test/test.dart';

class Request {
  Request(this.executable, this.args, this.environment);
  final String executable;
  final List<String> args;
  final Map<String, String> environment;
  List<int> input = [];
}

class FakeRunner implements MySQLProcessRunner {
  final requests = <Request>[];
  MySQLProcessResult result = MySQLProcessResult(0, '', '');
  Object? failure;
  Completer<void>? gate;

  @override
  Future<MySQLProcessResult> run(String executable, List<String> arguments,
      {required Map<String, String> environment,
      required Stream<List<int>> input}) async {
    final request =
        Request(executable, List.of(arguments), Map.of(environment));
    requests.add(request);
    request.input = await input.expand((bytes) => bytes).toList();
    if (gate != null) {
      await gate!.future;
    }
    if (failure != null) {
      // Synthetic runner deliberately supports arbitrary process-layer errors.
      // ignore: only_throw_errors
      throw failure!;
    }
    return result;
  }

  @override
  MySQLProcessResult runSync(String executable, List<String> arguments,
      {required Map<String, String> environment}) {
    requests.add(Request(executable, List.of(arguments), Map.of(environment)));
    if (failure != null) {
      // ignore: only_throw_errors
      throw failure!;
    }
    return result;
  }
}

MySQL client(FakeRunner runner,
        {String password = 'dummy-admin', String schema = 'exampledb'}) =>
    MySQL(
        user: ' admin ~ * " ',
        password: password,
        schema: schema,
        host: 'host name',
        port: 4407,
        runner: runner);

void main() {
  test('SQL stdin and scalar argv are exact; caller options are not mutated',
      () async {
    final runner = FakeRunner();
    final mysql = client(runner, schema: '--schema with spaces');
    final args = ['--connect-timeout=5'];
    const sql = '  SELECT \'~ * "\';\n';
    await mysql.runFromArgs(sql, args, progress: MySQLProgress());
    expect(args, ['--connect-timeout=5']);
    final request = runner.requests.single;
    expect(request.executable, 'mysql');
    expect(request.args, [
      '--connect-timeout=5',
      '--user= admin ~ * " ',
      '--host=host name',
      '--port=4407',
      '--database=--schema with spaces',
      '--binary-mode'
    ]);
    expect(utf8.decode(request.input), sql);
    expect(request.environment, {'MYSQL_PWD': 'dummy-admin'});
    expect(request.args.join(' '), isNot(contains(sql)));
  });

  test('separate admin and new account password; apostrophes are doubled',
      () async {
    final runner = FakeRunner();
    final mysql = client(runner)..host = "ho'st";
    await mysql.createUser(username: "u'ser", password: "dummy-new ' !@#~* é");
    final request = runner.requests.single;
    expect(request.environment, {'MYSQL_PWD': 'dummy-admin'});
    expect(request.args.any((a) => a.contains('dummy-new')), isFalse);
    expect(request.args, isNot(contains('--database=exampledb')));
    final sql = utf8.decode(request.input);
    expect(sql, contains("'u''ser'@'ho''st'"));
    expect(sql, contains("IDENTIFIED BY 'dummy-new '' !@#~* é'"));
    expect(sql, contains('GRANT ALL ON `exampledb`.*'));
  });

  test('unsafe account values fail before launch without echoing values',
      () async {
    for (final value in [
      r'bad\value',
      'bad\nvalue',
      'bad\rvalue',
      'bad\x00value',
      'bad\x7fvalue'
    ]) {
      final runner = FakeRunner();
      final mysql = client(runner);
      await expectLater(mysql.createUser(username: value, password: 'dummy'),
          throwsArgumentError);
      await expectLater(mysql.createUser(username: 'user', password: value),
          throwsArgumentError);
      mysql.host = value;
      await expectLater(mysql.createUser(username: 'user', password: 'dummy'),
          throwsArgumentError);
      expect(runner.requests, isEmpty);
    }
  });

  test('schema helpers and backup reject ambiguous names', () async {
    for (final schema in [
      '',
      '-option',
      'db_name',
      'db%',
      'a b',
      'a`b',
      '1db',
      'a' * 65
    ]) {
      final runner = FakeRunner();
      final mysql = client(runner, schema: schema);
      await expectLater(mysql.createSchema(), throwsArgumentError);
      await expectLater(mysql.dropSchema(), throwsArgumentError);
      await expectLater(mysql.createUser(username: 'u', password: 'dummy'),
          throwsArgumentError);
      expect(() => mysql.backup('not-created.sql'), throwsArgumentError);
      expect(runner.requests, isEmpty);
    }
  });

  test('schema DDL is quoted and does not select the nonexistent schema',
      () async {
    final runner = FakeRunner();
    await client(runner).createSchema();
    await client(runner).dropSchema();
    expect(utf8.decode(runner.requests.first.input),
        'CREATE DATABASE IF NOT EXISTS `exampledb`;');
    expect(utf8.decode(runner.requests.last.input),
        'DROP DATABASE IF EXISTS `exampledb`;');
    expect(runner.requests.first.args.any((a) => a.startsWith('--database=')),
        isFalse);
  });

  test('backup uses one launch, literal destination, configured port, no probe',
      () {
    final runner = FakeRunner();
    client(runner).backup('-backup with spaces.sql', columnStatistics: false);
    final request = runner.requests.single;
    expect(request.executable, 'mysqldump');
    expect(request.args, [
      '--user= admin ~ * " ',
      '--host=host name',
      '--port=4407',
      '--routines',
      '--result-file=-backup with spaces.sql',
      '--column-statistics=0',
      '--',
      'exampledb'
    ]);
    expect(request.environment, {'MYSQL_PWD': 'dummy-admin'});
    expect(request.input, isEmpty);
  });

  test(
      'restore forwards exact bytes and literal filename including dash/spaces',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('mysql-wrapper-test-');
    try {
      final file = File('${directory.path}/-input with spaces.sql');
      final bytes = [0, 13, 10, 32, 255, 92, 126];
      await file.writeAsBytes(bytes);
      final runner = FakeRunner();
      await client(runner).restore(file.path);
      expect(runner.requests.single.input, bytes);
      expect(runner.requests.single.args, contains('--port=4407'));
      expect(runner.requests.single.args, contains('--binary-mode'));
      expect(runner.requests.single.args.join(' '), isNot(contains(file.path)));
      runner.result = MySQLProcessResult(9, '', 'private diagnostics');
      await expectLater(
          client(runner).restore(file.path), throwsA(isA<MySQLException>()));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('restore source failure propagates without path or raw diagnostic',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('mysql-wrapper-missing-');
    try {
      await expectLater(
          client(FakeRunner()).restore('${directory.path}/missing'),
          throwsA(isA<MySQLException>().having((e) => e.toString(), 'redacted',
              'MySQLException: restore failed')));
    } finally {
      await directory.delete();
    }
  });

  test('failures redact SQL, stderr, and thrown process details', () async {
    final runner = FakeRunner()
      ..result = MySQLProcessResult(7, '', 'dummy-admin dummy-new private SQL');
    final mysql = client(runner);
    await expectLater(
        mysql.createUser(username: 'u', password: 'dummy-new'),
        throwsA(isA<MySQLException>().having((e) => e.toString(), 'message',
            'MySQLException: query failed (exit code 7)')));
    expect(() => mysql.backup('somewhere'), throwsA(isA<MySQLException>()));
    runner.failure =
        const ProcessException('mysql', ['dummy-new'], 'dummy-admin');
    await expectLater(
        mysql.toList('private SQL'),
        throwsA(isA<MySQLException>().having(
            (e) => e.toString(), 'message', 'MySQLException: query failed')));
    expect(
        () => mysql.backup('somewhere'),
        throwsA(isA<MySQLException>().having(
            (e) => e.toString(), 'message', 'MySQLException: backup failed')));
  });

  test('overlapping calls retain independent environment snapshots on failure',
      () async {
    final runner = FakeRunner()..gate = Completer<void>();
    final mysql = client(runner, password: 'dummy-first');
    final first = mysql.toList('first');
    mysql.password = 'dummy-second';
    final second = mysql.toList('second');
    client(runner, password: 'dummy-third').backup('unused');
    runner.gate!.complete();
    await Future.wait([first, second]);
    expect(runner.requests.map((r) => r.environment['MYSQL_PWD']),
        ['dummy-first', 'dummy-second', 'dummy-third']);
    runner.failure = StateError('dummy-second');
    await expectLater(mysql.toList('failing'), throwsA(isA<MySQLException>()));
    runner.failure = null;
    await client(runner, password: 'dummy-next').toList('next');
    expect(runner.requests.first.environment, {'MYSQL_PWD': 'dummy-first'});
    expect(runner.requests.last.environment, {'MYSQL_PWD': 'dummy-next'});
  });

  test('progress exposes stdout and exit status, never stderr', () async {
    final runner = FakeRunner()
      ..result = MySQLProcessResult(4, 'one\ntwo\n', 'private diagnostics');
    final lines = <String>[];
    final progress = MySQLProgress(stdout: lines.add);
    await client(runner).run('SELECT 1', noThrow: true, progress: progress);
    expect(progress.exitCode, 4);
    expect(lines, ['one', 'two']);
  });

  test('runMysqlQuery requests batch output and preserves field data',
      () async {
    final runner = FakeRunner()
      ..result = MySQLProcessResult(0, 'a\tb\n  x|y  \t\n', 'ignored');
    final records = await client(runner).runMysqlQuery('SELECT a, b');
    expect(runner.requests.single.args, contains('--batch'));
    expect(records.rows.single.values, ['  x|y  ', '']);
  });

  test('batch parser decodes escaped fields and keeps empty rows', () {
    const escaped = r'one\ntwo\t\0\\';
    final records = MySQLParser.parseBatch(['a\tb', '$escaped\t x|y ']);
    expect(records.rows.single.values, ['one\ntwo\t\x00\\', ' x|y ']);
    expect(MySQLParser.parseBatch(['a', '']).rows.single.values, ['']);
    expect(MySQLParser.parseBatch([]).rows, isEmpty);
    expect(
        () => MySQLParser.parseBatch(['a\tb', 'one']), throwsFormatException);
    expect(
        () => MySQLParser.parseBatch(['a', 'one\ttwo']), throwsFormatException);
    expect(
        () => MySQLParser.parseBatch(['a', r'bad\q']), throwsFormatException);
  });

  test('batch query preserves raw CR within fields and before LF or EOF',
      () async {
    for (final ending in ['', '\n']) {
      final runner = FakeRunner()
        ..result = MySQLProcessResult(
            0, 'a\tb\nleft\rright\tend\r\n\r\t\r\r$ending', '');
      final records = await client(runner).runMysqlQuery('SELECT a, b');
      expect(records.rows.map((row) => row.values), [
        ['left\rright', 'end\r'],
        ['\r', '\r\r']
      ]);
    }
  });

  test('batch query framing preserves empty rows without a final extra row',
      () async {
    final cases = <String, List<List<String>>>{
      '': [],
      'a': [],
      'a\n': [],
      'a\n\n': [['']],
      'a\n\n\n': [[''], ['']],
      'a\nx': [['x']],
      'a\nx\n': [['x']],
    };
    for (final entry in cases.entries) {
      final runner = FakeRunner()
        ..result = MySQLProcessResult(0, entry.key, '');
      final records = await client(runner).runMysqlQuery('SELECT a');
      expect(records.rows.map((row) => row.values), entry.value);
      expect(records.headingNames, entry.key.isEmpty ? <String>[] : ['a']);
    }
  });

  test('batch parser preserves raw CR in headings and values', () {
    final records = MySQLParser.parseBatch(
        ['a\rb\tc\r', 'left\rright\tend\r', '\r\t\r\r']);
    expect(records.headingNames, ['a\rb', 'c\r']);
    expect(records.rows.map((row) => row.values), [
      ['left\rright', 'end\r'],
      ['\r', '\r\r']
    ]);
  });

  test('batch parser preserves backslash aliases and still decodes values', () {
    final headings = [r'a\n', r'b\t', r'c\0', r'd\\', r'e\q', r'tail\'];
    final records = MySQLParser.parseBatch([
      headings.join('\t'),
      [r'\n', r'\t', r'\0', r'\\', 'plain', ''].join('\t')
    ]);
    expect(records.headingNames, headings);
    expect(records.rows.single.values, ['\n', '\t', '\x00', r'\', 'plain', '']);
  });

  test('batch query preserves verbatim aliases and still decodes values',
      () async {
    final headings = [
      r'a\n',
      r'b\t',
      r'c\0',
      r'd\\',
      r'e\q',
      r'tail\',
      'raw\rname\r'
    ];
    final values = [r'\n', r'\t', r'\0', r'\\', 'plain', '', 'end\r'];
    final runner = FakeRunner()
      ..result = MySQLProcessResult(
          0, '${headings.join('\t')}\n${values.join('\t')}\n', '');
    final records = await client(runner).runMysqlQuery('SELECT aliases');
    expect(records.headingNames, headings);
    expect(records.rows.single.values,
        ['\n', '\t', '\x00', r'\', 'plain', '', 'end\r']);
  });

  test(
      'legacy parser handles empty input and rejects malformed/multiple tables',
      () {
    expect(MySQLParser.parseLine(''), isEmpty);
    expect(MySQLParser.parseLine('|'), isEmpty);
    expect(MySQLParser.parseResults([]).rows, isEmpty);
    final table = ['+---+', '| a |', '+---+', '| x |', '+---+'];
    expect(MySQLParser.parseResults(table).rows.single.values, ['x']);
    expect(() => MySQLParser.parseResults([...table, ...table]),
        throwsFormatException);
    expect(() => MySQLParser.parseResults(['private diagnostic']),
        throwsFormatException);
    expect(
        () => Row.parseRow('| x | y |', [Field('a')]), throwsFormatException);
    expect(() => Row.parseRow('| x |', [Field('a'), Field('b')]),
        throwsFormatException);
  });
}
