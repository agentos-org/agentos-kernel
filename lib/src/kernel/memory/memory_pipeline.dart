import '../logging/logger.dart';
import 'drift_memory.dart';
import 'memory_summary_indexer.dart';
import 'memory_summarizer.dart';
import 'model.dart';

class MemoryPipeline {
  final DriftMemory memory;
  final KernelLogger? logger;
  final bool Function()? isIndexingAvailable;

  MemorySummarizer? summarizer;
  MemorySummaryIndexer? indexer;

  MemoryPipeline({
    required this.memory,
    this.logger,
    this.isIndexingAvailable,
    this.summarizer,
    this.indexer,
  });

  bool get summarizerAvailable => summarizer != null;

  void markDirty() {
    summarizer?.markDirty();
  }

  Future<MemorySummarizationTriggerResult> triggerSummarization() async {
    final now = DateTime.now();
    final items = await memory.listMemoryItems(
      type: agentMemoryItemType,
      limit: 0,
    );
    final activeSummarizer = summarizer;
    final minRequired = activeSummarizer?.minRecords ?? 0;
    final bucketCounts = _buildBucketCounts(items, now: now);
    if (items.isEmpty) {
      return MemorySummarizationTriggerResult(
        summaries: const [],
        memoryItemCount: 0,
        minRequired: minRequired,
        reason: MemorySummarizationTriggerResult.reasonEmpty,
        bucketCounts: bucketCounts,
      );
    }
    if (items.length < minRequired) {
      return MemorySummarizationTriggerResult(
        summaries: const [],
        memoryItemCount: items.length,
        minRequired: minRequired,
        reason: MemorySummarizationTriggerResult.reasonInsufficientRecords,
        bucketCounts: bucketCounts,
      );
    }
    if (activeSummarizer == null) {
      return MemorySummarizationTriggerResult(
        summaries: const [],
        memoryItemCount: items.length,
        minRequired: minRequired,
        reason: MemorySummarizationTriggerResult.reasonNoNewSummary,
        bucketCounts: bucketCounts,
      );
    }
    final summaries = await activeSummarizer.summarize();
    await syncIndexIfAvailable(summaries: summaries);
    return MemorySummarizationTriggerResult(
      summaries: summaries,
      memoryItemCount: items.length,
      minRequired: minRequired,
      reason: summaries.isEmpty
          ? MemorySummarizationTriggerResult.reasonNoNewSummary
          : MemorySummarizationTriggerResult.reasonGenerated,
      bucketCounts: bucketCounts,
    );
  }

  Future<void> syncIndexIfAvailable({List<MemorySummary>? summaries}) async {
    final activeIndexer = indexer;
    if (activeIndexer == null || !(isIndexingAvailable?.call() ?? true)) {
      return;
    }
    try {
      await activeIndexer.sync(summaries: summaries);
    } catch (error) {
      logger?.warn(
        'Failed to sync memory summary embeddings index.',
        data: {'error': error.toString()},
      );
    }
  }

  Map<String, int> _buildBucketCounts(
    List<MemoryItem> items, {
    required DateTime now,
  }) {
    final counts = <String, int>{};
    final archiveCutoff = now.subtract(const Duration(days: 90));
    for (final bucket in MemorySummaryBucket.values) {
      if (bucket == MemorySummaryBucket.archive) {
        counts[bucket.name] = items
            .where(
              (item) =>
                  item.timestamp.isBefore(archiveCutoff) ||
                  item.timestamp.isAtSameMomentAs(archiveCutoff),
            )
            .length;
        continue;
      }
      final window = bucket.window;
      if (window == null) {
        counts[bucket.name] = 0;
        continue;
      }
      final after = now.subtract(window);
      counts[bucket.name] = items
          .where(
            (item) =>
                item.timestamp.isAfter(after) ||
                item.timestamp.isAtSameMomentAs(after),
          )
          .length;
    }
    return counts;
  }
}
