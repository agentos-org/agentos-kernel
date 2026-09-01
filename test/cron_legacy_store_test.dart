import 'dart:convert';
import 'dart:io';

import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:agentos_kernel/src/kernel/cron/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('DriftCronTaskStore legacy schema compatibility', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cron_legacy_store_test');
      dbPath = '${tempDir.path}/cron.sqlite';
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'reads and writes a database containing the old user_id column',
      () async {
        final db = sqlite3.open(dbPath);
        db.execute('''
CREATE TABLE cron_tasks (
  cron_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  schedule TEXT NOT NULL,
  source TEXT NOT NULL,
  user_id TEXT,
  session_id TEXT,
  timezone TEXT,
  concurrency TEXT NOT NULL,
  spec_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_run_at INTEGER,
  next_run_at INTEGER,
  status TEXT NOT NULL
);
''');
        db.execute(
          '''
INSERT INTO cron_tasks (
  cron_id, name, schedule, source, user_id, session_id, timezone,
  concurrency, spec_json, created_at, updated_at, last_run_at, next_run_at,
  status
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
          [
            'legacy-cron',
            'legacy task',
            '0 9 * * *',
            'legacy',
            'unused-user',
            'saved-session',
            'Asia/Shanghai',
            CronTaskConcurrencyPolicy.skipIfRunning.name,
            jsonEncode({
              'systemPrompt': 'Legacy prompt',
              'content': [
                {'type': 'text', 'message': 'Legacy content'},
              ],
              'timeoutSeconds': 60,
            }),
            DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
            DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
            null,
            DateTime.utc(2026, 1, 2, 1).millisecondsSinceEpoch,
            CronTaskStatus.active.name,
          ],
        );
        db.dispose();

        final store = DriftCronTaskStore.open(path: dbPath);
        final loaded = await store.getTask('legacy-cron');

        expect(loaded, isNotNull);
        expect(loaded!.sessionId, 'saved-session');
        expect(loaded.timezone, 'Asia/Shanghai');
        expect(loaded.spec.content.single.message, 'Legacy content');
        expect(loaded.nextRunAt, DateTime.utc(2026, 1, 2, 1));

        final updated = loaded.copyWith(name: 'updated legacy task');
        await store.putTask(updated);
        final reloaded = await store.getTask('legacy-cron');
        expect(reloaded!.name, 'updated legacy task');
      },
    );

    test('does not add user_id to a newly created schema', () async {
      final store = DriftCronTaskStore.open(path: dbPath);
      await store.listTasks();

      final db = sqlite3.open(dbPath);
      addTearDown(db.dispose);
      final columns = db
          .select('PRAGMA table_info(cron_tasks);')
          .map((row) => row['name'] as String)
          .toList(growable: false);

      expect(columns, isNot(contains('user_id')));
    });
  });
}
