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
    <String, dynamic>{
      'name': instance.name,
      'arguments': instance.arguments,
    };

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
      skills:
          (json['skills'] as List<dynamic>?)?.map((e) => e as String).toList(),
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
      concurrency:
          $enumDecode(_$CronTaskConcurrencyDtoEnumMap, json['concurrency']),
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
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('userId', instance.userId);
  writeNotNull('sessionId', instance.sessionId);
  writeNotNull('timezone', instance.timezone);
  val['enabled'] = instance.enabled;
  val['status'] = instance.status;
  val['concurrency'] = _$CronTaskConcurrencyDtoEnumMap[instance.concurrency]!;
  val['createdAt'] = instance.createdAt.toIso8601String();
  val['updatedAt'] = instance.updatedAt.toIso8601String();
  writeNotNull('lastRunAt', instance.lastRunAt?.toIso8601String());
  writeNotNull('nextRunAt', instance.nextRunAt?.toIso8601String());
  val['spec'] = instance.spec.toJson();
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
  val['hasDisplayableResult'] = instance.hasDisplayableResult;
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
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('finishedAt', instance.finishedAt?.toIso8601String());
  writeNotNull('llmConfig', instance.llmConfig?.toJson());
  val['hasDisplayableResult'] = instance.hasDisplayableResult;
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

Map<String, dynamic> _$CronRunMessageDtoToJson(CronRunMessageDto instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'runId': instance.runId,
      'cronId': instance.cronId,
      'timestamp': instance.timestamp.toIso8601String(),
      'message': instance.message.toJson(),
    };

CronSchedulerSnapshotDto _$CronSchedulerSnapshotDtoFromJson(
        Map<String, dynamic> json) =>
    CronSchedulerSnapshotDto(
      running: json['running'] as bool,
      activeTaskCount: (json['activeTaskCount'] as num).toInt(),
      runningTaskCount: (json['runningTaskCount'] as num).toInt(),
      lastTickAt: json['lastTickAt'] == null
          ? null
          : DateTime.parse(json['lastTickAt'] as String),
    );

