import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'embedder.dart';
import 'model.dart';
import 'preference.dart';
import 'vector_store.dart';

class DriftPreference implements Preference {
  final QueryExecutor _executor;
  final _PreferenceDbUser _user = _PreferenceDbUser();
  final VectorStore _vectorStore;
  final PreferenceEmbedder _embedder;
  final bool Function()? _isIndexingAvailable;
  Future<void>? _openFuture;

  DriftPreference({
    required QueryExecutor executor,
    required VectorStore vectorStore,
    PreferenceEmbedder? embedder,
    bool Function()? isIndexingAvailable,
  }) : _executor = executor,
       _vectorStore = vectorStore,
       _embedder = embedder ?? HashEmbedder(),
       _isIndexingAvailable = isIndexingAvailable;

  factory DriftPreference.open({
    required String path,
    required VectorStore vectorStore,
    PreferenceEmbedder? embedder,
    bool Function()? isIndexingAvailable,
  }) {
    return DriftPreference(
      executor: _openConnection(path),
      vectorStore: vectorStore,
      embedder: embedder,
      isIndexingAvailable: isIndexingAvailable,
    );
  }

  Future<void> _ensureOpen() {
    _openFuture ??= () async {
      await _executor.ensureOpen(_user);
      await _user.ensureInitialized(_executor);
    }();
    return _openFuture!;
  }

  @override
  Future<List<PreferenceEntry>> addTexts({
    required String userId,
    required List<String> texts,
    DateTime? updatedAt,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return const [];
    }
    final nextUpdatedAt = updatedAt ?? DateTime.now();
    final seen = <String>{};
    final changed = <PreferenceEntry>[];
    for (final rawText in texts) {
      final trimmed = rawText.trim();
      final normalizedText = normalizePreferenceText(trimmed);
      if (normalizedText.isEmpty || !seen.add(normalizedText)) {
        continue;
      }
      final existing = await _getByNormalizedText(
        normalizedUserId,
        normalizedText,
      );
      if (existing != null) {
        final updated = PreferenceEntry(
          id: existing.id,
          text: trimmed,
          updatedAt: nextUpdatedAt,
        );
        await _upsertEntry(
          userId: normalizedUserId,
          entry: updated,
          existingIndexId: existing.indexId,
        );
        changed.add(updated);
        continue;
      }
      final created = PreferenceEntry(
        id: buildPreferenceId(normalizedUserId, trimmed, nextUpdatedAt),
        text: trimmed,
        updatedAt: nextUpdatedAt,
      );
      await _upsertEntry(
        userId: normalizedUserId,
        entry: created,
      );
      changed.add(created);
    }
    return changed;
  }

  @override
  Future<List<PreferenceEntry>> listPreferences({
    String? userId,
    int offset = 0,
    int limit = 50,
  }) async {
    if (userId == null || userId.trim().isEmpty) {
      return const [];
    }
    await _ensureOpen();
    final paginationClause = limit > 0
        ? offset > 0
              ? 'LIMIT $limit OFFSET $offset'
              : 'LIMIT $limit'
        : offset > 0
        ? 'LIMIT -1 OFFSET $offset'
        : '';
    final rows = await _executor.runSelect(
      '''
SELECT id, text, updated_at
FROM preference_items
WHERE user_id = ?
ORDER BY updated_at DESC
$paginationClause;
''',
      [userId.trim()],
    );
    return rows.map(_entryFromRow).toList(growable: false);
  }

  @override
  Future<void> deletePreference(String id, {String? userId}) async {
    if (userId == null || userId.trim().isEmpty || id.trim().isEmpty) {
      return;
    }
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT index_id
FROM preference_items
WHERE user_id = ? AND id = ?
LIMIT 1;
''',
      [userId.trim(), id.trim()],
    );
    if (rows.isNotEmpty) {
      final indexId = rows.first['index_id'] as String?;
      if (indexId != null && indexId.trim().isNotEmpty) {
        if (_indexingAvailable) {
          await _deleteIndex(indexId);
        } else {
          await _queuePendingIndexDelete(indexId);
        }
      }
    }
    await _executor.runCustom(
      'DELETE FROM preference_items WHERE user_id = ? AND id = ?;',
      [userId.trim(), id.trim()],
    );
  }

  @override
  Future<void> clear({String? userId}) async {
    if (userId == null || userId.trim().isEmpty) {
      return;
    }
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT index_id
FROM preference_items
WHERE user_id = ?;
''',
      [userId.trim()],
    );
    for (final row in rows) {
      final indexId = row['index_id'] as String?;
      if (indexId != null && indexId.trim().isNotEmpty) {
        if (_indexingAvailable) {
          await _deleteIndex(indexId);
        } else {
          await _queuePendingIndexDelete(indexId);
        }
      }
    }
    await _executor.runCustom(
      'DELETE FROM preference_items WHERE user_id = ?;',
      [userId.trim()],
    );
  }

  Future<_StoredPreferenceEntry?> _getByNormalizedText(
    String userId,
    String normalizedText,
  ) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT id, text, updated_at, index_id
