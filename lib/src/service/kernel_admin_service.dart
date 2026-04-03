import '../kernel/memory/model.dart';
import '../kernel/preference/model.dart';
import '../kernel/kernel.dart';

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

  Future<PreferenceExtractionTriggerResult> triggerPreferenceExtraction() async {
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
}
