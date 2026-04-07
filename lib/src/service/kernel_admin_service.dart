import '../kernel/memory/model.dart';
import '../kernel/preference/model.dart';
import '../kernel/rag/model.dart';
import '../kernel/kernel.dart';
import 'dto.dart';

class KernelAdminService {
  final Kernel _kernel;
  final Future<PreferenceExtractionTriggerResult> Function()?
  _triggerPreferenceExtraction;

  /// Admin/debug wrapper with access to internal snapshots.
  KernelAdminService(
    this._kernel, {
    Future<PreferenceExtractionTriggerResult> Function()?
    triggerPreferenceExtraction,
  }) : _triggerPreferenceExtraction = triggerPreferenceExtraction;

  Future<List<MemoryItem>> listMemoryItems({
    String? type,
    DateTime? after,
    DateTime? before,
    int offset = 0,
    int limit = 50,
    bool descending = false,
  }) async {
    final memory = _kernel.memory;
    return memory.listMemoryItems(
      type: type,
      after: after,
      before: before,
      offset: offset,
      limit: limit,
      descending: descending,
    );
  }

  Future<void> deleteMemoryItem(String id) async {
    return _kernel.memory.deleteMemoryItem(id);
  }

  Future<List<MemorySummary>> listMemorySummaries({
    MemorySummaryBucket? bucket,
    int offset = 0,
    int limit = 50,
  }) async {
    final memory = _kernel.memory;
    return memory.listMemorySummaries(
      bucket: bucket,
      offset: offset,
      limit: limit,
    );
  }

  Future<void> deleteMemorySummary(String id) async {
    return _kernel.memory.deleteMemorySummary(id);
  }

  Future<MemorySummarizationTriggerResult> triggerMemorySummarization() async {
    return _kernel.memoryPipeline.triggerSummarization();
  }

  Future<List<PreferenceEntry>> listPreferences({
    String userId = 'default',
    int offset = 0,
    int limit = 50,
  }) {
    return _kernel.preference.listPreferences(
      userId: userId,
      offset: offset,
      limit: limit,
    );
  }

  Future<PreferenceExtractionTriggerResult>
  triggerPreferenceExtraction() async {
    final trigger = _triggerPreferenceExtraction;
    if (trigger == null) {
      return const PreferenceExtractionTriggerResult(
        preferences: [],
        sourceRecordCount: 0,
        minRequired: 1,
        reason: PreferenceExtractionTriggerResult.reasonEmpty,
      );
    }
    return trigger();
  }

  Future<void> deletePreference(String id, {String userId = 'default'}) {
    return _kernel.preference.deletePreference(id, userId: userId);
  }

  Future<void> clearPreferences({String userId = 'default'}) {
    return _kernel.preference.clear(userId: userId);
  }

  Future<List<RagDocumentListItemDto>> listRagDocuments({
    String? baseId,
    RagDocumentSyncStatus? syncStatus,
    int offset = 0,
    int limit = 50,
  }) async {
    final documents = await _kernel.rag.listDocumentsByStatus(
      baseId: baseId,
      syncStatus: syncStatus,
      offset: offset,
      limit: limit,
    );
    return documents.map(_toRagDocumentListItemDto).toList(growable: false);
  }

  Future<List<RagDocumentListItemDto>> listFailedRagDocuments({
    String? baseId,
    int offset = 0,
    int limit = 50,
  }) {
    return listRagDocuments(
      baseId: baseId,
      syncStatus: RagDocumentSyncStatus.failed,
      offset: offset,
      limit: limit,
    );
  }

  Future<RagBatchResultDto> syncRagBase(String baseId) async {
    return _toRagBatchResultDto(await _kernel.rag.syncBase(baseId));
  }

  Future<RagBatchResultDto> retryFailedRagDocuments({String? baseId}) async {
    return _toRagBatchResultDto(
      await _kernel.rag.retryFailedDocuments(baseId: baseId),
    );
  }

  Future<List<RagSegmentDto>> listRagSegments({
    required String baseId,
    required String documentId,
  }) async {
    final segments = await _kernel.rag.listSegmentsByBase(
      baseId: baseId,
      documentId: documentId,
    );
    return segments.map(_toRagSegmentDto).toList(growable: false);
  }
}

RagDocumentListItemDto _toRagDocumentListItemDto(RagDocument document) {
  return RagDocumentListItemDto(
    id: document.id,
    baseId: document.baseId,
    title: document.title,
    updatedAt: document.updatedAt,
    indexedAt: document.indexedAt,
    syncStatus: document.syncStatus.name,
  );
}

RagBatchResultDto _toRagBatchResultDto(RagBatchResult result) {
  return RagBatchResultDto(
    totalCount: result.totalCount,
    successCount: result.successCount,
    failedCount: result.failedCount,
    skippedCount: result.skippedCount,
    processedAt: result.processedAt,
    items: result.items
        .map(
          (item) => RagBatchItemResultDto(
            baseId: item.baseId,
            documentId: item.documentId,
            status: item.status.name,
            syncStatus: item.syncStatus.name,
            message: item.message,
          ),
        )
        .toList(growable: false),
  );
}

RagSegmentDto _toRagSegmentDto(RagSegment segment) {
  return RagSegmentDto(
    id: segment.id,
    baseId: segment.baseId,
    documentId: segment.documentId,
    segmentIndex: segment.segmentIndex,
    headingPath: segment.headingPath,
    tokenEstimate: segment.tokenEstimate,
    charStart: segment.charStart,
    charEnd: segment.charEnd,
    vdbSegmentId: segment.vdbSegmentId,
    updatedAt: segment.updatedAt,
  );
}
