import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import 'executor.dart';
import 'model.dart';
import 'scheduler.dart';
import 'store.dart';

class CronModule {
  final CronTaskStore _store;
  final CronTaskExecutor _executor;
  late final CronScheduler _scheduler;
  final Set<String> _runningTaskIds = <String>{};
  int _taskCounter = 0;
  int _runCounter = 0;
  int _messageCounter = 0;

  CronModule({required CronTaskStore store, required CronTaskExecutor executor})
    : _store = store,
      _executor = executor {
    _scheduler = CronScheduler(onTrigger: runNow);
  }

  Future<CronTaskDefinition> createTask({
    required String name,
    required String schedule,
    required AgentCronSpec spec,
    required String source,
    String? userId,
    String? sessionId,
    String? timezone,
    CronTaskConcurrencyPolicy concurrency =
        CronTaskConcurrencyPolicy.skipIfRunning,
    bool enabled = true,
  }) async {
    final now = DateTime.now();
    final task = CronTaskDefinition(
      cronId: _nextCronId(now),
      name: name,
      schedule: schedule,
      source: source,
      userId: userId,
      sessionId: sessionId,
      timezone: timezone,
      concurrency: concurrency,
      spec: spec,
      createdAt: now,
      updatedAt: now,
      nextRunAt: null,
      status: enabled ? CronTaskStatus.active : CronTaskStatus.paused,
    );
    final stored = await _store.putTask(task);
    await _refreshSchedule();
    return stored;
  }

  Future<CronTaskDefinition?> getTask(String cronId) {
    return _store.getTask(cronId);
  }

