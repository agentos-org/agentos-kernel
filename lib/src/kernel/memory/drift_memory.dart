import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'model.dart';

class DriftMemory {
  final QueryExecutor _executor;
  final _MemoryDbUser _user = _MemoryDbUser();
  Future<void>? _openFuture;

  DriftMemory(this._executor);

  factory DriftMemory.open({required String path}) {
    return DriftMemory(_openConnection(path));
  }

  Future<void> _ensureOpen() {
    _openFuture ??= () async {
      await _executor.ensureOpen(_user);
      await _user.ensureInitialized(_executor);
    }();
    return _openFuture!;
  }

  Future<void> appendAgentMemoryMessage({
    required String sessionId,
    required String taskId,
    required String actorId,
    required AgentMemoryActorType actorType,
    required List<String> content,
    required DateTime timestamp,
  }) async {
    await _ensureOpen();
    final normalizedSessionId = sessionId.trim();
    final normalizedContent = content
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (normalizedSessionId.isEmpty || normalizedContent.isEmpty) {
      return;
    }
    final existing = await getMemoryItem(normalizedSessionId);
    final entry = _renderAgentMemoryEntry(
      taskId: taskId,
      actorId: actorId,
      actorType: actorType,
      content: normalizedContent,
      timestamp: timestamp,
    );
    final mergedContent = existing == null || existing.content.trim().isEmpty
        ? entry
        : '${existing.content.trim()}\n\n$entry';
    await upsertMemoryItem(
      MemoryItem(
        id: normalizedSessionId,
        type: agentMemoryItemType,
        sourceId: normalizedSessionId,
        content: mergedContent,
        timestamp: timestamp,
      ),
    );
  }

  Future<void> upsertMemoryItem(MemoryItem item) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO memory_items (
  id,
  type,
  source_id,
  content,
  timestamp
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  type = excluded.type,
  source_id = excluded.source_id,
  content = excluded.content,
  timestamp = excluded.timestamp;
''',
      [
        item.id,
        item.type,
        item.sourceId,
        item.content,
        item.timestamp.millisecondsSinceEpoch,
      ],
    );
  }

  Future<List<MemoryItem>> listMemoryItems({
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int limit = 50,
    bool descending = false,
  }) async {
    await _ensureOpen();
    final where = <String>[];
    final args = <Object?>[];
    if (type != null && type.trim().isNotEmpty) {
      where.add('type = ?');
      args.add(type.trim());
    }
    if (after != null) {
      where.add('timestamp > ?');
      args.add(after.millisecondsSinceEpoch);
    }
    if (before != null) {
      where.add('timestamp <= ?');
      args.add(before.millisecondsSinceEpoch);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final orderDirection = descending ? 'DESC' : 'ASC';
    final paginationClause = limit > 0
        ? offset > 0
              ? 'LIMIT $limit OFFSET $offset'
              : 'LIMIT $limit'
        : offset > 0
        ? 'LIMIT -1 OFFSET $offset'
        : '';
    final rows = await _executor.runSelect('''
SELECT id, type, source_id, content, timestamp
FROM memory_items
$whereClause
ORDER BY timestamp $orderDirection
$paginationClause;
''', args);
    return rows.map(_memoryItemFromRow).toList(growable: false);
  }

  Future<MemoryItem?> getMemoryItem(String id) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT id, type, source_id, content, timestamp
FROM memory_items
WHERE id = ?
LIMIT 1;
''',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _memoryItemFromRow(rows.first);
  }

  Future<void> saveMemorySummaries(
    MemorySummaryBucket bucket,
    List<MemorySummary> summaries,
  ) {
    return _savePipelineState('memory_summaries_${bucket.name}', {
      'items': summaries.map((summary) => summary.toJson()).toList(),
    });
  }

