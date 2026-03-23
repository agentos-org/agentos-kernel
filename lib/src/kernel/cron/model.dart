import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

enum CronTaskStatus { active, paused, deleted }

enum CronTaskConcurrencyPolicy { allow, skipIfRunning, replace }

enum CronRunStatus { running, succeeded, failed, cancelled }

enum CronRunTrigger { manual, schedule }

class AgentCronSpec {
  final String systemPrompt;
  final List<Content> content;
  final int timeoutSeconds;
  final LLMConfig? llmConfig;

  const AgentCronSpec({
    required this.systemPrompt,
    required this.content,
    this.timeoutSeconds = 3600,
    this.llmConfig,
  });

  Capability toCapability({
    required LLMConfig llmConfig,
    List<LLMConfig>? llmConfigList,
    List<OpenSpec>? openSpecList,
    CallbackOpenTool? callbackOpenTool,
  }) {
    return Capability(
      llmConfig: llmConfig,
      systemPrompt: systemPrompt,
      openSpecList: openSpecList,
      callbackOpenTool: callbackOpenTool,
      timeoutSeconds: timeoutSeconds,
      taskPipelineStrategy: PipelineStrategyType.parallel,
      toolPipelineStrategy: PipelineStrategyType.parallel,
      auto: true,
      llmConfigList: llmConfigList,
      enableThinking: true,
    );
  }

  UserTask toUserTask({DateTime? now}) {
    return UserTask(content: _contentWithCurrentTime(now: now), isChunk: false);
  }

  List<Content> _contentWithCurrentTime({DateTime? now}) {
    final currentTime = _formatCurrentTime(now ?? DateTime.now());
    final suffix = '*Current Time: $currentTime*';
    if (content.isEmpty) {
      return [Content(type: ContentType.text, message: suffix)];
    }
    final items = List<Content>.from(content);
    final last = items.last;
    if (last.type == ContentType.text) {
      items[items.length - 1] = Content(
        type: last.type,
        message: '${last.message}\n$suffix',
      );
      return items;
    }
    items.add(Content(type: ContentType.text, message: suffix));
    return items;
  }

  String _formatCurrentTime(DateTime value) {
    String twoDigits(int input) => input.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}:${twoDigits(value.second)}';
  }
}

class CronTaskDefinition {
  final String cronId;
  final String name;
  final String schedule;
  final String source;
  final String? userId;
  final String? sessionId;
  final String? timezone;
  final CronTaskConcurrencyPolicy concurrency;
  final AgentCronSpec spec;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final CronTaskStatus status;

  const CronTaskDefinition({
    required this.cronId,
    required this.name,
    required this.schedule,
    required this.source,
    required this.concurrency,
    required this.spec,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.userId,
    this.sessionId,
    this.timezone,
    this.lastRunAt,
    this.nextRunAt,
  });

  bool get enabled => status == CronTaskStatus.active;

  CronTaskDefinition copyWith({
    String? name,
    String? schedule,
    String? source,
    Object? userId = _sentinel,
    Object? sessionId = _sentinel,
    Object? timezone = _sentinel,
    CronTaskConcurrencyPolicy? concurrency,
    AgentCronSpec? spec,
    DateTime? updatedAt,
    Object? lastRunAt = _sentinel,
    Object? nextRunAt = _sentinel,
    CronTaskStatus? status,
  }) {
    return CronTaskDefinition(
      cronId: cronId,
      name: name ?? this.name,
      schedule: schedule ?? this.schedule,
      source: source ?? this.source,
      userId: identical(userId, _sentinel) ? this.userId : userId as String?,
      sessionId: identical(sessionId, _sentinel)
          ? this.sessionId
          : sessionId as String?,
      timezone: identical(timezone, _sentinel)
          ? this.timezone
          : timezone as String?,
      concurrency: concurrency ?? this.concurrency,
      spec: spec ?? this.spec,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRunAt: identical(lastRunAt, _sentinel)
          ? this.lastRunAt
          : lastRunAt as DateTime?,
      nextRunAt: identical(nextRunAt, _sentinel)
          ? this.nextRunAt
          : nextRunAt as DateTime?,
      status: status ?? this.status,
    );
  }
}

class CronRunRecord {
  final String runId;
  final String cronId;
  final CronRunTrigger trigger;
  final DateTime scheduledAt;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final CronRunStatus status;
  final LLMConfig? llmConfig;
  final String? liteAgentSessionId;
  final String? error;
  final Map<String, dynamic>? result;
  final String? displayMessageId;
  final String? displayText;

  const CronRunRecord({
    required this.runId,
    required this.cronId,
    required this.trigger,
    required this.scheduledAt,
    required this.startedAt,
    required this.status,
    this.finishedAt,
    this.llmConfig,
    this.liteAgentSessionId,
    this.error,
    this.result,
    this.displayMessageId,
    this.displayText,
  });

  bool get hasDisplayableResult =>
      status == CronRunStatus.succeeded &&
      displayText != null &&
      displayText!.trim().isNotEmpty;

  CronRunRecord copyWith({
    DateTime? finishedAt,
    CronRunStatus? status,
    CronRunTrigger? trigger,
    Object? llmConfig = _sentinel,
    Object? liteAgentSessionId = _sentinel,
    Object? error = _sentinel,
    Object? result = _sentinel,
    Object? displayMessageId = _sentinel,
    Object? displayText = _sentinel,
  }) {
    return CronRunRecord(
      runId: runId,
      cronId: cronId,
      trigger: trigger ?? this.trigger,
      scheduledAt: scheduledAt,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      status: status ?? this.status,
      llmConfig: identical(llmConfig, _sentinel)
          ? this.llmConfig
          : llmConfig as LLMConfig?,
      liteAgentSessionId: identical(liteAgentSessionId, _sentinel)
          ? this.liteAgentSessionId
          : liteAgentSessionId as String?,
      error: identical(error, _sentinel) ? this.error : error as String?,
      result: identical(result, _sentinel)
          ? this.result
          : result as Map<String, dynamic>?,
      displayMessageId: identical(displayMessageId, _sentinel)
          ? this.displayMessageId
          : displayMessageId as String?,
      displayText: identical(displayText, _sentinel)
          ? this.displayText
          : displayText as String?,
    );
  }
}

class CronRunMessageRecord {
  final String messageId;
  final String runId;
  final String cronId;
  final DateTime timestamp;
  final AgentMessage message;

  const CronRunMessageRecord({
    required this.messageId,
    required this.runId,
    required this.cronId,
    required this.timestamp,
    required this.message,
  });
}

class CronExecutionResult {
  final LLMConfig? llmConfig;
  final String? liteAgentSessionId;
  final Map<String, dynamic>? result;
  final String? error;
  final List<AgentMessage> messages;
  final String? displayMessageId;
  final String? displayText;

  const CronExecutionResult({
    this.llmConfig,
    this.liteAgentSessionId,
    this.result,
    this.error,
    this.messages = const [],
    this.displayMessageId,
    this.displayText,
  });

  bool get success => error == null;
}

class CronSchedulerSnapshot {
  final bool running;
  final int activeTaskCount;
  final int runningTaskCount;
  final DateTime? lastTickAt;

  const CronSchedulerSnapshot({
    required this.running,
    required this.activeTaskCount,
    required this.runningTaskCount,
    this.lastTickAt,
  });
}

const _sentinel = Object();
