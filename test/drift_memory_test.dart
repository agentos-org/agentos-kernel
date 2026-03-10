import 'dart:io';

import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/model.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('DriftMemory initialization', () {
    test('first listScopes opens db without throwing', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);

      final scopes = await memory.listScopes();

      expect(scopes, isEmpty);
    });

    test('creates memory_records table and indexes', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      await memory.listScopes();
      await memory.record(
        MemoryRecord(
          jobId: 'job-1',
          scope: 'scope-a',
          type: 'TEST',
          data: const {'k': 'v'},
          timestamp: DateTime.now(),
        ),
      );

      final db = sqlite3.open(dbPath);
      addTearDown(db.dispose);
      final names = db
          .select('''
SELECT name
FROM sqlite_master
WHERE type IN ('table', 'index');
''')
          .map((row) => row['name'] as String)
          .toSet();

      expect(names, contains('memory_records'));
      expect(names, contains('memory_records_scope_ts'));
      expect(names, contains('memory_records_scope_type_ts'));
      expect(names, contains('memory_records_user_ts'));
      expect(names, contains('memory_records_session_ts'));
      expect(names, contains('memory_records_bundle_ts'));
      expect(names, contains('memory_records_task_id'));
      expect(names, contains('memory_records_liteagent_session_ts'));
    });
  });
}

Future<String> _newDbPath() async {
  final dir = await Directory.systemTemp.createTemp('drift-memory-test-');
  return '${dir.path}/memory.sqlite';
}
