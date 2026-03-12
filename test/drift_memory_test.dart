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

    test(
      'returns structured short-term and long-term memory snapshot',
      () async {
        final dbPath = await _newDbPath();
        final memory = DriftMemory.open(path: dbPath);
        await memory.record(
          MemoryRecord(
            jobId: 'job-short',
            scope: 'scope-a',
            type: shortTermMemoryType,
            data: const {'summaryText': 'recent summary'},
            timestamp: DateTime.now(),
          ),
        );
        await memory.record(
          MemoryRecord(
            jobId: 'job-long',
            scope: 'scope-a',
            type: longTermMemoryType,
            data: const {'summaryText': 'durable summary'},
            timestamp: DateTime.now().add(const Duration(seconds: 1)),
          ),
        );

        final snapshot = await memory.getSnapshot(scope: 'scope-a');

        expect(snapshot.shortTermMemory['summaryText'], 'recent summary');
        expect(snapshot.longTermMemory['summaryText'], 'durable summary');
        expect(
          snapshot.data,
          containsPair(
            'shortTermMemory',
            containsPair('summaryText', 'recent summary'),
          ),
        );
      },
    );

    test('listRecords excludes memory state records by default', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      await memory.record(
        MemoryRecord(
          jobId: 'job-short',
          scope: 'scope-a',
          type: shortTermMemoryType,
          data: const {'summaryText': 'recent summary'},
          timestamp: DateTime.now(),
        ),
      );
      await memory.record(
        MemoryRecord(
          jobId: 'job-detail',
          scope: 'scope-a',
          type: 'TEST',
          data: const {'text': 'detail'},
          timestamp: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );

      final records = await memory.listRecords(scope: 'scope-a');

      expect(records, hasLength(1));
      expect(records.single.type, 'TEST');
    });

    test(
      'deleteDetailRecordsBefore removes only covered raw records',
      () async {
        final dbPath = await _newDbPath();
        final memory = DriftMemory.open(path: dbPath);
        final base = DateTime.now();
        await memory.record(
          MemoryRecord(
            jobId: 'job-detail-old',
            scope: 'scope-a',
            type: 'TEST',
            data: const {'text': 'old'},
            timestamp: base,
          ),
        );
        await memory.record(
          MemoryRecord(
            jobId: 'job-summary',
            scope: 'scope-a',
            type: memorySummaryType,
            data: const {'summaryText': 'covered'},
            timestamp: base.add(const Duration(seconds: 1)),
          ),
        );
        await memory.record(
          MemoryRecord(
            jobId: 'job-short',
            scope: 'scope-a',
            type: shortTermMemoryType,
            data: const {'summaryText': 'short'},
            timestamp: base.add(const Duration(seconds: 2)),
          ),
        );
        await memory.record(
          MemoryRecord(
            jobId: 'job-detail-new',
            scope: 'scope-a',
            type: 'TEST',
            data: const {'text': 'new'},
            timestamp: base.add(const Duration(seconds: 3)),
          ),
        );

        await memory.deleteDetailRecordsBefore(
          before: base.add(const Duration(seconds: 1)),
          scope: 'scope-a',
        );

        final records = await memory.listRecords(
          scope: 'scope-a',
          includeSummaries: true,
        );
        expect(records.map((record) => record.jobId), [
          'job-summary',
          'job-short',
          'job-detail-new',
        ]);
      },
    );

    test(
      'deleteSummaryRecordsBefore removes absorbed summaries only',
      () async {
        final dbPath = await _newDbPath();
        final memory = DriftMemory.open(path: dbPath);
        final base = DateTime.now();
        await memory.record(
          MemoryRecord(
            jobId: 'job-summary-1',
            scope: 'scope-a',
            type: memorySummaryType,
            data: const {'summaryText': 'summary-1'},
            timestamp: base,
          ),
        );
        await memory.record(
          MemoryRecord(
            jobId: 'job-summary-2',
            scope: 'scope-a',
            type: memorySummaryType,
            data: const {'summaryText': 'summary-2'},
            timestamp: base.add(const Duration(seconds: 1)),
          ),
        );

        await memory.deleteSummaryRecordsBefore(before: base, scope: 'scope-a');

        final records = await memory.listRecords(
          scope: 'scope-a',
          type: memorySummaryType,
          includeSummaries: true,
        );
        expect(records, hasLength(1));
        expect(records.single.jobId, 'job-summary-2');
      },
    );

    test('pruneStateRecords keeps only latest state versions', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      final base = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await memory.record(
          MemoryRecord(
            jobId: 'job-short-$i',
            scope: 'scope-a',
            type: shortTermMemoryType,
            data: {'summaryText': 'short-$i'},
            timestamp: base.add(Duration(seconds: i)),
          ),
        );
      }

      await memory.pruneStateRecords(
        type: shortTermMemoryType,
        keepLatest: 2,
        scope: 'scope-a',
      );

      final records = await memory.listRecords(
        scope: 'scope-a',
        type: shortTermMemoryType,
        includeSummaries: true,
      );
      expect(records, hasLength(2));
      expect(records.map((record) => record.jobId), [
        'job-short-3',
        'job-short-4',
      ]);
    });
  });
}

Future<String> _newDbPath() async {
  final dir = await Directory.systemTemp.createTemp('drift-memory-test-');
  return '${dir.path}/memory.sqlite';
}
