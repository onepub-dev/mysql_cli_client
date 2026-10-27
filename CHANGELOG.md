# 2.0.0

- Replace dcli execution with literal dart:io process arguments and per-child authentication environments. Remove runtime dependencies.
- Send SQL through stdin, redact client failures, and stream restore files directly. Include configured ports in backup and restore.
- Validate and quote provisioning identifiers; encode account literals and reject unsafe mode-dependent characters.
- Replace dcli Progress with MySQLProgress; suppress raw diagnostics and report exit status. No credential-bearing version probes.
- Preserve synchronous backup with an explicit optional columnStatistics setting.
- Use escaped batch records for runMysqlQuery; validate field counts and reject malformed legacy table output.
- Breaking: narrower provisioning names/account values, stdin SQL transport, new progress API, explicit dump compatibility option, and authenticated waitForMysql readiness. See README for migration and limitations.

# 1.0.1
- add a repsoitory to pubspec

## 1.0.0

- Initial version.
