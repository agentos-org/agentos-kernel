import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import 'model.dart';

abstract class CronTaskStore {
  Future<CronTaskDefinition> putTask(CronTaskDefinition task);
  Future<CronTaskDefinition?> getTask(String cronId);
  Future<List<CronTaskDefinition>> listTasks();
  Future<void> deleteTask(String cronId);
  Future<CronRunRecord> putRun(CronRunRecord run);
  Future<CronRunRecord?> getRun(String runId);
  Future<List<CronRunRecord>> listRuns({String? cronId});
  Future<void> deleteRun(String runId);
  Future<CronRunMessageRecord> putRunMessage(CronRunMessageRecord message);
  Future<List<CronRunMessageRecord>> listRunMessages(String runId);
}

class InMemoryCronTaskStore implements CronTaskStore {
  final Map<String, CronTaskDefinition> _tasks = {};
  final Map<String, CronRunRecord> _runs = {};
  final Map<String, CronRunMessageRecord> _messages = {};

  @override
  Future<void> deleteTask(String cronId) async {
    _tasks.remove(cronId);
  }

  @override
  Future<CronTaskDefinition?> getTask(String cronId) async {
    return _tasks[cronId];
  }

  @override
  Future<CronRunRecord?> getRun(String runId) async {
    return _runs[runId];
  }

  @override
  Future<List<CronRunRecord>> listRuns({String? cronId}) async {
    final values = _runs.values
        .where((run) {
          if (cronId == null || cronId.isEmpty) {
            return true;
          }
          return run.cronId == cronId;
        })
        .toList(growable: false);
    values.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return values;
  }

  @override
  Future<List<CronRunMessageRecord>> listRunMessages(String runId) async {
    final values = _messages.values
        .where((message) => message.runId == runId)
        .toList(growable: false);
    values.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return values;
  }

  @override
  Future<void> deleteRun(String runId) async {
    _runs.remove(runId);
    _messages.removeWhere((_, message) => message.runId == runId);
  }

  @override
  Future<List<CronTaskDefinition>> listTasks() async {
    final values = _tasks.values.toList(growable: false);
    values.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return values;
  }

  @override
  Future<CronRunRecord> putRun(CronRunRecord run) async {
    _runs[run.runId] = run;
    return run;
  }

  @override
  Future<CronRunMessageRecord> putRunMessage(
    CronRunMessageRecord message,
  ) async {
    _messages[message.messageId] = message;
    return message;
  }

  @override
  Future<CronTaskDefinition> putTask(CronTaskDefinition task) async {
    _tasks[task.cronId] = task;
    return task;
  }
}

class DriftCronTaskStore implements CronTaskStore {
  final QueryExecutor _executor;
  final _CronDbUser _user = _CronDbUser();
  Future<void>? _openFuture;

  DriftCronTaskStore(this._executor);

  factory DriftCronTaskStore.open({required String path}) {
    return DriftCronTaskStore(_openConnection(path));
  }

  Future<void> _ensureOpen() {
    _openFuture ??= () async {
      await _executor.ensureOpen(_user);
      await _user.ensureInitialized(_executor);
    }();
    return _openFuture!;
  }

