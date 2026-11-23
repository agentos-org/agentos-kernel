import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'model.dart';
import 'preference.dart';

class DriftPreference implements Preference {
  final QueryExecutor _executor;
  final _PreferenceDbUser _user = _PreferenceDbUser();
  Future<void>? _openFuture;

  DriftPreference({required this._executor});

  factory DriftPreference.open({required String path}) {
    return DriftPreference(executor: _openConnection(path));
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
      await _ensureOpen();
      final rows = await _executor.runSelect(
        '''
INSERT INTO preference_items (id, user_id, normalized_text, text, updated_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(user_id, normalized_text) DO UPDATE SET
  text = excluded.text,
  updated_at = excluded.updated_at
RETURNING id;
''',
        [
          buildPreferenceId(normalizedUserId, trimmed, nextUpdatedAt),
          normalizedUserId,
          normalizedText,
          trimmed,
          nextUpdatedAt.millisecondsSinceEpoch,
        ],
      );
      changed.add(
        PreferenceEntry(
          id: rows.single['id'] as String,
          text: trimmed,
          updatedAt: nextUpdatedAt,
        ),
      );
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
    await _executor.runCustom(
      'DELETE FROM preference_items WHERE user_id = ?;',
      [userId.trim()],
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
  updated_at INTEGER NOT NULL
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
