import 'dart:async';

import 'package:lite_embeddings_sdk_dart/lite_embeddings_sdk_dart.dart'
    as embeddings;

import '../logging/logger.dart';
import 'drift_rag.dart';
import 'markdown_segmenter.dart';
import 'model.dart';

class Rag {
  final DriftRag store;
  final MarkdownSegmenter segmenter;
  final KernelLogger? logger;
  RagEmbeddingsBackend? _backend;
  String _docsNamePrefix;

  Rag({
    required this.store,
    this.segmenter = const MarkdownSegmenter(),
    this.logger,
    String docsNamePrefix = 'rag',
    RagEmbeddingsBackend? backend,
    embeddings.LiteEmbeddingsClient? client,
    embeddings.LLMConfig? llmConfig,
  }) : _docsNamePrefix = docsNamePrefix,
       _backend =
           backend ??
           (client == null || llmConfig == null
               ? null
               : LiteEmbeddingsRagBackend(
                   client: client,
                   llmConfig: llmConfig,
                 ));

  bool get ready => _backend != null;

  Future<void> configureEmbeddings({
    embeddings.LiteEmbeddingsClient? client,
    embeddings.LLMConfig? llmConfig,
    String? docsNamePrefix,
  }) async {
    _backend = client == null || llmConfig == null
        ? null
        : LiteEmbeddingsRagBackend(client: client, llmConfig: llmConfig);
    if (docsNamePrefix != null && docsNamePrefix.trim().isNotEmpty) {
      _docsNamePrefix = docsNamePrefix.trim();
    }
    if (!ready) {
      return;
    }
    final bases = await store.listBases(limit: 0);
    for (final base in bases) {
      final docsId = await _ensureBaseDocsId(base);
      if (docsId != base.docsId) {
        await store.upsertBase(
          base.copyWith(docsId: docsId, updatedAt: DateTime.now()),
        );
      }
    }
  }

