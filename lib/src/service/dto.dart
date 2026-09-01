import 'package:json_annotation/json_annotation.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

part 'dto.g.dart';

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
  final List<String>? skills;

  const AgentCronSpecDto({
    required this.systemPrompt,
    required this.content,
    this.timeoutSeconds = 3600,
    this.llmConfig,
    this.skills,
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

@JsonSerializable(explicitToJson: true, includeIfNull: false)
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

@JsonSerializable(explicitToJson: true, includeIfNull: false)
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

@JsonSerializable(includeIfNull: false)
class RagBaseDto {
  final String id;
  final String name;
  final String docsName;
  final String docsId;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RagBaseDto({
    required this.id,
    required this.name,
    required this.docsName,
    required this.docsId,
    required this.createdAt,
    required this.updatedAt,
    this.metadata,
  });

  factory RagBaseDto.fromJson(Map<String, dynamic> json) =>
      _$RagBaseDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagBaseDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagBaseListItemDto {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RagBaseListItemDto({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  factory RagBaseListItemDto.fromJson(Map<String, dynamic> json) =>
      _$RagBaseListItemDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagBaseListItemDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagDocumentDto {
  final String id;
  final String baseId;
  final String title;
  final String markdown;
  final String contentHash;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? indexedAt;
  final String syncStatus;

  const RagDocumentDto({
    required this.id,
    required this.baseId,
    required this.title,
    required this.markdown,
    required this.contentHash,
    required this.createdAt,
    required this.updatedAt,
    required this.syncStatus,
    this.metadata,
    this.indexedAt,
  });

  factory RagDocumentDto.fromJson(Map<String, dynamic> json) =>
      _$RagDocumentDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagDocumentDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagDocumentListItemDto {
  final String id;
  final String baseId;
  final String title;
  final DateTime updatedAt;
  final DateTime? indexedAt;
  final String syncStatus;

  const RagDocumentListItemDto({
    required this.id,
    required this.baseId,
    required this.title,
    required this.updatedAt,
    required this.syncStatus,
    this.indexedAt,
  });

  factory RagDocumentListItemDto.fromJson(Map<String, dynamic> json) =>
      _$RagDocumentListItemDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagDocumentListItemDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagDocumentSyncResultDto {
  final String baseId;
  final String documentId;
  final String syncStatus;
  final int keptCount;
  final int updatedCount;
  final int insertedCount;
  final int deletedCount;
  final DateTime syncedAt;

  const RagDocumentSyncResultDto({
    required this.baseId,
    required this.documentId,
    required this.syncStatus,
    required this.keptCount,
    required this.updatedCount,
    required this.insertedCount,
    required this.deletedCount,
    required this.syncedAt,
  });

  factory RagDocumentSyncResultDto.fromJson(Map<String, dynamic> json) =>
      _$RagDocumentSyncResultDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagDocumentSyncResultDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagMarkdownDocumentInputDto {
  final String documentId;
  final String title;
  final String markdown;
  final Map<String, dynamic>? metadata;

  const RagMarkdownDocumentInputDto({
    required this.documentId,
    required this.title,
    required this.markdown,
    this.metadata,
  });

  factory RagMarkdownDocumentInputDto.fromJson(Map<String, dynamic> json) =>
      _$RagMarkdownDocumentInputDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagMarkdownDocumentInputDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagBatchItemResultDto {
  final String baseId;
  final String documentId;
  final String status;
  final String syncStatus;
  final String? message;

  const RagBatchItemResultDto({
    required this.baseId,
    required this.documentId,
    required this.status,
    required this.syncStatus,
    this.message,
  });

  factory RagBatchItemResultDto.fromJson(Map<String, dynamic> json) =>
      _$RagBatchItemResultDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagBatchItemResultDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class RagBatchResultDto {
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final DateTime processedAt;
  final List<RagBatchItemResultDto> items;

  const RagBatchResultDto({
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.processedAt,
    required this.items,
  });

  factory RagBatchResultDto.fromJson(Map<String, dynamic> json) =>
      _$RagBatchResultDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagBatchResultDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagSegmentDto {
  final String id;
  final String baseId;
  final String documentId;
  final int segmentIndex;
  final String headingPath;
  final int tokenEstimate;
  final int charStart;
  final int charEnd;
  final String vdbSegmentId;
  final DateTime updatedAt;

  const RagSegmentDto({
    required this.id,
    required this.baseId,
    required this.documentId,
    required this.segmentIndex,
    required this.headingPath,
    required this.tokenEstimate,
    required this.charStart,
    required this.charEnd,
    required this.vdbSegmentId,
    required this.updatedAt,
  });

  factory RagSegmentDto.fromJson(Map<String, dynamic> json) =>
      _$RagSegmentDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagSegmentDtoToJson(this);
}

@JsonSerializable(includeIfNull: false)
class RagSegmentHitDto {
  final String segmentId;
  final double score;
  final String text;
  final String headingPath;

  const RagSegmentHitDto({
    required this.segmentId,
    required this.score,
    required this.text,
    required this.headingPath,
  });

  factory RagSegmentHitDto.fromJson(Map<String, dynamic> json) =>
      _$RagSegmentHitDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagSegmentHitDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class RagDocumentHitDto {
  final String documentId;
  final String title;
  final double score;
  final String snippet;
  final List<RagSegmentHitDto> segments;

  const RagDocumentHitDto({
    required this.documentId,
    required this.title,
    required this.score,
    required this.snippet,
    required this.segments,
  });

  factory RagDocumentHitDto.fromJson(Map<String, dynamic> json) =>
      _$RagDocumentHitDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagDocumentHitDtoToJson(this);
}

@JsonSerializable(explicitToJson: true, includeIfNull: false)
class RagQueryResultDto {
  final String baseId;
  final String query;
  final List<RagDocumentHitDto> hits;

  const RagQueryResultDto({
    required this.baseId,
    required this.query,
    required this.hits,
  });

  factory RagQueryResultDto.fromJson(Map<String, dynamic> json) =>
      _$RagQueryResultDtoFromJson(json);

  Map<String, dynamic> toJson() => _$RagQueryResultDtoToJson(this);
}
