A simple wrapper for calling the mysql command line client from Dart.

```dart

  final mysql =
      MySQL(user: 'root', password: config.adminPassword!, schema: dbSchema);
  await mysql.waitForMysql();
  print('Running backup of $dbSchema.');
  mysql.backup(selectedBackupFile);
  ```# mysql_cli_client