FROM preference_items
WHERE user_id = ? AND normalized_text = ?
LIMIT 1;
''',
      [userId, normalizedText],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    return _StoredPreferenceEntry(
      id: row['id'] as String? ?? '',
      text: row['text'] as String? ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
      indexId: row['index_id'] as String?,
    );
  }

  Future<void> _upsertEntry({
    required String userId,
    required PreferenceEntry entry,
    String? existingIndexId,
  }) async {
    await _ensureOpen();
    String? nextIndexId;
    if (_indexingAvailable) {
      if (existingIndexId != null && existingIndexId.trim().isNotEmpty) {
        await _deleteIndex(existingIndexId);
      }
      final embedding = _embedder.embed(entry.text);
      try {
        nextIndexId = await _vectorStore.upsert(
          id: entry.id,
          vector: embedding,
          payload: {
            'id': entry.id,
            'userId': userId,
            'text': entry.text,
            'updatedAt': entry.updatedAt.toIso8601String(),
          },
        );
      } catch (_) {
        nextIndexId = null;
      }
    } else {
      nextIndexId = null;
      if (existingIndexId != null && existingIndexId.trim().isNotEmpty) {
        await _queuePendingIndexDelete(existingIndexId);
      }
    }
    await _executor.runCustom(
      '''
INSERT INTO preference_items (
  id,
  user_id,
  normalized_text,
  text,
  updated_at,
  index_id
) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  user_id = excluded.user_id,
  normalized_text = excluded.normalized_text,
  text = excluded.text,
  updated_at = excluded.updated_at,
  index_id = excluded.index_id;
''',
      [
        entry.id,
        userId,
        normalizePreferenceText(entry.text),
        entry.text,
        entry.updatedAt.millisecondsSinceEpoch,
        nextIndexId,
      ],
    );
  }

  PreferenceEntry _entryFromRow(Map<String, Object?> row) {
    return PreferenceEntry(
      id: row['id'] as String? ?? '',
      text: row['text'] as String? ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
    );
  }

  @override
  Future<void> syncIndexes({String? userId}) async {
    if (!_indexingAvailable) {
      return;
    }
    await _ensureOpen();
    await _flushPendingIndexDeletes();
    final normalizedUserId = userId?.trim();
    final args = <Object?>[];
    final where = (normalizedUserId == null || normalizedUserId.isEmpty)
        ? ''
        : 'WHERE user_id = ?';
    if (where.isNotEmpty) {
      args.add(normalizedUserId);
    }
    final rows = await _executor.runSelect('''
SELECT id, user_id, text, updated_at, index_id
FROM preference_items
$where
ORDER BY updated_at DESC;
''', args);
    for (final row in rows) {
      final existingIndexId = row['index_id'] as String?;
      if (existingIndexId != null && existingIndexId.trim().isNotEmpty) {
        await _deleteIndex(existingIndexId);
      }
      final entry = PreferenceEntry(
        id: row['id'] as String? ?? '',
        text: row['text'] as String? ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['updated_at'] as int? ?? 0,
        ),
      );
      final userId = row['user_id'] as String? ?? '';
      final embedding = _embedder.embed(entry.text);
      String? nextIndexId;
      try {
        nextIndexId = await _vectorStore.upsert(
          id: entry.id,
          vector: embedding,
          payload: {
            'id': entry.id,
            'userId': userId,
            'text': entry.text,
            'updatedAt': entry.updatedAt.toIso8601String(),
          },
        );
      } catch (_) {
        nextIndexId = null;
      }
      await _executor.runCustom(
        'UPDATE preference_items SET index_id = ? WHERE id = ?;',
        [nextIndexId, entry.id],
      );
    }
  }

  bool get _indexingAvailable => _isIndexingAvailable?.call() ?? true;

  Future<void> _deleteIndex(String indexId) async {
    try {
      await _vectorStore.delete(indexId);
    } catch (_) {}
  }

  Future<void> _queuePendingIndexDelete(String indexId) async {
    if (indexId.trim().isEmpty) {
      return;
    }
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO preference_pending_index_deletes (segment_id)
VALUES (?)
ON CONFLICT(segment_id) DO NOTHING;
''',
      [indexId.trim()],
    );
  }

  Future<void> _flushPendingIndexDeletes() async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      'SELECT segment_id FROM preference_pending_index_deletes;',
      const [],
    );
    for (final row in rows) {
      final segmentId = row['segment_id'] as String?;
      if (segmentId == null || segmentId.trim().isEmpty) {
        continue;
      }
      await _deleteIndex(segmentId);
    }
    await _executor.runCustom(
      'DELETE FROM preference_pending_index_deletes;',
      const [],
    );
  }
}

class _StoredPreferenceEntry {
  final String id;
  final String text;
  final DateTime updatedAt;
  final String? indexId;

  const _StoredPreferenceEntry({
    required this.id,
    required this.text,
    required this.updatedAt,
    this.indexId,
  });
}

class _PreferenceDbUser implements QueryExecutorUser {
  Future<void>? _initFuture;

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}

  Future<void> ensureInitialized(QueryExecutor executor) {
    _initFuture ??= _createSchema(executor);
    return _initFuture!;
  }

  Future<void> _createSchema(QueryExecutor executor) async {
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS preference_items (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  normalized_text TEXT NOT NULL,
  text TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  index_id TEXT
);
''');
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS preference_pending_index_deletes (
  segment_id TEXT PRIMARY KEY
);
''');
    await executor.runCustom('''
CREATE UNIQUE INDEX IF NOT EXISTS preference_items_user_normalized_text
  ON preference_items (user_id, normalized_text);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS preference_items_user_updated_at
  ON preference_items (user_id, updated_at);
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