  Future<RagBase> createBase({
    String? baseId,
    required String name,
    Map<String, dynamic>? metadata,
  }) async {
    final now = DateTime.now();
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError('name is required.');
    }
    final nextBaseId = _normalizeId(
      baseId,
      fallback:
          'rag_${stableHashHex('$normalizedName|${now.microsecondsSinceEpoch}')}',
    );
    final docsName = _buildDocsName(nextBaseId, normalizedName);
    var docsId = '';
    if (ready) {
      docsId = await _backend!.ensureDocsId(docsName);
    }
    final base = RagBase(
      id: nextBaseId,
      name: normalizedName,
      docsName: docsName,
      docsId: docsId,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );
    await store.upsertBase(base);
    return base;
  }

  Future<RagBase> getBase(String baseId) async {
    final base = await store.getBase(baseId);
    if (base == null) {
      throw StateError('RAG base not found: $baseId');
    }
    return base;
  }

  Future<List<RagBase>> listBases({int offset = 0, int limit = 50}) {
    return store.listBases(offset: offset, limit: limit);
  }

  Future<RagBase> updateBase({
    required String baseId,
    String? name,
    Map<String, dynamic>? metadata,
  }) async {
    final current = await getBase(baseId);
    final updated = current.copyWith(
      name: name?.trim().isNotEmpty == true ? name!.trim() : current.name,
      metadata: metadata ?? current.metadata,
      updatedAt: DateTime.now(),
    );
    await store.upsertBase(updated);
    return updated;
  }

  Future<void> deleteBase(String baseId) async {
    final base = await store.getBase(baseId);
    if (base == null) {
      return;
    }
    if (_backend != null && base.docsId.trim().isNotEmpty) {
      try {
        await _backend!.deleteDocs(base.docsId);
      } catch (error) {
        logger?.warn(
          'Failed to delete RAG docs from embeddings backend.',
          data: {'baseId': baseId, 'error': error.toString()},
        );
      }
    }
    await store.deleteBase(baseId);
  }

  Future<RagDocument> upsertMarkdownDocument({
    required String baseId,
    required String documentId,
    required String title,
    required String markdown,
    Map<String, dynamic>? metadata,
    bool sync = true,
  }) async {
    await getBase(baseId);
    final now = DateTime.now();
    final current = await store.getDocumentByBase(baseId, documentId);
    final document = RagDocument(
      id: _normalizeId(documentId),
      baseId: baseId,
      title: title.trim().isEmpty ? documentId : title.trim(),
      markdown: markdown,
      contentHash: stableHashHex(normalizeRagText(markdown)),
      metadata: metadata ?? current?.metadata,
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
      indexedAt: current?.indexedAt,
      syncStatus: RagDocumentSyncStatus.pending,
    );
    await store.upsertDocument(document);
    if (!sync || !ready) {
      return document;
    }
    await syncDocument(baseId: baseId, documentId: document.id);
    return (await store.getDocumentByBase(baseId, document.id)) ?? document;
  }

  Future<RagDocument> getDocument({
    required String baseId,
    required String documentId,
  }) async {
    final document = await store.getDocumentByBase(baseId, documentId);
    if (document == null || document.baseId != baseId) {
      throw StateError('RAG document not found: $documentId');
    }
    return document;
  }

  Future<List<RagDocument>> listDocuments({
    required String baseId,
    int offset = 0,
    int limit = 50,
  }) {
    return store.listDocuments(baseId: baseId, offset: offset, limit: limit);
  }

  Future<void> deleteDocument({
    required String baseId,
    required String documentId,
  }) async {
    final document = await getDocument(baseId: baseId, documentId: documentId);
    final segments = await store.listSegmentsByDocument(baseId, document.id);
    if (_backend != null) {
      final base = await getBase(baseId);
      final docsId = base.docsId.trim();
      for (final segment in segments) {
        if (segment.vdbSegmentId.trim().isEmpty || docsId.isEmpty) {
          continue;
        }
        try {
          await _backend!.deleteSegment(
            docsId: docsId,
            segmentId: segment.vdbSegmentId,
          );
        } catch (error) {
          logger?.warn(
            'Failed to delete RAG segment from embeddings backend.',
            data: {
              'baseId': baseId,
              'documentId': documentId,
              'segmentId': segment.vdbSegmentId,
              'error': error.toString(),
            },
          );
        }
      }
    }
    await store.deleteDocumentByBase(baseId, document.id);
  }

  Future<RagDocumentSyncResult> syncDocument({
    required String baseId,
    required String documentId,
  }) async {
    final document = await getDocument(baseId: baseId, documentId: documentId);
    if (!ready) {
      final now = DateTime.now();
      await store.upsertDocument(
        document.copyWith(
          updatedAt: now,
          syncStatus: RagDocumentSyncStatus.pending,
        ),
      );
      return RagDocumentSyncResult(
        baseId: baseId,
        documentId: documentId,
        syncStatus: RagDocumentSyncStatus.pending,
        keptCount: 0,
        updatedCount: 0,
        insertedCount: 0,
        deletedCount: 0,
        syncedAt: now,
      );
    }
    try {
      final base = await _ensureBaseDocs(getBase(baseId));
      final currentDocument = await getDocument(
        baseId: baseId,
        documentId: documentId,
      );
      final currentSegments = await store.listSegmentsByDocument(
        baseId,
        currentDocument.id,
      );
      final desiredSegments = segmenter.segment(
        documentId: currentDocument.id,
        title: currentDocument.title,
        markdown: currentDocument.markdown,
      );
      final plan = _buildSyncPlan(currentSegments, desiredSegments);
      final nextSegments = <RagSegment>[];
      final now = DateTime.now();
      final docsId = base.docsId;

      for (final item in plan.kept) {
        nextSegments.add(item);
      }
      for (final item in plan.updated) {
        await _backend!.updateSegment(
          docsId: docsId,
          segmentId: item.current.vdbSegmentId,
          text: item.next.text,
          metadata: _segmentMetadata(
            baseId: base.id,
            documentId: currentDocument.id,
            title: currentDocument.title,
            item: item.next,
            document: currentDocument,
          ),
        );
        nextSegments.add(
          RagSegment(
            id: item.current.id,
            baseId: base.id,
            documentId: currentDocument.id,
            segmentKey: item.next.segmentKey,
            segmentIndex: item.next.segmentIndex,
            headingPath: item.next.headingPath,
            text: item.next.text,
            textHash: item.next.textHash,
            contentFingerprint: item.next.contentFingerprint,
            tokenEstimate: item.next.tokenEstimate,
            charStart: item.next.charStart,
            charEnd: item.next.charEnd,
            vdbSegmentId: item.current.vdbSegmentId,
            createdAt: item.current.createdAt,
            updatedAt: now,
          ),
        );
      }
      for (final item in plan.inserted) {
        final segmentId = await _backend!.insertSegment(
          docsId: docsId,
          text: item.text,
          metadata: _segmentMetadata(
            baseId: base.id,
            documentId: currentDocument.id,
            title: currentDocument.title,
            item: item,
            document: currentDocument,
          ),
        );
        nextSegments.add(
          RagSegment(
            id: stableHashHex(
              '${base.id}|${currentDocument.id}|${item.segmentKey}',
            ),
            baseId: base.id,
            documentId: currentDocument.id,
            segmentKey: item.segmentKey,
            segmentIndex: item.segmentIndex,
            headingPath: item.headingPath,
            text: item.text,
            textHash: item.textHash,
            contentFingerprint: item.contentFingerprint,
            tokenEstimate: item.tokenEstimate,
            charStart: item.charStart,
            charEnd: item.charEnd,
            vdbSegmentId: segmentId,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      for (final item in plan.deleted) {
        try {
          await _backend!.deleteSegment(
            docsId: docsId,
            segmentId: item.vdbSegmentId,
          );
        } catch (error) {
          logger?.warn(
            'Failed to delete obsolete RAG segment.',
            data: {
              'baseId': base.id,
              'documentId': currentDocument.id,
              'segmentId': item.vdbSegmentId,
              'error': error.toString(),
            },
          );
        }
      }
      nextSegments.sort((a, b) => a.segmentIndex.compareTo(b.segmentIndex));
      await store.replaceDocumentSegments(
        baseId,
        currentDocument.id,
        nextSegments,
      );
      await store.upsertDocument(
        currentDocument.copyWith(
          indexedAt: now,
          updatedAt: now,
          syncStatus: RagDocumentSyncStatus.synced,
        ),
      );
      return RagDocumentSyncResult(
        baseId: base.id,
        documentId: currentDocument.id,
        syncStatus: RagDocumentSyncStatus.synced,
        keptCount: plan.kept.length,
        updatedCount: plan.updated.length,
        insertedCount: plan.inserted.length,
        deletedCount: plan.deleted.length,
        syncedAt: now,
      );
    } catch (error) {
      final now = DateTime.now();
      await store.upsertDocument(
        document.copyWith(
          updatedAt: now,
          syncStatus: RagDocumentSyncStatus.failed,
        ),
      );
      rethrow;
    }
  }

  Future<RagBatchResult> syncAllDocuments() {
    return syncDocuments();
  }

  Future<RagBatchResult> syncBase(String baseId) {
    return syncDocuments(baseId: baseId);
  }

  Future<RagBatchResult> retryFailedDocuments({String? baseId}) {
    return syncDocuments(baseId: baseId, onlyFailed: true);
  }

  Future<RagBatchResult> syncDocuments({
    String? baseId,
    bool onlyFailed = false,
  }) async {
    final documents = await store.listAllDocuments(
      baseId: baseId,
      syncStatus: onlyFailed ? RagDocumentSyncStatus.failed : null,
    );
    final items = <RagBatchItemResult>[];
    for (final document in documents) {
      try {
        final result = await syncDocument(
          baseId: document.baseId,
          documentId: document.id,
        );
        final itemStatus = result.syncStatus == RagDocumentSyncStatus.pending
            ? RagBatchItemStatus.skipped
            : RagBatchItemStatus.success;
        items.add(
          RagBatchItemResult(
            baseId: document.baseId,
            documentId: document.id,
            status: itemStatus,
            syncStatus: result.syncStatus,
            message: result.syncStatus == RagDocumentSyncStatus.pending
                ? 'Embeddings are not configured.'
                : null,
          ),
        );
      } catch (error) {
        items.add(
          RagBatchItemResult(
            baseId: document.baseId,
            documentId: document.id,
            status: RagBatchItemStatus.failed,
            syncStatus: RagDocumentSyncStatus.failed,
            message: error.toString(),
          ),
        );
        logger?.warn(
          'Failed to sync RAG document.',
          data: {
            'baseId': document.baseId,
            'documentId': document.id,
            'error': error.toString(),
          },
        );
      }
    }
    return RagBatchResult(
      totalCount: items.length,
      successCount: items
          .where((item) => item.status == RagBatchItemStatus.success)
          .length,
      failedCount: items
          .where((item) => item.status == RagBatchItemStatus.failed)
          .length,
      skippedCount: items
          .where((item) => item.status == RagBatchItemStatus.skipped)
          .length,
      items: items,
      processedAt: DateTime.now(),
    );
  }

  Future<RagQueryResult> query({
    required String baseId,
    required String query,
    int limit = 5,
    int candidateLimit = 20,
  }) async {
    _requireReady();
    final base = await getBase(baseId);
    final docsId = base.docsId.trim();
    if (docsId.isEmpty) {
      throw StateError('RAG base is not indexed yet.');
    }
    final result = await _backend!.queryDocs(
      docsId: docsId,
      queryText: query,
      limit: candidateLimit,
    );
    final hitsByDocument = <String, _DocumentHitBuilder>{};
    for (final segment in result.segments) {
      final metadata = segment.metadata;
      final documentId = metadata['documentId'] as String? ?? '';
      if (documentId.isEmpty) {
        continue;
      }
      final title = metadata['title'] as String? ?? documentId;
      final headingPath = metadata['headingPath'] as String? ?? '';
      final builder = hitsByDocument.putIfAbsent(
        documentId,
        () => _DocumentHitBuilder(documentId: documentId, title: title),
      );
      builder.add(
        RagSegmentHit(
          segmentId: segment.segmentId,
          score: -segment.distance,
          text: segment.text,
          headingPath: headingPath,
        ),
      );
    }
    final hits =
        hitsByDocument.values
            .map((builder) => builder.build())
            .toList(growable: false)
          ..sort((a, b) => b.score.compareTo(a.score));
    return RagQueryResult(
      baseId: base.id,
      query: query,
      hits: limit > 0 ? hits.take(limit).toList(growable: false) : hits,
    );
  }

  void _requireReady() {
    if (!ready) {
      throw StateError('RAG embeddings are not configured.');
    }
  }

  Future<List<RagDocument>> listDocumentsByStatus({
    String? baseId,
    RagDocumentSyncStatus? syncStatus,
    int offset = 0,
    int limit = 50,
  }) async {
    if (baseId != null && baseId.trim().isNotEmpty) {
      return store.listDocuments(
        baseId: baseId.trim(),
        syncStatus: syncStatus,
        offset: offset,
        limit: limit,
      );
    }
    final all = await store.listAllDocuments(syncStatus: syncStatus);
    if (offset >= all.length) {
      return const [];
    }
    final paged = all.skip(offset);
    if (limit <= 0) {
      return paged.toList(growable: false);
    }
    return paged.take(limit).toList(growable: false);
  }

  Future<List<RagSegment>> listSegments(String documentId) {
    throw UnsupportedError('Use listSegmentsByBase.');
  }

  Future<List<RagSegment>> listSegmentsByBase({
    required String baseId,
    required String documentId,
  }) {
    return store.listSegmentsByDocument(baseId, documentId);
  }

  Future<RagBase> _ensureBaseDocs(Future<RagBase> baseFuture) async {
    final base = await baseFuture;
    final docsId = await _ensureBaseDocsId(base);
    if (docsId == base.docsId) {
      return base;
    }
    final updated = base.copyWith(docsId: docsId, updatedAt: DateTime.now());
    await store.upsertBase(updated);
    return updated;
  }

  Future<String> _ensureBaseDocsId(RagBase base) async {
    final docsId = base.docsId.trim();
    if (docsId.isNotEmpty) {
      return docsId;
    }
    _requireReady();
    return _backend!.ensureDocsId(base.docsName);
  }

  String _normalizeId(String? value, {String? fallback}) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }
    throw ArgumentError('id is required.');
  }

  String _buildDocsName(String baseId, String name) {
    final raw =
        '${_docsNamePrefix}_${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';
    final normalized = raw
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return '${_docsNamePrefix}_$baseId';
  }

  Map<String, dynamic> _segmentMetadata({
    required String baseId,
    required String documentId,
    required String title,
    required MarkdownSegmentPlanItem item,
    required RagDocument document,
  }) {
    return {
      'baseId': baseId,
      'documentId': documentId,
      'title': title,
      'headingPath': item.headingPath,
      'segmentKey': item.segmentKey,
      'segmentIndex': item.segmentIndex,
      'tokenEstimate': item.tokenEstimate,
      'updatedAt': document.updatedAt.toUtc().toIso8601String(),
    };
  }
}

