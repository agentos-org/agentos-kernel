import 'package:hive/hive.dart';
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

class HiveCronTaskStore implements CronTaskStore {
  final Box<Map> _taskBox;
  final Box<Map> _runBox;
  final Box<Map> _messageBox;

  HiveCronTaskStore({
    required Box<Map> taskBox,
    required Box<Map> runBox,
    required Box<Map> messageBox,
  }) : _taskBox = taskBox,
       _runBox = runBox,
       _messageBox = messageBox;

  @override
  Future<CronTaskDefinition> putTask(CronTaskDefinition task) async {
    await _taskBox.put(task.cronId, _taskToMap(task));
    return task;
  }

  @override
  Future<CronTaskDefinition?> getTask(String cronId) async {
    final value = _taskBox.get(cronId);
    return _taskFromMap(value);
  }

  @override
  Future<List<CronTaskDefinition>> listTasks() async {
    final values = _taskBox.values
        .map(_taskFromMap)
        .whereType<CronTaskDefinition>()
        .toList(growable: false);
    values.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return values;
  }

  @override
  Future<void> deleteTask(String cronId) async {
    await _taskBox.delete(cronId);
  }

  @override
  Future<CronRunRecord> putRun(CronRunRecord run) async {
    await _runBox.put(run.runId, _runToMap(run));
    return run;
  }

  @override
  Future<CronRunRecord?> getRun(String runId) async {
    final value = _runBox.get(runId);
    return _runFromMap(value);
  }

  @override
  Future<List<CronRunRecord>> listRuns({String? cronId}) async {
    final values = _runBox.values
        .map(_runFromMap)
        .whereType<CronRunRecord>()
        .where(
          (run) => cronId == null || cronId.isEmpty || run.cronId == cronId,
        )
        .toList(growable: false);
    values.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return values;
  }

  @override
  Future<void> deleteRun(String runId) async {
    await _runBox.delete(runId);
    final messageIds = _messageBox.values
        .map(_messageFromMap)
        .whereType<CronRunMessageRecord>()
        .where((message) => message.runId == runId)
        .map((message) => message.messageId)
        .toList(growable: false);
    if (messageIds.isEmpty) {
      return;
    }
    await _messageBox.deleteAll(messageIds);
  }

  @override
  Future<CronRunMessageRecord> putRunMessage(
    CronRunMessageRecord message,
  ) async {
    await _messageBox.put(message.messageId, _messageToMap(message));
    return message;
  }

  @override
  Future<List<CronRunMessageRecord>> listRunMessages(String runId) async {
    final values = _messageBox.values
        .map(_messageFromMap)
        .whereType<CronRunMessageRecord>()
        .where((message) => message.runId == runId)
        .toList(growable: false);
    values.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return values;
  }

  Map<String, dynamic> _taskToMap(CronTaskDefinition task) {
    return {
      'cronId': task.cronId,
      'name': task.name,
      'schedule': task.schedule,
      'source': task.source,
      'userId': task.userId,
      'sessionId': task.sessionId,
      'timezone': task.timezone,
      'concurrency': task.concurrency.name,
      'spec': {
        'systemPrompt': task.spec.systemPrompt,
        'content': task.spec.content.map((item) => item.toJson()).toList(),
        'timeoutSeconds': task.spec.timeoutSeconds,
        'llmConfig': _llmConfigToMap(task.spec.llmConfig),
      },
      'createdAt': task.createdAt.toIso8601String(),
      'updatedAt': task.updatedAt.toIso8601String(),
      'lastRunAt': task.lastRunAt?.toIso8601String(),
      'nextRunAt': task.nextRunAt?.toIso8601String(),
      'status': task.status.name,
    };
  }

