A simple wrapper for calling the mysql command line client from Dart.

```dart

  final mysql =
      MySQL(user: 'root', password: config.adminPassword!, schema: dbSchema);

  // wait for mysql to start.
  await mysql.waitForMysql();

  print('Running backup of $dbSchema.');
  mysql.backup(selectedBackupFile);

  mysql.dropSchema();
  mysql.createSchema();

  mysql.restore(selectedBackupFile);

  mysql.createUser(username: 'brett', password: 'a apasswrod');

  var results = mysql.toList('select * from user');

  ```# mysql_cli_client