class _SyncPlan {
  final List<RagSegment> kept;
  final List<_SegmentUpdate> updated;
  final List<MarkdownSegmentPlanItem> inserted;
  final List<RagSegment> deleted;

  const _SyncPlan({
    required this.kept,
    required this.updated,
    required this.inserted,
    required this.deleted,
  });
}

class _SegmentUpdate {
  final RagSegment current;
  final MarkdownSegmentPlanItem next;

  const _SegmentUpdate({required this.current, required this.next});
}

_SyncPlan _buildSyncPlan(
  List<RagSegment> current,
  List<MarkdownSegmentPlanItem> desired,
) {
  final kept = <RagSegment>[];
  final updated = <_SegmentUpdate>[];
  final inserted = <MarkdownSegmentPlanItem>[];
  final remaining = [...current];
  final byKey = <String, RagSegment>{
    for (final item in current) item.segmentKey: item,
  };

  for (final next in desired) {
    final exact = byKey[next.segmentKey];
    if (exact != null) {
      remaining.remove(exact);
      if (exact.contentFingerprint == next.contentFingerprint) {
        kept.add(exact);
      } else {
        updated.add(_SegmentUpdate(current: exact, next: next));
      }
      continue;
    }
    RagSegment? matched;
    for (final candidate in remaining) {
      if (candidate.textHash == next.textHash) {
        matched = candidate;
        break;
      }
    }
    if (matched != null) {
      remaining.remove(matched);
      updated.add(_SegmentUpdate(current: matched, next: next));
      continue;
    }
    inserted.add(next);
  }

  return _SyncPlan(
    kept: kept,
    updated: updated,
    inserted: inserted,
    deleted: remaining,
  );
}

