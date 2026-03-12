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

    test('assigns ids to records and deletes by id', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      await memory.record(
        MemoryRecord(
          jobId: 'job-1',
          scope: 'scope-a',
          type: 'TEST',
          data: const {'text': 'first'},
          timestamp: DateTime.now(),
        ),
      );
      await memory.record(
        MemoryRecord(
          jobId: 'job-2',
          scope: 'scope-a',
          type: 'TEST',
          data: const {'text': 'second'},
          timestamp: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );

      final records = await memory.listRecords(scope: 'scope-a');

      expect(records, hasLength(2));
      expect(records.first.id, isNotNull);
      expect(records.last.id, isNotNull);

      await memory.deleteRecord(records.first.id!);

      final remaining = await memory.listRecords(scope: 'scope-a');
      expect(remaining, hasLength(1));
      expect(remaining.single.id, records.last.id);
      expect(remaining.single.data?['text'], 'second');
    });

    test('lists summary records with pagination', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      for (var i = 0; i < 4; i++) {
        await memory.record(
          MemoryRecord(
            jobId: 'job-summary-$i',
            scope: 'scope-a',
            type: 'MEMORY_SUMMARY',
            data: {'summaryText': 'summary-$i'},
            timestamp: DateTime.now().add(Duration(seconds: i)),
          ),
        );
      }
      await memory.record(
        MemoryRecord(
          jobId: 'job-detail',
          scope: 'scope-a',
          type: 'TEST',
          data: const {'text': 'detail'},
          timestamp: DateTime.now().add(const Duration(seconds: 10)),
        ),
      );

      final page = await memory.listRecords(
        type: 'MEMORY_SUMMARY',
        includeSummaries: true,
        offset: 2,
        limit: 2,
      );

      expect(page, hasLength(2));
      expect(page.map((record) => record.data?['summaryText']), [
        'summary-2',
        'summary-3',
      ]);
    });
  });
}

Future<String> _newDbPath() async {
  final dir = await Directory.systemTemp.createTemp('drift-memory-test-');
  return '${dir.path}/memory.sqlite';
}