  @override
  Future<CronTaskDefinition> putTask(CronTaskDefinition task) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO cron_tasks (
  cron_id,
  name,
  schedule,
  source,
  user_id,
  session_id,
  timezone,
  concurrency,
  spec_json,
  created_at,
  updated_at,
  last_run_at,
  next_run_at,
  status
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(cron_id) DO UPDATE SET
  name = excluded.name,
  schedule = excluded.schedule,
  source = excluded.source,
  user_id = excluded.user_id,
  session_id = excluded.session_id,
  timezone = excluded.timezone,
  concurrency = excluded.concurrency,
  spec_json = excluded.spec_json,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at,
  last_run_at = excluded.last_run_at,
  next_run_at = excluded.next_run_at,
  status = excluded.status;
''',
      [
        task.cronId,
        task.name,
        task.schedule,
        task.source,
        task.userId,
        task.sessionId,
        task.timezone,
        task.concurrency.name,
        jsonEncode(_taskSpecToMap(task.spec)),
        task.createdAt.millisecondsSinceEpoch,
        task.updatedAt.millisecondsSinceEpoch,
        task.lastRunAt?.millisecondsSinceEpoch,
        task.nextRunAt?.millisecondsSinceEpoch,
        task.status.name,
      ],
    );
    return task;
  }

  @override
  Future<CronTaskDefinition?> getTask(String cronId) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT *
FROM cron_tasks
WHERE cron_id = ?
LIMIT 1;
''',
      [cronId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _taskFromRow(rows.first);
  }

  @override
  Future<List<CronTaskDefinition>> listTasks() async {
    await _ensureOpen();
    final rows = await _executor.runSelect('''
SELECT *
FROM cron_tasks
ORDER BY created_at ASC;
''', const []);
    return rows.map(_taskFromRow).toList(growable: false);
  }

  @override
  Future<void> deleteTask(String cronId) async {
    await _ensureOpen();
    await _executor.runCustom('DELETE FROM cron_tasks WHERE cron_id = ?;', [
      cronId,
    ]);
  }

  @override
  Future<CronRunRecord> putRun(CronRunRecord run) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO cron_runs (
  run_id,
  cron_id,
  trigger,
  scheduled_at,
  started_at,
  finished_at,
  status,
  llm_config_json,
  liteagent_session_id,
  error,
  result_json,
  display_message_id,
  display_text
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(run_id) DO UPDATE SET
  cron_id = excluded.cron_id,
  trigger = excluded.trigger,
  scheduled_at = excluded.scheduled_at,
  started_at = excluded.started_at,
  finished_at = excluded.finished_at,
  status = excluded.status,
  llm_config_json = excluded.llm_config_json,
  liteagent_session_id = excluded.liteagent_session_id,
  error = excluded.error,
  result_json = excluded.result_json,
  display_message_id = excluded.display_message_id,
  display_text = excluded.display_text;
''',
      [
        run.runId,
        run.cronId,
        run.trigger.name,
        run.scheduledAt.millisecondsSinceEpoch,
        run.startedAt.millisecondsSinceEpoch,
        run.finishedAt?.millisecondsSinceEpoch,
        run.status.name,
        _encodeJson(_llmConfigToMap(run.llmConfig)),
        run.liteAgentSessionId,
        run.error,
        _encodeJson(run.result),
        run.displayMessageId,
        run.displayText,
      ],
    );
    return run;
  }

  @override
  Future<CronRunRecord?> getRun(String runId) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT *
FROM cron_runs
WHERE run_id = ?
LIMIT 1;
''',
      [runId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _runFromRow(rows.first);
  }

  @override
  Future<List<CronRunRecord>> listRuns({String? cronId}) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT *
FROM cron_runs
WHERE (? IS NULL OR ? = '' OR cron_id = ?)
ORDER BY started_at DESC;
''',
      [cronId, cronId, cronId],
    );
    return rows.map(_runFromRow).toList(growable: false);
  }

  @override
  Future<void> deleteRun(String runId) async {
    await _ensureOpen();
    await _executor.runCustom('DELETE FROM cron_runs WHERE run_id = ?;', [
      runId,
    ]);
    await _executor.runCustom(
      'DELETE FROM cron_run_messages WHERE run_id = ?;',
      [runId],
    );
  }

  @override
  Future<CronRunMessageRecord> putRunMessage(
    CronRunMessageRecord message,
  ) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO cron_run_messages (
  message_id,
  run_id,
  cron_id,
  timestamp,
  message_json
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(message_id) DO UPDATE SET
  run_id = excluded.run_id,
  cron_id = excluded.cron_id,
  timestamp = excluded.timestamp,
  message_json = excluded.message_json;
''',
      [
        message.messageId,
        message.runId,
        message.cronId,
        message.timestamp.millisecondsSinceEpoch,
        jsonEncode(message.message.toJson()),
      ],
    );
    return message;
  }