class _DocumentHitBuilder {
  final String documentId;
  final String title;
  final List<RagSegmentHit> _segments = [];

  _DocumentHitBuilder({required this.documentId, required this.title});

  void add(RagSegmentHit hit) {
    _segments.add(hit);
  }

  RagDocumentHit build() {
    _segments.sort((a, b) => b.score.compareTo(a.score));
    final snippet = _segments.isEmpty ? '' : _segments.first.text;
    final bestScore = _segments.isEmpty ? 0.0 : _segments.first.score;
    return RagDocumentHit(
      documentId: documentId,
      title: title,
      score: bestScore,
      snippet: snippet,
      segments: _segments,
    );
  }
}

abstract class RagEmbeddingsBackend {
  Future<String> ensureDocsId(String docsName);

  Future<void> deleteDocs(String docsId);

  Future<String> insertSegment({
    required String docsId,
    required String text,
    required Map<String, dynamic> metadata,
  });

  Future<void> updateSegment({
    required String docsId,
    required String segmentId,
    required String text,
    required Map<String, dynamic> metadata,
  });

  Future<void> deleteSegment({
    required String docsId,
    required String segmentId,
  });

  Future<RagEmbeddingsQueryResult> queryDocs({
    required String docsId,
    required String queryText,
    required int limit,
  });
}

