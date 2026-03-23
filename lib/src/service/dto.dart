import 'package:json_annotation/json_annotation.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

part 'dto.g.dart';

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentRequestDto {
  final String source;
  final List<Content> content;
  final IntentHintsDto? hints;

  const IntentRequestDto({
    required this.source,
    required this.content,
    this.hints,
  });

  factory IntentRequestDto.fromJson(Map<String, dynamic> json) =>
      _$IntentRequestDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentRequestDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentHintsDto {
  final List<String>? allowedActions;
  final List<String>? preferredApps;
  final Map<String, dynamic>? extra;

  const IntentHintsDto({this.allowedActions, this.preferredApps, this.extra});

  factory IntentHintsDto.fromJson(Map<String, dynamic> json) =>
      _$IntentHintsDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentHintsDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentResponseDto {
  final List<IntentCandidateDto> candidates;

  const IntentResponseDto({required this.candidates});

  factory IntentResponseDto.fromJson(Map<String, dynamic> json) =>
      _$IntentResponseDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentResponseDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IntentCandidateDto {
  final String action;
  final Map<String, dynamic> payload;
  final double? confidence;
  final String? reason;
  final FunctionCallDto? call;

  const IntentCandidateDto({
    required this.action,
    required this.payload,
    this.confidence,
    this.reason,
    this.call,
  });

  factory IntentCandidateDto.fromJson(Map<String, dynamic> json) =>
      _$IntentCandidateDtoFromJson(json);

  Map<String, dynamic> toJson() => _$IntentCandidateDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class FunctionCallDto {
  final String name;
  final Map<String, dynamic> arguments;

  const FunctionCallDto({required this.name, required this.arguments});

  factory FunctionCallDto.fromJson(Map<String, dynamic> json) =>
      _$FunctionCallDtoFromJson(json);

  Map<String, dynamic> toJson() => _$FunctionCallDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class AgentCronSpecDto {
  final String systemPrompt;
  final List<Content> content;
  final int timeoutSeconds;
  final LLMConfig? llmConfig;

  const AgentCronSpecDto({
    required this.systemPrompt,
    required this.content,
    this.timeoutSeconds = 3600,
    this.llmConfig,
  });

  factory AgentCronSpecDto.fromJson(Map<String, dynamic> json) =>
      _$AgentCronSpecDtoFromJson(json);

  Map<String, dynamic> toJson() => _$AgentCronSpecDtoToJson(this);
}

enum CronTaskConcurrencyDto { allow, skipIfRunning, replace }

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class CronTaskDto {
  final String cronId;
  final String name;
  final String schedule;
  final String source;
  final String? userId;
  final String? sessionId;
  final String? timezone;
  final bool enabled;
  final String status;
  final CronTaskConcurrencyDto concurrency;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final AgentCronSpecDto spec;

  const CronTaskDto({
    required this.cronId,
    required this.name,
    required this.schedule,
    required this.source,
    required this.enabled,
    required this.status,
    required this.concurrency,
    required this.createdAt,
    required this.updatedAt,
    required this.spec,
    this.userId,
    this.sessionId,
    this.timezone,
    this.lastRunAt,
    this.nextRunAt,
  });

  factory CronTaskDto.fromJson(Map<String, dynamic> json) =>
      _$CronTaskDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronTaskDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class CronTaskListItemDto {
  final String cronId;
  final String name;
  final String schedule;
  final bool enabled;
  final String status;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;

  const CronTaskListItemDto({
    required this.cronId,
    required this.name,
    required this.schedule,
    required this.enabled,
    required this.status,
    this.lastRunAt,
    this.nextRunAt,
  });

  factory CronTaskListItemDto.fromJson(Map<String, dynamic> json) =>
      _$CronTaskListItemDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronTaskListItemDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class CronRunDto {
  final String runId;
  final String cronId;
  final String trigger;
  final String status;
  final DateTime scheduledAt;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final LLMConfig? llmConfig;
  final String? liteAgentSessionId;
  final String? error;
  final Map<String, dynamic>? result;
  final bool hasDisplayableResult;
  final String? displayMessageId;
  final String? displayText;

  const CronRunDto({
    required this.runId,
    required this.cronId,
    required this.trigger,
    required this.status,
    required this.scheduledAt,
    required this.startedAt,
    required this.hasDisplayableResult,
    this.finishedAt,
    this.llmConfig,
    this.liteAgentSessionId,
    this.error,
    this.result,
    this.displayMessageId,
    this.displayText,
  });

  factory CronRunDto.fromJson(Map<String, dynamic> json) =>
      _$CronRunDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronRunDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class CronRunListItemDto {
  final String runId;
  final String cronId;
  final String trigger;
  final String status;
  final DateTime scheduledAt;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final LLMConfig? llmConfig;
  final bool hasDisplayableResult;
  final String? displayText;

  const CronRunListItemDto({
    required this.runId,
    required this.cronId,
    required this.trigger,
    required this.status,
    required this.scheduledAt,
    required this.startedAt,
    required this.hasDisplayableResult,
    this.finishedAt,
    this.llmConfig,
    this.displayText,
  });

  factory CronRunListItemDto.fromJson(Map<String, dynamic> json) =>
      _$CronRunListItemDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronRunListItemDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class CronRunMessageDto {
  final String messageId;
  final String runId;
  final String cronId;
  final DateTime timestamp;
  final AgentMessage message;

  const CronRunMessageDto({
    required this.messageId,
    required this.runId,
    required this.cronId,
    required this.timestamp,
    required this.message,
  });

  factory CronRunMessageDto.fromJson(Map<String, dynamic> json) =>
      _$CronRunMessageDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronRunMessageDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class CronSchedulerSnapshotDto {
  final bool running;
  final int activeTaskCount;
  final int runningTaskCount;
  final DateTime? lastTickAt;

  const CronSchedulerSnapshotDto({
    required this.running,
    required this.activeTaskCount,
    required this.runningTaskCount,
    this.lastTickAt,
  });

  factory CronSchedulerSnapshotDto.fromJson(Map<String, dynamic> json) =>
      _$CronSchedulerSnapshotDtoFromJson(json);

  Map<String, dynamic> toJson() => _$CronSchedulerSnapshotDtoToJson(this);
}
