import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'memory.dart';
import 'model.dart';

class DriftMemory implements Memory {
  final QueryExecutor _executor;
  final _MemoryDbUser _user = _MemoryDbUser();
  final int _summaryLimit;
  Future<void>? _openFuture;

  DriftMemory(this._executor, {int summaryLimit = 5})
    : _summaryLimit = summaryLimit;

  factory DriftMemory.open({required String path, int summaryLimit = 5}) {
    return DriftMemory(_openConnection(path), summaryLimit: summaryLimit);
  }

  Future<void> _ensureOpen() {
    _openFuture ??= () async {
      await _executor.ensureOpen(_user);
      await _user.ensureInitialized(_executor);
    }();
    return _openFuture!;
  }

  @override
  Future<MemorySnapshot> getSnapshot({String? scope}) async {
    await _ensureOpen();
    final shortTerm = await getLatestStateRecord(
      type: shortTermMemoryType,
      scope: scope,
    );
    final longTerm = await getLatestStateRecord(
      type: longTermMemoryType,
      scope: scope,
    );
    final summaries = await listSummaryRecords(
      scope: scope,
      limit: _summaryLimit,
    );
    return MemorySnapshot(
      scope: scope,
      data: {
        'shortTermMemory': shortTerm?.data ?? const {},
        'longTermMemory': longTerm?.data ?? const {},
      },
      shortTermMemory: shortTerm?.data,
      longTermMemory: longTerm?.data,
      records: summaries,
    );
  }