  Future<List<CronTaskDefinition>> listTasks({
    bool? enabled,
    String? source,
  }) async {
    final tasks = await _store.listTasks();
    return tasks
        .where((task) {
          if (enabled != null && task.enabled != enabled) {
            return false;
          }
          if (source != null && source.isNotEmpty && task.source != source) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<CronTaskDefinition> updateTask({
    required String cronId,
    String? name,
    String? schedule,
    AgentCronSpec? spec,
    String? timezone,
    CronTaskConcurrencyPolicy? concurrency,
    bool? enabled,
  }) async {
    final current = await _requireTask(cronId);
    final next = current.copyWith(
      name: name,
      schedule: schedule,
      spec: spec,
      timezone: timezone,
      concurrency: concurrency,
      status: enabled == null
          ? null
          : (enabled ? CronTaskStatus.active : CronTaskStatus.paused),
      updatedAt: DateTime.now(),
    );
    final stored = await _store.putTask(next);
    await _refreshSchedule();
    return stored;
  }

  Future<void> deleteTask(String cronId) async {
    await _store.deleteTask(cronId);
    await _refreshSchedule();
  }

  Future<CronTaskDefinition> pauseTask(String cronId) async {
    return updateTask(cronId: cronId, enabled: false);
  }

  Future<CronTaskDefinition> resumeTask(String cronId) async {
    return updateTask(cronId: cronId, enabled: true);
  }

  Future<CronRunRecord> runNow(
    CronTaskDefinition task, {
    DateTime? scheduledAt,
    CronRunTrigger trigger = CronRunTrigger.schedule,
  }) async {
    if (_runningTaskIds.contains(task.cronId)) {
      switch (task.concurrency) {
        case CronTaskConcurrencyPolicy.allow:
          break;
        case CronTaskConcurrencyPolicy.skipIfRunning:
          final skipped = CronRunRecord(
            runId: _nextRunId(),
            cronId: task.cronId,
            trigger: trigger,
            scheduledAt: scheduledAt ?? DateTime.now(),
            startedAt: DateTime.now(),
            finishedAt: DateTime.now(),
            status: CronRunStatus.cancelled,
            error: 'Skipped because task is already running.',
          );
          await _store.putRun(skipped);
          return skipped;
        case CronTaskConcurrencyPolicy.replace:
          final rejected = CronRunRecord(
            runId: _nextRunId(),
            cronId: task.cronId,
            trigger: trigger,
            scheduledAt: scheduledAt ?? DateTime.now(),
            startedAt: DateTime.now(),
            finishedAt: DateTime.now(),
            status: CronRunStatus.cancelled,
            error: 'Replace policy is not supported yet.',
          );
          await _store.putRun(rejected);
          return rejected;
      }
    }

    _runningTaskIds.add(task.cronId);
    final now = DateTime.now();
    final baseRun = CronRunRecord(
      runId: _nextRunId(),
      cronId: task.cronId,
      trigger: trigger,
      scheduledAt: scheduledAt ?? now,
      startedAt: now,
      status: CronRunStatus.running,
      llmConfig: task.spec.llmConfig,
    );
    await _store.putRun(baseRun);
    print(
      jsonEncode({
        'tag': 'cron_module_stage',
        'stage': 'run_persisted_running',
        'timestamp': DateTime.now().toIso8601String(),
        'data': {
          'cronId': task.cronId,
          'runId': baseRun.runId,
          'status': baseRun.status.name,
        },
      }),
    );
    final storedMessageKeys = <String>{};
    try {
      final execution = await _executor.run(
        task,
        onMessage: (message) async {
          final key = _messageStorageKey(message);
          if (!storedMessageKeys.add(key)) {
            return;
          }
          await _store.putRunMessage(
            CronRunMessageRecord(
              messageId: _nextMessageId(),
              runId: baseRun.runId,
              cronId: task.cronId,
              timestamp: message.createTime,
              message: message,
            ),
          );
        },
      );
      for (final message in execution.messages) {
        final key = _messageStorageKey(message);
        if (!storedMessageKeys.add(key)) {
          continue;
        }
        await _store.putRunMessage(
          CronRunMessageRecord(
            messageId: _nextMessageId(),
            runId: baseRun.runId,
            cronId: task.cronId,
            timestamp: message.createTime,
            message: message,
          ),
        );
      }
      final finished = baseRun.copyWith(
        finishedAt: DateTime.now(),
        status: execution.success
            ? CronRunStatus.succeeded
            : CronRunStatus.failed,
        llmConfig: execution.llmConfig,
        liteAgentSessionId: execution.liteAgentSessionId,
        error: execution.error,
        result: execution.result,
        displayMessageId: execution.displayMessageId,
        displayText: execution.displayText,
      );
      await _store.putRun(finished);
      print(
        jsonEncode({
          'tag': 'cron_module_stage',
          'stage': 'run_persisted_finished',
          'timestamp': DateTime.now().toIso8601String(),
          'data': {
            'cronId': task.cronId,
            'runId': finished.runId,
            'status': finished.status.name,
            'displayText': finished.displayText,
            'displayMessageId': finished.displayMessageId,
            'hasDisplayableResult': finished.hasDisplayableResult,
          },
        }),
      );
      final updatedTask = task.copyWith(
        lastRunAt: finished.finishedAt,
        updatedAt: DateTime.now(),
      );
      await _store.putTask(updatedTask);
      return finished;
    } finally {
      _runningTaskIds.remove(task.cronId);
    }
  }

  Future<CronRunRecord> runTaskNow(
    String cronId, {
    DateTime? scheduledAt,
  }) async {
    final task = await _requireTask(cronId);
    return runNow(
      task,
      scheduledAt: scheduledAt,
      trigger: CronRunTrigger.manual,
    );
  }

  Future<List<CronRunRecord>> listRuns({String? cronId}) {
    return _store.listRuns(cronId: cronId);
  }

  Future<CronRunRecord?> getRun(String runId) {
    return _store.getRun(runId);
  }

  Future<void> deleteRun(String runId) {
    return _store.deleteRun(runId);
  }

  Future<List<CronRunMessageRecord>> listRunMessages(String runId) {
    return _store.listRunMessages(runId);
  }

  Future<void> start() async {
    final tasks = await _store.listTasks();
    await _scheduler.start(tasks);
  }

  Future<void> stop() {
    return _scheduler.stop();
  }

  Future<CronSchedulerSnapshot> snapshot() async {
    final tasks = await _store.listTasks();
    final activeTaskCount = tasks.where((task) => task.enabled).length;
    return CronSchedulerSnapshot(
      running: _scheduler.isRunning,
      activeTaskCount: activeTaskCount,
      runningTaskCount: _runningTaskIds.length,
      lastTickAt: _scheduler.lastTickAt,
    );
  }

  Future<void> _refreshSchedule() async {
    if (!_scheduler.isRunning) {
      return;
    }
    final tasks = await _store.listTasks();
    await _scheduler.refresh(tasks);
  }

  Future<CronTaskDefinition> _requireTask(String cronId) async {
    final task = await _store.getTask(cronId);
    if (task == null) {
      throw StateError('Unknown cronId: $cronId');
    }
    return task;
  }

  String _nextCronId(DateTime now) {
    return 'cron-${now.microsecondsSinceEpoch}-${_taskCounter++}';
  }

  String _nextRunId() {
    return 'cron-run-${DateTime.now().microsecondsSinceEpoch}-${_runCounter++}';
  }

  String _nextMessageId() {
    return 'cron-msg-${DateTime.now().microsecondsSinceEpoch}-${_messageCounter++}';
  }

  String _messageStorageKey(AgentMessage message) {
    return [
      message.sessionId,
      message.parentTaskId ?? '',
      message.taskId,
      message.role,
      message.to,
      message.type,
      message.createTime.toIso8601String(),
      message.content.toString(),
      message.reasoningContent ?? '',
    ].join('|');
  }
}
