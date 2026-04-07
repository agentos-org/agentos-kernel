import 'dart:convert';

class RagSegmentationConfig {
  final int targetTokens;
  final int maxTokens;
  final int minTokens;
  final int overlapTokens;

  const RagSegmentationConfig({
    this.targetTokens = 400,
    this.maxTokens = 600,
    this.minTokens = 120,
    this.overlapTokens = 40,
  });
}

enum RagDocumentSyncStatus { pending, synced, failed }

enum RagBatchItemStatus { success, failed, skipped }

class RagBase {
  final String id;
  final String name;
  final String docsName;
  final String docsId;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RagBase({
    required this.id,
    required this.name,
    required this.docsName,
    required this.docsId,
    required this.createdAt,
    required this.updatedAt,
    this.metadata,
  });

  RagBase copyWith({
    String? name,
    String? docsName,
    String? docsId,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return RagBase(
      id: id,
      name: name ?? this.name,
      docsName: docsName ?? this.docsName,
      docsId: docsId ?? this.docsId,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class RagDocument {
  final String id;
  final String baseId;
  final String title;
  final String markdown;
  final String contentHash;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? indexedAt;
  final RagDocumentSyncStatus syncStatus;

  const RagDocument({
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

  RagDocument copyWith({
    String? title,
    String? markdown,
    String? contentHash,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? indexedAt,
    RagDocumentSyncStatus? syncStatus,
  }) {
    return RagDocument(
      id: id,
      baseId: baseId,
      title: title ?? this.title,
      markdown: markdown ?? this.markdown,
      contentHash: contentHash ?? this.contentHash,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      indexedAt: indexedAt ?? this.indexedAt,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

class RagSegment {
  final String id;
  final String baseId;
  final String documentId;
  final String segmentKey;
  final int segmentIndex;
  final String headingPath;
  final String text;
  final String textHash;
  final String contentFingerprint;
  final int tokenEstimate;
  final int charStart;
  final int charEnd;
  final String vdbSegmentId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RagSegment({
    required this.id,
    required this.baseId,
    required this.documentId,
    required this.segmentKey,
    required this.segmentIndex,
    required this.headingPath,
    required this.text,
    required this.textHash,
    required this.contentFingerprint,
    required this.tokenEstimate,
    required this.charStart,
    required this.charEnd,
    required this.vdbSegmentId,
    required this.createdAt,
    required this.updatedAt,
  });
}

class RagDocumentSyncResult {
  final String baseId;
  final String documentId;
  final RagDocumentSyncStatus syncStatus;
  final int keptCount;
  final int updatedCount;
  final int insertedCount;
  final int deletedCount;
  final DateTime syncedAt;

  const RagDocumentSyncResult({
    required this.baseId,
    required this.documentId,
    required this.syncStatus,
    required this.keptCount,
    required this.updatedCount,
    required this.insertedCount,
    required this.deletedCount,
    required this.syncedAt,
  });
}

class RagBatchItemResult {
  final String baseId;
  final String documentId;
  final RagBatchItemStatus status;
  final RagDocumentSyncStatus syncStatus;
  final String? message;

  const RagBatchItemResult({
    required this.baseId,
    required this.documentId,
    required this.status,
    required this.syncStatus,
    this.message,
  });
}

class RagBatchResult {
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final List<RagBatchItemResult> items;
  final DateTime processedAt;

  const RagBatchResult({
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.items,
    required this.processedAt,
  });
}

class RagQueryResult {
  final String baseId;
  final String query;
  final List<RagDocumentHit> hits;

  const RagQueryResult({
    required this.baseId,
    required this.query,
    required this.hits,
  });
}

class RagDocumentHit {
  final String documentId;
  final String title;
  final double score;
  final String snippet;
  final List<RagSegmentHit> segments;

  const RagDocumentHit({
    required this.documentId,
    required this.title,
    required this.score,
    required this.snippet,
    required this.segments,
  });
}

class RagSegmentHit {
  final String segmentId;
  final double score;
  final String text;
  final String headingPath;

  const RagSegmentHit({
    required this.segmentId,
    required this.score,
    required this.text,
    required this.headingPath,
  });
}

String stableHashHex(String input) {
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(input)) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

String normalizeRagText(String text) {
  return text.trim().replaceAll(RegExp(r'\s+'), ' ');
}