  Future<List<MemorySummary>> getMemorySummaries(
    MemorySummaryBucket bucket,
  ) async {
    final payload = await _loadPipelineState('memory_summaries_${bucket.name}');
    if (payload == null) {
      return const [];
    }
    final items = payload['items'];
    if (items is! List) {
      return const [];
    }
    return items
        .whereType<Map>()
        .map(
          (item) => MemorySummary.fromJson(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .where((summary) => summary.id.isNotEmpty && summary.text.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<MemorySummary>> listMemorySummaries({
    MemorySummaryBucket? bucket,
    int offset = 0,
    int limit = 50,
  }) async {
    final all = bucket == null
        ? <MemorySummary>[
            for (final value in MemorySummaryBucket.values)
              ...await getMemorySummaries(value),
          ]
        : await getMemorySummaries(bucket);
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (offset >= all.length) {
      return const [];
    }
    final paged = all.skip(offset);
    if (limit <= 0) {
      return paged.toList(growable: false);
    }
    return paged.take(limit).toList(growable: false);
  }

  Future<List<MemorySummaryIndexEntry>> getMemorySummaryIndexEntries() async {
    final payload = await _loadPipelineState('memory_summary_index_entries');
    if (payload == null) {
      return const [];
    }
    final items = payload['items'];
    if (items is! List) {
      return const [];
    }
    return items
        .whereType<Map>()
        .map(
          (item) => MemorySummaryIndexEntry.fromJson(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .where(
          (entry) =>
              entry.summaryId.isNotEmpty &&
              entry.segmentId.isNotEmpty &&
              entry.contentFingerprint.isNotEmpty,
        )
        .toList(growable: false);
  }

  Future<void> saveMemorySummaryIndexEntries(
    List<MemorySummaryIndexEntry> entries,
  ) {
    return _savePipelineState('memory_summary_index_entries', {
      'items': entries.map((entry) => entry.toJson()).toList(),
    });
  }

  Future<void> deleteMemoryItem(String id) async {
    await _ensureOpen();
    await _executor.runCustom('DELETE FROM memory_items WHERE id = ?;', [id]);
  }

  Future<void> deleteMemorySummary(String id) async {
    await _ensureOpen();
    for (final bucket in MemorySummaryBucket.values) {
      final items = await getMemorySummaries(bucket);
      final filtered = items
          .where((item) => item.id != id)
          .toList(growable: false);
      if (filtered.length != items.length) {
        await saveMemorySummaries(bucket, filtered);
        return;
      }
    }
  }

  Future<void> _savePipelineState(
    String key,
    Map<String, dynamic> value,
  ) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO memory_pipeline_state (key, value_json)
VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;
''',
      [key, jsonEncode(value)],
    );
  }

  Future<Map<String, dynamic>?> _loadPipelineState(String key) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT value_json
FROM memory_pipeline_state
WHERE key = ?
LIMIT 1;
''',
      [key],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _decodeJson(rows.first['value_json'] as String?);
  }

  MemoryItem _memoryItemFromRow(Map<String, Object?> row) {
    final timestamp = row['timestamp'] as int? ?? 0;
    return MemoryItem(
      id: row['id'] as String? ?? '',
      type: row['type'] as String? ?? '',
      sourceId: row['source_id'] as String? ?? '',
      content: row['content'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }

  Map<String, dynamic>? _decodeJson(String? dataJson) {
    if (dataJson == null || dataJson.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(dataJson);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  String _renderAgentMemoryEntry({
    required String taskId,
    required String actorId,
    required AgentMemoryActorType actorType,
    required List<String> content,
    required DateTime timestamp,
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
      '$actorId(${actorType.name}) ${timestamp.toUtc().toIso8601String()} [$taskId]:',
    );
    for (final line in content) {
      buffer.writeln(line);
    }
    return buffer.toString().trim();
  }
}

class _MemoryDbUser implements QueryExecutorUser {
  Future<void>? _initFuture;

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    // Drift may call beforeOpen before the executor is considered open.
    // We run schema setup after ensureOpen() completes.
  }

  Future<void> ensureInitialized(QueryExecutor executor) {
    _initFuture ??= _createSchema(executor);
    return _initFuture!;
  }

  Future<void> _createSchema(QueryExecutor executor) async {
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS memory_items (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  source_id TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL
);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_items_type_ts
  ON memory_items (type, timestamp);
''');
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS memory_pipeline_state (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);
''');
  }
}

QueryExecutor _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return NativeDatabase(file);
  });
}