class LiteEmbeddingsRagBackend implements RagEmbeddingsBackend {
  final embeddings.LiteEmbeddingsClient client;
  final embeddings.LLMConfig llmConfig;

  const LiteEmbeddingsRagBackend({
    required this.client,
    required this.llmConfig,
  });

  @override
  Future<void> deleteDocs(String docsId) async {
    await client.deleteDocs(embeddings.DocsId(docsId: docsId));
  }

  @override
  Future<void> deleteSegment({
    required String docsId,
    required String segmentId,
  }) async {
    await client.deleteSegment(
      embeddings.DeleteSegmentRequest(docsId: docsId, segmentId: segmentId),
    );
  }

  @override
  Future<String> ensureDocsId(String docsName) async {
    final docsList = await client.listDocs();
    for (final docs in docsList) {
      if (docs.docsName == docsName) {
        return docs.docsId;
      }
    }
    final created = await client.createDocs(
      embeddings.CreateDocsRequest(
        docsName: docsName,
        segmentList: [
          embeddings.Segment(
            text: 'bootstrap',
            metadata: const {'bootstrap': true},
          ),
        ],
        llmConfig: llmConfig,
      ),
    );
    return created.docsId;
  }

  @override
  Future<String> insertSegment({
    required String docsId,
    required String text,
    required Map<String, dynamic> metadata,
  }) async {
    final result = await client.insertSegment(
      embeddings.InsertSegmentRequest(
        docsId: docsId,
        segment: embeddings.Segment(text: text, metadata: metadata),
        llmConfig: llmConfig,
      ),
    );
    return result.segmentId;
  }

