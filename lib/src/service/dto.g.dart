// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

FunctionCallDto _$FunctionCallDtoFromJson(Map<String, dynamic> json) =>
    FunctionCallDto(
      name: json['name'] as String,
      arguments: json['arguments'] as Map<String, dynamic>,
    );

Map<String, dynamic> _$FunctionCallDtoToJson(FunctionCallDto instance) =>
    <String, dynamic>{'name': instance.name, 'arguments': instance.arguments};

AgentCronSpecDto _$AgentCronSpecDtoFromJson(Map<String, dynamic> json) =>
    AgentCronSpecDto(
      systemPrompt: json['systemPrompt'] as String,
      content: (json['content'] as List<dynamic>)
          .map((e) => Content.fromJson(e as Map<String, dynamic>))
          .toList(),
      timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 3600,
      llmConfig: json['llmConfig'] == null
          ? null
          : LLMConfig.fromJson(json['llmConfig'] as Map<String, dynamic>),
      skills: (json['skills'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$AgentCronSpecDtoToJson(AgentCronSpecDto instance) {
  final val = <String, dynamic>{
    'systemPrompt': instance.systemPrompt,
    'content': instance.content.map((e) => e.toJson()).toList(),
    'timeoutSeconds': instance.timeoutSeconds,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('llmConfig', instance.llmConfig?.toJson());
  writeNotNull('skills', instance.skills);
  return val;
}

CronTaskDto _$CronTaskDtoFromJson(Map<String, dynamic> json) => CronTaskDto(
  cronId: json['cronId'] as String,
  name: json['name'] as String,
  schedule: json['schedule'] as String,
  source: json['source'] as String,
  enabled: json['enabled'] as bool,
  status: json['status'] as String,
  concurrency: $enumDecode(
    _$CronTaskConcurrencyDtoEnumMap,
    json['concurrency'],
  ),
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  spec: AgentCronSpecDto.fromJson(json['spec'] as Map<String, dynamic>),
  userId: json['userId'] as String?,
  sessionId: json['sessionId'] as String?,
  timezone: json['timezone'] as String?,
  lastRunAt: json['lastRunAt'] == null
      ? null
      : DateTime.parse(json['lastRunAt'] as String),
  nextRunAt: json['nextRunAt'] == null
      ? null
      : DateTime.parse(json['nextRunAt'] as String),
);

Map<String, dynamic> _$CronTaskDtoToJson(CronTaskDto instance) {
  final val = <String, dynamic>{
    'cronId': instance.cronId,
    'name': instance.name,
    'schedule': instance.schedule,
    'source': instance.source,
    'enabled': instance.enabled,
    'status': instance.status,
    'concurrency': _$CronTaskConcurrencyDtoEnumMap[instance.concurrency]!,
    'createdAt': instance.createdAt.toIso8601String(),
    'updatedAt': instance.updatedAt.toIso8601String(),
    'spec': instance.spec.toJson(),
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('userId', instance.userId);
  writeNotNull('sessionId', instance.sessionId);
  writeNotNull('timezone', instance.timezone);
  writeNotNull('lastRunAt', instance.lastRunAt?.toIso8601String());
  writeNotNull('nextRunAt', instance.nextRunAt?.toIso8601String());
  return val;
}

const _$CronTaskConcurrencyDtoEnumMap = {
  CronTaskConcurrencyDto.allow: 'allow',
  CronTaskConcurrencyDto.skipIfRunning: 'skipIfRunning',
  CronTaskConcurrencyDto.replace: 'replace',
};

CronTaskListItemDto _$CronTaskListItemDtoFromJson(Map<String, dynamic> json) =>
    CronTaskListItemDto(
      cronId: json['cronId'] as String,
      name: json['name'] as String,
      schedule: json['schedule'] as String,
      enabled: json['enabled'] as bool,
      status: json['status'] as String,
      lastRunAt: json['lastRunAt'] == null
          ? null
          : DateTime.parse(json['lastRunAt'] as String),
      nextRunAt: json['nextRunAt'] == null
          ? null
          : DateTime.parse(json['nextRunAt'] as String),
    );

Map<String, dynamic> _$CronTaskListItemDtoToJson(CronTaskListItemDto instance) {
  final val = <String, dynamic>{
    'cronId': instance.cronId,
    'name': instance.name,
    'schedule': instance.schedule,
    'enabled': instance.enabled,
    'status': instance.status,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('lastRunAt', instance.lastRunAt?.toIso8601String());
  writeNotNull('nextRunAt', instance.nextRunAt?.toIso8601String());
  return val;
}

CronRunDto _$CronRunDtoFromJson(Map<String, dynamic> json) => CronRunDto(
  runId: json['runId'] as String,
  cronId: json['cronId'] as String,
  trigger: json['trigger'] as String,
  status: json['status'] as String,
  scheduledAt: DateTime.parse(json['scheduledAt'] as String),
  startedAt: DateTime.parse(json['startedAt'] as String),
  hasDisplayableResult: json['hasDisplayableResult'] as bool,
  finishedAt: json['finishedAt'] == null
      ? null
      : DateTime.parse(json['finishedAt'] as String),
  llmConfig: json['llmConfig'] == null
      ? null
      : LLMConfig.fromJson(json['llmConfig'] as Map<String, dynamic>),
  liteAgentSessionId: json['liteAgentSessionId'] as String?,
  error: json['error'] as String?,
  result: json['result'] as Map<String, dynamic>?,
  displayMessageId: json['displayMessageId'] as String?,
  displayText: json['displayText'] as String?,
);

Map<String, dynamic> _$CronRunDtoToJson(CronRunDto instance) {
  final val = <String, dynamic>{
    'runId': instance.runId,
    'cronId': instance.cronId,
    'trigger': instance.trigger,
    'status': instance.status,
    'scheduledAt': instance.scheduledAt.toIso8601String(),
    'startedAt': instance.startedAt.toIso8601String(),
    'hasDisplayableResult': instance.hasDisplayableResult,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('finishedAt', instance.finishedAt?.toIso8601String());
  writeNotNull('llmConfig', instance.llmConfig?.toJson());
  writeNotNull('liteAgentSessionId', instance.liteAgentSessionId);
  writeNotNull('error', instance.error);
  writeNotNull('result', instance.result);
  writeNotNull('displayMessageId', instance.displayMessageId);
  writeNotNull('displayText', instance.displayText);
  return val;
}

CronRunListItemDto _$CronRunListItemDtoFromJson(Map<String, dynamic> json) =>
    CronRunListItemDto(
      runId: json['runId'] as String,
      cronId: json['cronId'] as String,
      trigger: json['trigger'] as String,
      status: json['status'] as String,
      scheduledAt: DateTime.parse(json['scheduledAt'] as String),
      startedAt: DateTime.parse(json['startedAt'] as String),
      hasDisplayableResult: json['hasDisplayableResult'] as bool,
      finishedAt: json['finishedAt'] == null
          ? null
          : DateTime.parse(json['finishedAt'] as String),
      llmConfig: json['llmConfig'] == null
          ? null
          : LLMConfig.fromJson(json['llmConfig'] as Map<String, dynamic>),
      displayText: json['displayText'] as String?,
    );

Map<String, dynamic> _$CronRunListItemDtoToJson(CronRunListItemDto instance) {
  final val = <String, dynamic>{
    'runId': instance.runId,
    'cronId': instance.cronId,
    'trigger': instance.trigger,
    'status': instance.status,
    'scheduledAt': instance.scheduledAt.toIso8601String(),
    'startedAt': instance.startedAt.toIso8601String(),
    'hasDisplayableResult': instance.hasDisplayableResult,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('finishedAt', instance.finishedAt?.toIso8601String());
  writeNotNull('llmConfig', instance.llmConfig?.toJson());
  writeNotNull('displayText', instance.displayText);
  return val;
}

CronRunMessageDto _$CronRunMessageDtoFromJson(Map<String, dynamic> json) =>
    CronRunMessageDto(
      messageId: json['messageId'] as String,
      runId: json['runId'] as String,
      cronId: json['cronId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      message: AgentMessage.fromJson(json['message'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$CronRunMessageDtoToJson(CronRunMessageDto instance) {
  final val = <String, dynamic>{
    'messageId': instance.messageId,
    'runId': instance.runId,
    'cronId': instance.cronId,
    'timestamp': instance.timestamp.toIso8601String(),
    'message': instance.message.toJson(),
  };
  return val;
}

CronSchedulerSnapshotDto _$CronSchedulerSnapshotDtoFromJson(
  Map<String, dynamic> json,
) => CronSchedulerSnapshotDto(
  running: json['running'] as bool,
  activeTaskCount: (json['activeTaskCount'] as num).toInt(),
  runningTaskCount: (json['runningTaskCount'] as num).toInt(),
  lastTickAt: json['lastTickAt'] == null
      ? null
      : DateTime.parse(json['lastTickAt'] as String),
);

Map<String, dynamic> _$CronSchedulerSnapshotDtoToJson(
  CronSchedulerSnapshotDto instance,
) {
  final val = <String, dynamic>{
    'running': instance.running,
    'activeTaskCount': instance.activeTaskCount,
    'runningTaskCount': instance.runningTaskCount,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('lastTickAt', instance.lastTickAt?.toIso8601String());
  return val;
}
