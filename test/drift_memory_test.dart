import 'dart:io';

import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/model.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('DriftMemory initialization', () {
    test('opens db without throwing', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);

      final items = await memory.listMemoryItems();

      expect(items, isEmpty);
    });

    test('creates memory tables and indexes', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      await memory.upsertMemoryItem(
        MemoryItem(
          id: 'item-1',
          type: 'TEST',
          sourceId: 'source-1',
          content: 'hello',
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

      expect(names, contains('memory_items'));
      expect(names, contains('memory_items_type_ts'));
      expect(names, contains('memory_pipeline_state'));
    });

    test('upserts memory items and deletes by id', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      await memory.upsertMemoryItem(
        MemoryItem(
          id: 'item-1',
          type: 'TEST',
          sourceId: 'source-1',
          content: 'first',
          timestamp: DateTime.now(),
        ),
      );
      await memory.upsertMemoryItem(
        MemoryItem(
          id: 'item-2',
          type: 'TEST',
          sourceId: 'source-2',
          content: 'second',
          timestamp: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );

      final items = await memory.listMemoryItems(limit: 10);

      expect(items, hasLength(2));
      expect(items.first.id, 'item-1');
      expect(items.last.id, 'item-2');

      await memory.deleteMemoryItem('item-1');

      final remaining = await memory.listMemoryItems(limit: 10);
      expect(remaining, hasLength(1));
      expect(remaining.single.id, 'item-2');
      expect(remaining.single.content, 'second');
    });

    test('lists memory items with pagination', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      for (var i = 0; i < 4; i++) {
        await memory.upsertMemoryItem(
          MemoryItem(
            id: 'item-$i',
            type: 'TEST',
            sourceId: 'source-$i',
            content: 'record-$i',
            timestamp: DateTime.now().add(Duration(seconds: i)),
          ),
        );
      }
      final page = await memory.listMemoryItems(
        type: 'TEST',
        offset: 2,
        limit: 2,
      );

      expect(page, hasLength(2));
      expect(page.map((item) => item.content), ['record-2', 'record-3']);
    });

    test('stores agent memory messages directly into memory item', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      final base = DateTime.utc(2026, 1, 1, 8, 0, 0);

      await memory.appendAgentMemoryMessage(
        sessionId: 'session-a',
        taskId: 'task-1',
        actorId: 'alice',
        actorType: AgentMemoryActorType.user,
        content: const ['Hello', 'Help me check my schedule'],
        timestamp: base,
      );
      await memory.appendAgentMemoryMessage(
        sessionId: 'session-a',
        taskId: 'task-2',
        actorId: 'calendar.app',
        actorType: AgentMemoryActorType.app,
        content: const ['There is a meeting at 3 PM this afternoon'],
        timestamp: base.add(const Duration(seconds: 1)),
      );

      final derived = await memory.getMemoryItem('session-a');

      expect(derived, isNotNull);
      expect(derived!.type, agentMemoryItemType);
      expect(derived.sourceId, 'session-a');
      expect(
        derived.content,
        contains('alice(user) 2026-01-01T08:00:00.000Z [task-1]:'),
      );
      expect(derived.content, contains('calendar.app(app)'));
      expect(
        derived.content,
        contains('There is a meeting at 3 PM this afternoon'),
      );
    });

    test('lists memory items with pagination and deletes by id', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      final base = DateTime.utc(2026, 1, 1, 8, 0, 0);
      for (var i = 0; i < 3; i++) {
        await memory.upsertMemoryItem(
          MemoryItem(
            id: 'item-$i',
            type: 'TEST',
            sourceId: 'source-$i',
            content: 'content-$i',
            timestamp: base.add(Duration(minutes: i)),
          ),
        );
      }

      final page = await memory.listMemoryItems(offset: 1, limit: 1);
      expect(page, hasLength(1));
      expect(page.single.id, 'item-1');

      await memory.deleteMemoryItem('item-1');
      final all = await memory.listMemoryItems(limit: 10);
      expect(all.map((item) => item.id), ['item-0', 'item-2']);
    });

    test('lists memory summaries with pagination and deletes by id', () async {
      final dbPath = await _newDbPath();
      final memory = DriftMemory.open(path: dbPath);
      final base = DateTime.utc(2026, 1, 1, 8, 0, 0);
      final recent = MemorySummary(
        id: 'recent-1',
        text: 'Recent summary',
        sourceIds: const ['item-1', 'item-2'],
        sourceStartAt: base,
        sourceEndAt: base.add(const Duration(minutes: 10)),
        updatedAt: base.add(const Duration(minutes: 11)),
        bucket: MemorySummaryBucket.recent,
      );
      final week = MemorySummary(
        id: 'week-1',
        text: 'Week summary',
        sourceIds: const ['item-3'],
        sourceStartAt: base.subtract(const Duration(days: 2)),
        sourceEndAt: base.subtract(const Duration(days: 1)),
        updatedAt: base.add(const Duration(minutes: 12)),
        bucket: MemorySummaryBucket.week,
      );

      await memory.saveMemorySummaries(MemorySummaryBucket.recent, [recent]);
      await memory.saveMemorySummaries(MemorySummaryBucket.week, [week]);

      final page = await memory.listMemorySummaries(offset: 1, limit: 1);
      expect(page, hasLength(1));
      expect(page.single.id, 'recent-1');

      await memory.deleteMemorySummary('recent-1');
      final allItems = await memory.listMemorySummaries(limit: 10);
      expect(allItems.map((summary) => summary.id), ['week-1']);
      final remainingRecent = await memory.getMemorySummaries(
        MemorySummaryBucket.recent,
      );
      expect(remainingRecent, isEmpty);
    });
  });
}

Future<String> _newDbPath() async {
  final dir = await Directory.systemTemp.createTemp('drift-memory-test-');
  return '${dir.path}/memory.sqlite';
}
