import 'dart:convert';

import 'package:lite_embeddings_sdk_dart/lite_embeddings_sdk_dart.dart'
    as embeddings;

import '../logging/logger.dart';
import 'drift_memory.dart';
import 'model.dart';

class MemorySummaryIndexer {
  final DriftMemory memory;
  final embeddings.LiteEmbeddingsClient client;
  final embeddings.LLMConfig llmConfig;
  final String docsId;
  final KernelLogger? logger;

  const MemorySummaryIndexer({
    required this.memory,
    required this.client,
    required this.llmConfig,
    required this.docsId,
    this.logger,
  });

  Future<List<MemorySummaryIndexEntry>> sync({
    List<MemorySummary>? summaries,
  }) async {
    final desiredSummaries =
        summaries ?? await memory.listMemorySummaries(limit: 0);
    final existingEntries = await memory.getMemorySummaryIndexEntries();
    final existingBySummaryId = {
      for (final entry in existingEntries) entry.summaryId: entry,
    };
    final desiredIds = desiredSummaries.map((summary) => summary.id).toSet();
    final nextEntries = <MemorySummaryIndexEntry>[];

    for (final entry in existingEntries) {
      if (desiredIds.contains(entry.summaryId)) {
        continue;
      }
      await _deleteSegment(entry.segmentId);
    }

    for (final summary in desiredSummaries) {
      final fingerprint = _fingerprint(summary);
      final existing = existingBySummaryId[summary.id];
      if (existing != null && existing.contentFingerprint == fingerprint) {
        nextEntries.add(existing);
        continue;
      }
      if (existing != null) {
        await _deleteSegment(existing.segmentId);
      }
      final segmentId = await _insertSegment(summary);
      nextEntries.add(
        MemorySummaryIndexEntry(
          summaryId: summary.id,
          segmentId: segmentId,
          contentFingerprint: fingerprint,
          indexedAt: DateTime.now(),
        ),
      );
    }

    await memory.saveMemorySummaryIndexEntries(nextEntries);
    return nextEntries;
  }

  Future<List<MemorySummaryQueryHit>> queryHits(
    String text, {
    int limit = 24,
  }) async {
    final result = await client.queryDocs(
      embeddings.QueryRequest(
        docsId: docsId,
        queryText: text,
        nResults: limit,
        llmConfig: llmConfig,
      ),
    );
    return result.segmentResultList
        .map(
          (item) => MemorySummaryQueryHit(
            segmentId: item.segmentId,
            summaryId: item.metadata?['id'] as String? ?? '',
            score: -item.distance,
            timeGroup: item.metadata?['timeGroup'] as String?,
          ),
        )
        .where((hit) => hit.summaryId.isNotEmpty)
        .toList(growable: false);
  }

  Future<String> _insertSegment(MemorySummary summary) async {
    final result = await client.insertSegment(
      embeddings.InsertSegmentRequest(
        docsId: docsId,
        segment: embeddings.Segment(
          text: summary.text,
          metadata: {
            'id': summary.id,
            'timeStart': summary.sourceStartAt.toUtc().toIso8601String(),
            'timeEnd': summary.sourceEndAt.toUtc().toIso8601String(),
            'updatedAt': summary.updatedAt.toUtc().toIso8601String(),
            'timeGroup': summary.bucket.name,
          },
        ),
        llmConfig: llmConfig,
      ),
    );
    return result.segmentId;
  }

  Future<void> _deleteSegment(String segmentId) async {
    try {
      await client.deleteSegment(
        embeddings.DeleteSegmentRequest(docsId: docsId, segmentId: segmentId),
      );
    } catch (error) {
      logger?.warn(
        'Failed to delete memory summary segment.',
        data: {'segmentId': segmentId, 'error': error.toString()},
      );
    }
  }

  String _fingerprint(MemorySummary summary) {
    return jsonEncode({
      'text': summary.text,
      'timeStart': summary.sourceStartAt.toUtc().toIso8601String(),
      'timeEnd': summary.sourceEndAt.toUtc().toIso8601String(),
      'updatedAt': summary.updatedAt.toUtc().toIso8601String(),
      'timeGroup': summary.bucket.name,
    });
  }
}

class MemorySummaryQueryHit {
  final String segmentId;
  final String summaryId;
  final double score;
  final String? timeGroup;

  const MemorySummaryQueryHit({
    required this.segmentId,
    required this.summaryId,
    required this.score,
    required this.timeGroup,
  });
}
