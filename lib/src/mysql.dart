/* Copyright (C) OnePub IP Pty Ltd - All Rights Reserved
 * Unauthorized copying of this file, via any medium is strictly prohibited
 * Proprietary and confidential
 * Written by Brett Sutton <bsutton@onepub.dev>, Jan 2022
 */

import 'package:dcli/dcli.dart';

import 'mysql_parser.dart';

class MySQL {
  MySQL({
    required this.user,
    required this.password,
    required this.schema,
    this.host = '127.0.0.1',
    this.port = 3306,
  });
  String user;
  String password;
  String schema;
  String host;
  int port;

  Future<void> dropSchema() async {
    final sql = 'drop database if exists $schema';
    await run(sql, noschema: true);
  }

  Future<void> createSchema() async {
    final sql = 'create database if not exists $schema';
    await run(sql, noschema: true);
  }

  Future<void> restore(String sourcePath) async {
    await withEnvironment(
      () async =>
          ('cat $sourcePath' | 'mysql --user $user --host=$host $schema ').run,
      environment: {'MYSQL_PWD': password},
    );
  }

  Future<void> createUser(
      {required String username, required String password}) async {
    await withEnvironment(
      () async {
        final qualifiedUser = "'$username'@'$host'";
        final cmd = '''
DROP USER if exists $qualifiedUser;
CREATE USER $qualifiedUser IDENTIFIED BY '$password'; 
GRANT ALL ON $schema.* TO $qualifiedUser;
flush privileges;'''
            .replaceAll('\n', ' ');
        await run(cmd);
      },
      environment: {'MYSQL_PWD': password},
    );
  }

  void backup(String savePath) {
    env['MYSQL_PWD'] = password;

    var v8 = false;
    final progress = Progress((line) {
      v8 |= line.contains('Ver 8.');
    });
    'mysqldump --version'.start(progress: progress);

    var statistics = '';
    if (v8) {
      print('suppressing colum-statistics for mysqldump Ver 8.x');
      statistics = '--column-statistics=0';
    }

    final cmd = 'mysqldump $statistics --user $user --host=$host $schema '
        '--routines --result-file=$savePath';
    Settings().verbose(cmd);
    cmd.run;
    // .forEach((line) => savePath.append(line));
  }

  ///
  /// Pass [noschema] if the schema name should NOT be included in the
  /// command.
  ///
  Future<List<String>> toList(String sql,
      {bool noschema = false, bool table = false}) async {
    final args = <String>[];
    if (table) {
      args.add('-t');
    }

    args.addAll(<String>['--user=$user', '--host=$host', '--port=$port']);
    if (!noschema) {
      args.add(schema);
    }
    args
      ..add('-e')
      ..add(sql);

    Settings().verbose('mysql $args');

    return withEnvironment(
      () async =>
          startFromArgs('mysql', args, progress: Progress.capture()).toList(),
      environment: {'MYSQL_PWD': password},
    );
  }

  ///
  /// Run a mysql command returning a RecordSet
  ///
  Future<RecordSet> runMysqlQuery(String sqlQuery) async =>
      MySQLParser.parseResults(await toList(sqlQuery, table: true));

  /// Pass [noschema] if the schema name should NOT be included in the
  /// command.
  Future<void> run(String sql,
      {bool noschema = false, bool noThrow = false, Progress? progress}) async {
    await runFromArgs(sql, [],
        noschema: noschema, noThrow: noThrow, progress: progress);
  }

  ///
  /// Pass [noschema] if the schema name should NOT be included in the
  /// command.
  ///
  Future<void> runFromArgs(String sql, List<String> args,
      {bool noschema = false, bool noThrow = false, Progress? progress}) async {
    progress ??= Progress.print();

    args.addAll(<String>['--user=$user', '--host=$host', '--port=$port']);
    if (!noschema) {
      args.add(schema);
    }
    args
      ..add('-e')
      ..add(sql);

    Settings().verbose('mysql $args');

    await withEnvironment(
      () async {
        startFromArgs('mysql', args, progress: progress, nothrow: noThrow);
      },
      environment: {'MYSQL_PWD': password},
    );
  }

  /// Indefinitely wait for mysql to start responding.
  /// This is useful if you have just started mysql.
  Future<void> waitForMysql() async {
    final result = <String>[];
    Progress progress;

    var firstpass = true;
    var success = false;

    do {
      if (!firstpass) {
        print('Waiting for Mysql connection...');
        firstpass = false;
      }
      progress = Progress(devNull, stderr: result.add);

      await run('select 1', noschema: true, noThrow: true, progress: progress);

      if (progress.exitCode == 0) {
        success = true;
      } else {
        /// an access denied message also means we are up.
        /// On the first install the user won't exist at this point.
        if (result.length == 2 && result[1].contains('Access denied')) {
          success = true;
        } else {
          print(orange(
              'The following error may be due to mysql still initialising.'));

          /// print the error
          result.forEach(print);
        }
      }
      result.clear();
      if (!success) {
        sleep(10);
      }
    } while (!success);
    print('Connected to Mysql');
  }
}