  CronTaskDefinition? _taskFromMap(Map<dynamic, dynamic>? value) {
    if (value == null) {
      return null;
    }
    final specMap = value['spec'];
    if (specMap is! Map) {
      return null;
    }
    final contentList = (specMap['content'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Content.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    return CronTaskDefinition(
      cronId: value['cronId'] as String,
      name: value['name'] as String,
      schedule: value['schedule'] as String,
      source: value['source'] as String,
      userId: value['userId'] as String?,
      sessionId: value['sessionId'] as String?,
      timezone: value['timezone'] as String?,
      concurrency: CronTaskConcurrencyPolicy.values.byName(
        value['concurrency'] as String,
      ),
      spec: AgentCronSpec(
        systemPrompt: specMap['systemPrompt'] as String,
        content: contentList,
        timeoutSeconds: (specMap['timeoutSeconds'] as num?)?.toInt() ?? 3600,
        llmConfig: _llmConfigFromMap(specMap['llmConfig']),
      ),
      createdAt: DateTime.parse(value['createdAt'] as String),
      updatedAt: DateTime.parse(value['updatedAt'] as String),
      lastRunAt: _parseDateTime(value['lastRunAt']),
      nextRunAt: _parseDateTime(value['nextRunAt']),
      status: CronTaskStatus.values.byName(value['status'] as String),
    );
  }

  Map<String, dynamic> _runToMap(CronRunRecord run) {
    return {
      'runId': run.runId,
      'cronId': run.cronId,
      'trigger': run.trigger.name,
      'scheduledAt': run.scheduledAt.toIso8601String(),
      'startedAt': run.startedAt.toIso8601String(),
      'finishedAt': run.finishedAt?.toIso8601String(),
      'status': run.status.name,
      'liteAgentSessionId': run.liteAgentSessionId,
      'error': run.error,
      'result': run.result,
      'displayMessageId': run.displayMessageId,
      'displayText': run.displayText,
    };
  }

  CronRunRecord? _runFromMap(Map<dynamic, dynamic>? value) {
    if (value == null) {
      return null;
    }
    return CronRunRecord(
      runId: value['runId'] as String,
      cronId: value['cronId'] as String,
      trigger: value['trigger'] == null
          ? CronRunTrigger.schedule
          : CronRunTrigger.values.byName(value['trigger'] as String),
      scheduledAt: DateTime.parse(value['scheduledAt'] as String),
      startedAt: DateTime.parse(value['startedAt'] as String),
      finishedAt: _parseDateTime(value['finishedAt']),
      status: CronRunStatus.values.byName(value['status'] as String),
      liteAgentSessionId: value['liteAgentSessionId'] as String?,
      error: value['error'] as String?,
      result: _asStringMap(value['result']),
      displayMessageId: value['displayMessageId'] as String?,
      displayText: value['displayText'] as String?,
    );
  }

  Map<String, dynamic> _messageToMap(CronRunMessageRecord message) {
    return {
      'messageId': message.messageId,
      'runId': message.runId,
      'cronId': message.cronId,
      'timestamp': message.timestamp.toIso8601String(),
      'message': message.message.toJson(),
    };
  }

  CronRunMessageRecord? _messageFromMap(Map<dynamic, dynamic>? value) {
    if (value == null) {
      return null;
    }
    final message = value['message'];
    if (message is! Map) {
      return null;
    }
    final normalized = _normalizeHiveJson(message);
    if (normalized is! Map<String, dynamic>) {
      return null;
    }
    return CronRunMessageRecord(
      messageId: value['messageId'] as String,
      runId: value['runId'] as String,
      cronId: value['cronId'] as String,
      timestamp: DateTime.parse(value['timestamp'] as String),
      message: AgentMessage.fromJson(normalized),
    );
  }

  DateTime? _parseDateTime(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.parse(value);
    }
    return null;
  }

  Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  Object? _normalizeHiveJson(Object? value) {
    if (value is Map) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _normalizeHiveJson(nestedValue)),
      );
    }
    if (value is List) {
      return value.map(_normalizeHiveJson).toList(growable: false);
    }
    return value;
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
