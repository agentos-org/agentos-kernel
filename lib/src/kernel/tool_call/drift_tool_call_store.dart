import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tool_call_store.dart';

class DriftToolCallStore implements ToolCallStore {
  final QueryExecutor _executor;
  final _ToolCallDbUser _user = _ToolCallDbUser();
  Future<void>? _openFuture;

  DriftToolCallStore(this._executor);

  factory DriftToolCallStore.open({required String path}) {
    return DriftToolCallStore(_openConnection(path));
  }

  Future<void> _ensureOpen() {
    _openFuture ??= _executor.ensureOpen(_user);
    return _openFuture!;
  }

  @override
  Future<void> record(ToolCallRecord record) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO tool_call_records (
  job_id,
  user_id,
  session_id,
  source,
  tool_id,
  function,
  status,
  arguments_json,
  result_json,
  error,
  started_at,
  completed_at,
  duration_ms
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
      [
        record.jobId,
        record.userId,
        record.sessionId,
        record.source,
        record.toolId,
        record.function,
        record.status,
        record.argumentsJson,
        record.resultJson,
        record.error,
        record.startedAt.millisecondsSinceEpoch,
        record.completedAt.millisecondsSinceEpoch,
        record.durationMs,
      ],
    );
  }
}

class _ToolCallDbUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {
    await executor.runCustom(
      '''
CREATE TABLE IF NOT EXISTS tool_call_records (
  job_id TEXT NOT NULL,
  user_id TEXT,
  session_id TEXT,
  source TEXT,
  tool_id TEXT NOT NULL,
  function TEXT NOT NULL,
  status TEXT NOT NULL,
  arguments_json TEXT,
  result_json TEXT,
  error TEXT,
  started_at INTEGER NOT NULL,
  completed_at INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  PRIMARY KEY (job_id, tool_id, function, started_at)
);
''',
    );
  }
}

QueryExecutor _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return NativeDatabase(file);
  });
}