  @override
  Future<void> record(MemoryRecord record) async {
    await _ensureOpen();
    final dataJson = _encodeJson(record.data);
    final extras = _extractExtras(record.data);
    await _executor.runCustom(
      '''
INSERT INTO memory_records (
  job_id,
  user_id,
  session_id,
  scope,
  type,
  data_json,
  timestamp,
  bundle_id,
  task_id,
  liteagent_session_id,
  message_index
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
      [
        record.jobId,
        record.userId,
        record.sessionId,
        record.scope,
        record.type,
        dataJson,
        record.timestamp.millisecondsSinceEpoch,
        extras.bundleId,
        extras.taskId,
        extras.liteAgentSessionId,
        extras.messageIndex,
      ],
    );
  }

  @override
  Future<void> deleteRecord(String id) async {
    await _ensureOpen();
    final recordId = int.tryParse(id);
    if (recordId == null) {
      return;
    }
    await _executor.runCustom('DELETE FROM memory_records WHERE id = ?;', [
      recordId,
    ]);
  }

  @override
  Future<List<MemoryRecord>> listRecords({
    String? scope,
    String? userId,
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int? limit,
    bool includeSummaries = false,
  }) async {
    await _ensureOpen();
    final rows = await _listDetailRows(
      scope: scope,
      userId: userId,
      type: type,
      after: after,
      before: before,
      offset: offset,
      limit: limit,
      includeSummaries: includeSummaries,
    );
    return rows.map(_recordFromRow).toList();
  }

  Future<DateTime?> getLatestSummaryTimestamp({
    String? scope,
    String? userId,
  }) async {
    await _ensureOpen();
    final where = <String>['type = ?'];
    final args = <Object?>[memorySummaryType];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    final rows = await _executor.runSelect('''
SELECT MAX(timestamp) AS max_ts
FROM memory_records
WHERE ${where.join(' AND ')};
''', args);
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['max_ts'];
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }

  Future<List<String>> listScopes() async {
    await _ensureOpen();
    final rows = await _executor.runSelect('''
SELECT DISTINCT scope
FROM memory_records
WHERE scope IS NOT NULL AND scope != ''
ORDER BY scope ASC;
''', const []);
    return rows
        .map((row) => row['scope'])
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
  }

  List<MemoryRecord> _listSummariesSync(List<Map<String, Object?>> rows) {
    return rows.map(_recordFromRow).toList();
  }

  Future<List<MemoryRecord>> listSummaryRecords({
    String? scope,
    String? userId,
    int? limit,
    DateTime? after,
    DateTime? before,
  }) async {
    await _ensureOpen();
    final where = <String>['type = ?'];
    final args = <Object?>[memorySummaryType];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    if (after != null) {
      where.add('timestamp > ?');
      args.add(after.millisecondsSinceEpoch);
    }
    if (before != null) {
      where.add('timestamp <= ?');
      args.add(before.millisecondsSinceEpoch);
    }
    final limitClause = (limit == null || limit <= 0) ? '' : 'LIMIT $limit';
    final rows = await _executor.runSelect('''
SELECT
  id,
  job_id,
  user_id,
  session_id,
  scope,
  type,
  data_json,
  timestamp
FROM memory_records
WHERE ${where.join(' AND ')}
ORDER BY timestamp DESC
$limitClause;
''', args);
    final summaries = _listSummariesSync(rows);
    return summaries..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<MemoryRecord?> getLatestStateRecord({
    required String type,
    String? scope,
    String? userId,
  }) async {
    await _ensureOpen();
    final where = <String>['type = ?'];
    final args = <Object?>[type];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    final rows = await _executor.runSelect('''
SELECT
  id,
  job_id,
  user_id,
  session_id,
  scope,
  type,
  data_json,
  timestamp
FROM memory_records
WHERE ${where.join(' AND ')}
ORDER BY timestamp DESC
LIMIT 1;
''', args);
    if (rows.isEmpty) {
      return null;
    }
    return _recordFromRow(rows.first);
  }

  Future<void> deleteDetailRecordsBefore({
    required DateTime before,
    String? scope,
    String? userId,
  }) async {
    await _ensureOpen();
    final where = <String>['timestamp <= ?', 'type NOT IN (?, ?, ?)'];
    final args = <Object?>[
      before.millisecondsSinceEpoch,
      memorySummaryType,
      shortTermMemoryType,
      longTermMemoryType,
    ];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    await _executor.runCustom('''
DELETE FROM memory_records
WHERE ${where.join(' AND ')};
''', args);
  }

  Future<void> deleteSummaryRecordsBefore({
    required DateTime before,
    String? scope,
    String? userId,
  }) async {
    await _ensureOpen();
    final where = <String>['timestamp <= ?', 'type = ?'];
    final args = <Object?>[before.millisecondsSinceEpoch, memorySummaryType];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    await _executor.runCustom('''
DELETE FROM memory_records
WHERE ${where.join(' AND ')};
''', args);
  }

  Future<void> pruneStateRecords({
    required String type,
    int keepLatest = 3,
    String? scope,
    String? userId,
  }) async {
    await _ensureOpen();
    if (keepLatest < 0) {
      keepLatest = 0;
    }
    final where = <String>['type = ?'];
    final args = <Object?>[type];
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    final offsetClause = 'LIMIT -1 OFFSET $keepLatest';
    await _executor.runCustom('''
DELETE FROM memory_records
WHERE id IN (
  SELECT id
  FROM memory_records
  WHERE ${where.join(' AND ')}
  ORDER BY timestamp DESC
  $offsetClause
);
''', args);
  }

  Future<List<Map<String, Object?>>> _listDetailRows({
    String? scope,
    String? userId,
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int? limit,
    bool includeSummaries = false,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeSummaries) {
      where.add('type NOT IN (?, ?, ?)');
      args.add(memorySummaryType);
      args.add(shortTermMemoryType);
      args.add(longTermMemoryType);
    }
    if (scope != null && scope.isNotEmpty) {
      where.add('scope = ?');
      args.add(scope);
    }
    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }
    if (type != null && type.isNotEmpty) {
      where.add('type = ?');
      args.add(type);
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
    final limitClause = (limit == null || limit <= 0) ? '' : 'LIMIT $limit';
    final offsetClause = offset <= 0 ? '' : 'OFFSET $offset';
    return _executor.runSelect('''
SELECT
  id,
  job_id,
  user_id,
  session_id,
  scope,
  type,
  data_json,
  timestamp
FROM memory_records
$whereClause
ORDER BY timestamp ASC
$limitClause
$offsetClause;
''', args);
  }

  MemoryRecord _recordFromRow(Map<String, Object?> row) {
    final timestamp = row['timestamp'] as int? ?? 0;
    return MemoryRecord(
      id: (row['id'] as int?)?.toString(),
      jobId: row['job_id'] as String,
      userId: row['user_id'] as String?,
      sessionId: row['session_id'] as String?,
      scope: row['scope'] as String?,
      type: row['type'] as String,
      data: _decodeJson(row['data_json'] as String?),
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }

  String? _encodeJson(Map<String, dynamic>? data) {
    if (data == null) {
      return null;
    }
    try {
      return jsonEncode(data);
    } catch (error) {
      return jsonEncode({'_raw': data.toString(), '_error': error.toString()});
    }
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

  _MemoryExtras _extractExtras(Map<String, dynamic>? data) {
    if (data == null) {
      return const _MemoryExtras();
    }
    return _MemoryExtras(
      bundleId: _stringFromKeys(data, const ['bundleId', 'bundle_id']),
      taskId: _stringFromKeys(data, const ['taskId', 'task_id']),
      liteAgentSessionId: _stringFromKeys(data, const [
        'liteAgentSessionId',
        'liteagentSessionId',
        'liteagent_session_id',
      ]),
      messageIndex: _intFromKeys(data, const ['messageIndex', 'message_index']),
    );
  }

  String? _stringFromKeys(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  int? _intFromKeys(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }
}

class _MemoryExtras {
  final String? bundleId;
  final String? taskId;
  final String? liteAgentSessionId;
  final int? messageIndex;

  const _MemoryExtras({
    this.bundleId,
    this.taskId,
    this.liteAgentSessionId,
    this.messageIndex,
  });
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
CREATE TABLE IF NOT EXISTS memory_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,
  user_id TEXT,
  session_id TEXT,
  scope TEXT,
  type TEXT NOT NULL,
  data_json TEXT,
  timestamp INTEGER NOT NULL,
  bundle_id TEXT,
  task_id TEXT,
  liteagent_session_id TEXT,
  message_index INTEGER
);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_scope_ts
  ON memory_records (scope, timestamp);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_scope_type_ts
  ON memory_records (scope, type, timestamp);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_user_ts
  ON memory_records (user_id, timestamp);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_session_ts
  ON memory_records (session_id, timestamp);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_bundle_ts
  ON memory_records (bundle_id, timestamp);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_task_id
  ON memory_records (task_id);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS memory_records_liteagent_session_ts
  ON memory_records (liteagent_session_id, timestamp);
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