  @override
  Future<RagEmbeddingsQueryResult> queryDocs({
    required String docsId,
    required String queryText,
    required int limit,
  }) async {
    final result = await client.queryDocs(
      embeddings.QueryRequest(
        docsId: docsId,
        queryText: queryText,
        nResults: limit,
        llmConfig: llmConfig,
      ),
    );
    return RagEmbeddingsQueryResult(
      segments: result.segmentResultList
          .map(
            (item) => RagEmbeddingsQuerySegment(
              segmentId: item.segmentId,
              text: item.text,
              metadata: item.metadata ?? const <String, dynamic>{},
              distance: item.distance,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<void> updateSegment({
    required String docsId,
    required String segmentId,
    required String text,
    required Map<String, dynamic> metadata,
  }) async {
    await client.updateSegment(
      embeddings.UpdateSegmentRequest(
        docsId: docsId,
        segment: embeddings.SegmentInfo(
          segmentId: segmentId,
          text: text,
          metadata: metadata,
        ),
        llmConfig: llmConfig,
      ),
    );
  }
}

class RagEmbeddingsQueryResult {
  final List<RagEmbeddingsQuerySegment> segments;

  const RagEmbeddingsQueryResult({required this.segments});
}

class RagEmbeddingsQuerySegment {
  final String segmentId;
  final String text;
  final Map<String, dynamic> metadata;
  final double distance;

  const RagEmbeddingsQuerySegment({
    required this.segmentId,
    required this.text,
    required this.metadata,
    required this.distance,
  });
}