Map<String, dynamic> _$CronSchedulerSnapshotDtoToJson(
    CronSchedulerSnapshotDto instance) {
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

RagBaseDto _$RagBaseDtoFromJson(Map<String, dynamic> json) => RagBaseDto(
      id: json['id'] as String,
      name: json['name'] as String,
      docsName: json['docsName'] as String,
      docsId: json['docsId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$RagBaseDtoToJson(RagBaseDto instance) {
  final val = <String, dynamic>{
    'id': instance.id,
    'name': instance.name,
    'docsName': instance.docsName,
    'docsId': instance.docsId,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('metadata', instance.metadata);
  val['createdAt'] = instance.createdAt.toIso8601String();
  val['updatedAt'] = instance.updatedAt.toIso8601String();
  return val;
}

RagBaseListItemDto _$RagBaseListItemDtoFromJson(Map<String, dynamic> json) =>
    RagBaseListItemDto(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );

Map<String, dynamic> _$RagBaseListItemDtoToJson(RagBaseListItemDto instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
    };

RagDocumentDto _$RagDocumentDtoFromJson(Map<String, dynamic> json) =>
    RagDocumentDto(
      id: json['id'] as String,
      baseId: json['baseId'] as String,
      title: json['title'] as String,
      markdown: json['markdown'] as String,
      contentHash: json['contentHash'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      syncStatus: json['syncStatus'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
      indexedAt: json['indexedAt'] == null
          ? null
          : DateTime.parse(json['indexedAt'] as String),
    );

Map<String, dynamic> _$RagDocumentDtoToJson(RagDocumentDto instance) {
  final val = <String, dynamic>{
    'id': instance.id,
    'baseId': instance.baseId,
    'title': instance.title,
    'markdown': instance.markdown,
    'contentHash': instance.contentHash,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('metadata', instance.metadata);
  val['createdAt'] = instance.createdAt.toIso8601String();
  val['updatedAt'] = instance.updatedAt.toIso8601String();
  writeNotNull('indexedAt', instance.indexedAt?.toIso8601String());
  val['syncStatus'] = instance.syncStatus;
  return val;
}

RagDocumentListItemDto _$RagDocumentListItemDtoFromJson(
        Map<String, dynamic> json) =>
    RagDocumentListItemDto(
      id: json['id'] as String,
      baseId: json['baseId'] as String,
      title: json['title'] as String,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      syncStatus: json['syncStatus'] as String,
      indexedAt: json['indexedAt'] == null
          ? null
          : DateTime.parse(json['indexedAt'] as String),
    );

Map<String, dynamic> _$RagDocumentListItemDtoToJson(
    RagDocumentListItemDto instance) {
  final val = <String, dynamic>{
    'id': instance.id,
    'baseId': instance.baseId,
    'title': instance.title,
    'updatedAt': instance.updatedAt.toIso8601String(),
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('indexedAt', instance.indexedAt?.toIso8601String());
  val['syncStatus'] = instance.syncStatus;
  return val;
}

RagDocumentSyncResultDto _$RagDocumentSyncResultDtoFromJson(
        Map<String, dynamic> json) =>
    RagDocumentSyncResultDto(
      baseId: json['baseId'] as String,
      documentId: json['documentId'] as String,
      syncStatus: json['syncStatus'] as String,
      keptCount: (json['keptCount'] as num).toInt(),
      updatedCount: (json['updatedCount'] as num).toInt(),
      insertedCount: (json['insertedCount'] as num).toInt(),
      deletedCount: (json['deletedCount'] as num).toInt(),
      syncedAt: DateTime.parse(json['syncedAt'] as String),
    );

Map<String, dynamic> _$RagDocumentSyncResultDtoToJson(
        RagDocumentSyncResultDto instance) =>
    <String, dynamic>{
      'baseId': instance.baseId,
      'documentId': instance.documentId,
      'syncStatus': instance.syncStatus,
      'keptCount': instance.keptCount,
      'updatedCount': instance.updatedCount,
      'insertedCount': instance.insertedCount,
      'deletedCount': instance.deletedCount,
      'syncedAt': instance.syncedAt.toIso8601String(),
    };

RagMarkdownDocumentInputDto _$RagMarkdownDocumentInputDtoFromJson(
        Map<String, dynamic> json) =>
    RagMarkdownDocumentInputDto(
      documentId: json['documentId'] as String,
      title: json['title'] as String,
      markdown: json['markdown'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$RagMarkdownDocumentInputDtoToJson(
    RagMarkdownDocumentInputDto instance) {
  final val = <String, dynamic>{
    'documentId': instance.documentId,
    'title': instance.title,
    'markdown': instance.markdown,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('metadata', instance.metadata);
  return val;
}

RagBatchItemResultDto _$RagBatchItemResultDtoFromJson(
        Map<String, dynamic> json) =>
    RagBatchItemResultDto(
      baseId: json['baseId'] as String,
      documentId: json['documentId'] as String,
      status: json['status'] as String,
      syncStatus: json['syncStatus'] as String,
      message: json['message'] as String?,
    );

Map<String, dynamic> _$RagBatchItemResultDtoToJson(
    RagBatchItemResultDto instance) {
  final val = <String, dynamic>{
    'baseId': instance.baseId,
    'documentId': instance.documentId,
    'status': instance.status,
    'syncStatus': instance.syncStatus,
  };

  void writeNotNull(String key, dynamic value) {
    if (value != null) {
      val[key] = value;
    }
  }

  writeNotNull('message', instance.message);
  return val;
}

RagBatchResultDto _$RagBatchResultDtoFromJson(Map<String, dynamic> json) =>
    RagBatchResultDto(
      totalCount: (json['totalCount'] as num).toInt(),
      successCount: (json['successCount'] as num).toInt(),
      failedCount: (json['failedCount'] as num).toInt(),
      skippedCount: (json['skippedCount'] as num).toInt(),
      processedAt: DateTime.parse(json['processedAt'] as String),
      items: (json['items'] as List<dynamic>)
          .map((e) => RagBatchItemResultDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$RagBatchResultDtoToJson(RagBatchResultDto instance) =>
    <String, dynamic>{
      'totalCount': instance.totalCount,
      'successCount': instance.successCount,
      'failedCount': instance.failedCount,
      'skippedCount': instance.skippedCount,
      'processedAt': instance.processedAt.toIso8601String(),
      'items': instance.items.map((e) => e.toJson()).toList(),
    };

RagSegmentDto _$RagSegmentDtoFromJson(Map<String, dynamic> json) =>
    RagSegmentDto(
      id: json['id'] as String,
      baseId: json['baseId'] as String,
      documentId: json['documentId'] as String,
      segmentIndex: (json['segmentIndex'] as num).toInt(),
      headingPath: json['headingPath'] as String,
      tokenEstimate: (json['tokenEstimate'] as num).toInt(),
      charStart: (json['charStart'] as num).toInt(),
      charEnd: (json['charEnd'] as num).toInt(),
      vdbSegmentId: json['vdbSegmentId'] as String,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );

Map<String, dynamic> _$RagSegmentDtoToJson(RagSegmentDto instance) =>
    <String, dynamic>{
      'id': instance.id,
      'baseId': instance.baseId,
      'documentId': instance.documentId,
      'segmentIndex': instance.segmentIndex,
      'headingPath': instance.headingPath,
      'tokenEstimate': instance.tokenEstimate,
      'charStart': instance.charStart,
      'charEnd': instance.charEnd,
      'vdbSegmentId': instance.vdbSegmentId,
      'updatedAt': instance.updatedAt.toIso8601String(),
    };

RagSegmentHitDto _$RagSegmentHitDtoFromJson(Map<String, dynamic> json) =>
    RagSegmentHitDto(
      segmentId: json['segmentId'] as String,
      score: (json['score'] as num).toDouble(),
      text: json['text'] as String,
      headingPath: json['headingPath'] as String,
    );

Map<String, dynamic> _$RagSegmentHitDtoToJson(RagSegmentHitDto instance) =>
    <String, dynamic>{
      'segmentId': instance.segmentId,
      'score': instance.score,
      'text': instance.text,
      'headingPath': instance.headingPath,
    };

RagDocumentHitDto _$RagDocumentHitDtoFromJson(Map<String, dynamic> json) =>
    RagDocumentHitDto(
      documentId: json['documentId'] as String,
      title: json['title'] as String,
      score: (json['score'] as num).toDouble(),
      snippet: json['snippet'] as String,
      segments: (json['segments'] as List<dynamic>)
          .map((e) => RagSegmentHitDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$RagDocumentHitDtoToJson(RagDocumentHitDto instance) =>
    <String, dynamic>{
      'documentId': instance.documentId,
      'title': instance.title,
      'score': instance.score,
      'snippet': instance.snippet,
      'segments': instance.segments.map((e) => e.toJson()).toList(),
    };

RagQueryResultDto _$RagQueryResultDtoFromJson(Map<String, dynamic> json) =>
    RagQueryResultDto(
      baseId: json['baseId'] as String,
      query: json['query'] as String,
      hits: (json['hits'] as List<dynamic>)
          .map((e) => RagDocumentHitDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$RagQueryResultDtoToJson(RagQueryResultDto instance) =>
    <String, dynamic>{
      'baseId': instance.baseId,
      'query': instance.query,
      'hits': instance.hits.map((e) => e.toJson()).toList(),
    };
