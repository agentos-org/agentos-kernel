const String agentMemoryItemType = 'agent';

enum AgentMemoryActorType { user, app, system }

class MemoryItem {
  final String id;
  final String type;
  final String sourceId;
  final String content;
  final DateTime timestamp;

  const MemoryItem({
    required this.id,
    required this.type,
    required this.sourceId,
    required this.content,
    required this.timestamp,
  });
}

enum MemorySummaryBucket {
  recent,
  day,
  week,
  month,
  quarter,
  archive;

  Duration? get window {
    switch (this) {
      case MemorySummaryBucket.recent:
        return const Duration(hours: 6);
      case MemorySummaryBucket.day:
        return const Duration(hours: 24);
      case MemorySummaryBucket.week:
        return const Duration(days: 7);
      case MemorySummaryBucket.month:
        return const Duration(days: 30);
      case MemorySummaryBucket.quarter:
        return const Duration(days: 90);
      case MemorySummaryBucket.archive:
        return null;
    }
  }
}

class MemorySummary {
  final String id;
  final String text;
  final List<String> sourceIds;
  final DateTime sourceStartAt;
  final DateTime sourceEndAt;
  final DateTime updatedAt;
  final MemorySummaryBucket bucket;

  const MemorySummary({
    required this.id,
    required this.text,
    required this.sourceIds,
    required this.sourceStartAt,
    required this.sourceEndAt,
    required this.updatedAt,
    required this.bucket,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'sourceIds': sourceIds,
    'sourceStartAt': sourceStartAt.toIso8601String(),
    'sourceEndAt': sourceEndAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'bucket': bucket.name,
  };

  factory MemorySummary.fromJson(Map<String, dynamic> json) {
    final bucketName =
        json['bucket'] as String? ?? MemorySummaryBucket.recent.name;
    return MemorySummary(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      sourceIds: _stringListFromDynamic(json['sourceIds']),
      sourceStartAt:
          DateTime.tryParse(json['sourceStartAt'] as String? ?? '') ??
          DateTime.now(),
      sourceEndAt:
          DateTime.tryParse(json['sourceEndAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      bucket: MemorySummaryBucket.values.firstWhere(
        (value) => value.name == bucketName,
        orElse: () => MemorySummaryBucket.recent,
      ),
    );
  }
}

class MemorySummarizationTriggerResult {
  static const String reasonEmpty = 'empty';
  static const String reasonInsufficientRecords = 'insufficient_records';
  static const String reasonNoNewSummary = 'no_new_summary';
  static const String reasonGenerated = 'generated';

  final List<MemorySummary> summaries;
  final int memoryItemCount;
  final int minRequired;
  final String reason;
  final Map<String, int> bucketCounts;

  const MemorySummarizationTriggerResult({
    required this.summaries,
    required this.memoryItemCount,
    required this.minRequired,
    required this.reason,
    this.bucketCounts = const {},
  });
}

class MemorySummaryIndexEntry {
  final String summaryId;
  final String segmentId;
  final String contentFingerprint;
  final DateTime indexedAt;

  const MemorySummaryIndexEntry({
    required this.summaryId,
    required this.segmentId,
    required this.contentFingerprint,
    required this.indexedAt,
  });

  Map<String, dynamic> toJson() => {
    'summaryId': summaryId,
    'segmentId': segmentId,
    'contentFingerprint': contentFingerprint,
    'indexedAt': indexedAt.toIso8601String(),
  };

  factory MemorySummaryIndexEntry.fromJson(Map<String, dynamic> json) {
    return MemorySummaryIndexEntry(
      summaryId: json['summaryId'] as String? ?? '',
      segmentId: json['segmentId'] as String? ?? '',
      contentFingerprint: json['contentFingerprint'] as String? ?? '',
      indexedAt:
          DateTime.tryParse(json['indexedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

List<String> _stringListFromDynamic(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