  @override
  Future<List<CronRunMessageRecord>> listRunMessages(String runId) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT *
FROM cron_run_messages
WHERE run_id = ?
ORDER BY timestamp ASC;
''',
      [runId],
    );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  Map<String, dynamic> _taskSpecToMap(AgentCronSpec task) {
    return {
      'systemPrompt': task.systemPrompt,
      'content': task.content.map((item) => item.toJson()).toList(),
      'timeoutSeconds': task.timeoutSeconds,
      'llmConfig': _llmConfigToMap(task.llmConfig),
      'skills': task.skills,
    };
  }

  CronTaskDefinition _taskFromRow(Map<String, Object?> row) {
    final specMap = _decodeJsonMap(row['spec_json'] as String?) ?? const {};
    final contentList = (specMap['content'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Content.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    return CronTaskDefinition(
      cronId: row['cron_id'] as String? ?? '',
      name: row['name'] as String? ?? '',
      schedule: row['schedule'] as String? ?? '',
      source: row['source'] as String? ?? '',
      userId: row['user_id'] as String?,
      sessionId: row['session_id'] as String?,
      timezone: row['timezone'] as String?,
      concurrency: CronTaskConcurrencyPolicy.values.byName(
        row['concurrency'] as String? ??
            CronTaskConcurrencyPolicy.skipIfRunning.name,
      ),
      spec: AgentCronSpec(
        systemPrompt: specMap['systemPrompt'] as String,
        content: contentList,
        timeoutSeconds: (specMap['timeoutSeconds'] as num?)?.toInt() ?? 3600,
        llmConfig: _llmConfigFromMap(specMap['llmConfig']),
        skills: (specMap['skills'] as List<dynamic>?)
            ?.map((item) => item as String)
            .toList(growable: false),
      ),
      createdAt: _fromEpoch(row['created_at'] as int?),
      updatedAt: _fromEpoch(row['updated_at'] as int?),
      lastRunAt: _fromNullableEpoch(row['last_run_at'] as int?),
      nextRunAt: _fromNullableEpoch(row['next_run_at'] as int?),
      status: CronTaskStatus.values.byName(
        row['status'] as String? ?? CronTaskStatus.active.name,
      ),
    );
  }

  CronRunRecord _runFromRow(Map<String, Object?> row) {
    return CronRunRecord(
      runId: row['run_id'] as String? ?? '',
      cronId: row['cron_id'] as String? ?? '',
      trigger: row['trigger'] == null
          ? CronRunTrigger.schedule
          : CronRunTrigger.values.byName(
              row['trigger'] as String? ?? CronRunTrigger.schedule.name,
            ),
      scheduledAt: _fromEpoch(row['scheduled_at'] as int?),
      startedAt: _fromEpoch(row['started_at'] as int?),
      finishedAt: _fromNullableEpoch(row['finished_at'] as int?),
      status: CronRunStatus.values.byName(
        row['status'] as String? ?? CronRunStatus.running.name,
      ),
      llmConfig: _llmConfigFromMap(
        _decodeJsonMap(row['llm_config_json'] as String?),
      ),
      liteAgentSessionId: row['liteagent_session_id'] as String?,
      error: row['error'] as String?,
      result: _decodeJsonMap(row['result_json'] as String?),
      displayMessageId: row['display_message_id'] as String?,
      displayText: row['display_text'] as String?,
    );
  }

  CronRunMessageRecord _messageFromRow(Map<String, Object?> row) {
    final normalized =
        _decodeJsonMap(row['message_json'] as String?) ?? const {};
    return CronRunMessageRecord(
      messageId: row['message_id'] as String? ?? '',
      runId: row['run_id'] as String? ?? '',
      cronId: row['cron_id'] as String? ?? '',
      timestamp: _fromEpoch(row['timestamp'] as int?),
      message: AgentMessage.fromJson(normalized),
    );
  }

  DateTime _fromEpoch(int? value) {
    return DateTime.fromMillisecondsSinceEpoch(value ?? 0);
  }

  DateTime? _fromNullableEpoch(int? value) {
    if (value == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  Map<String, dynamic>? _decodeJsonMap(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  String? _encodeJson(Object? value) {
    if (value == null) {
      return null;
    }
    return jsonEncode(value);
  }

  Map<String, dynamic>? _llmConfigToMap(LLMConfig? config) {
    if (config == null) {
      return null;
    }
    return {
      'baseUrl': config.baseUrl,
      'apiKey': config.apiKey,
      'model': config.model,
      'contextWindowSize': config.contextWindowSize,
    };
  }

  LLMConfig? _llmConfigFromMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final baseUrl = value['baseUrl'] as String?;
    final model = value['model'] as String?;
    if (baseUrl == null || model == null) {
      return null;
    }
    return LLMConfig(
      baseUrl: baseUrl,
      apiKey: value['apiKey'] as String?,
      model: model,
      contextWindowSize: (value['contextWindowSize'] as num?)?.toInt(),
    );
  }
}

class _CronDbUser implements QueryExecutorUser {
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
CREATE TABLE IF NOT EXISTS cron_tasks (
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
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS cron_runs (
  run_id TEXT PRIMARY KEY,
  cron_id TEXT NOT NULL,
  trigger TEXT NOT NULL,
  scheduled_at INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  status TEXT NOT NULL,
  llm_config_json TEXT,
  liteagent_session_id TEXT,
  error TEXT,
  result_json TEXT,
  display_message_id TEXT,
  display_text TEXT
);
''');
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS cron_run_messages (
  message_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  cron_id TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  message_json TEXT NOT NULL
);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS cron_runs_cron_id_started_at
  ON cron_runs (cron_id, started_at);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS cron_run_messages_run_id_timestamp
  ON cron_run_messages (run_id, timestamp);
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
