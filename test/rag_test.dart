import 'dart:io';

import 'package:agentos_kernel/src/kernel/kernel.dart';
import 'package:agentos_kernel/src/kernel/memory/drift_memory.dart';
import 'package:agentos_kernel/src/kernel/memory/memory_pipeline.dart';
import 'package:agentos_kernel/src/kernel/opentool/opentool_daemon_registry.dart';
import 'package:agentos_kernel/src/kernel/preference/preference.dart';
import 'package:agentos_kernel/src/kernel/preference/preference_extractor.dart';
import 'package:agentos_kernel/src/kernel/rag/drift_rag.dart';
import 'package:agentos_kernel/src/kernel/rag/model.dart';
import 'package:agentos_kernel/src/kernel/rag/rag.dart';
import 'package:agentos_kernel/src/kernel/supervision/supervision.dart';
import 'package:agentos_kernel/src/service/dto.dart';
import 'package:agentos_kernel/src/service/kernel_service.dart';
import 'package:test/test.dart';

void main() {
  group('RAG', () {
    test('allows creating base and document without embeddings', () async {
      final harness = await _TestHarness.create();
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      final document = await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-1',
        title: 'Doc 1',
        markdown: '# Title\n\nhello world',
      );

      expect(base.docsId, isEmpty);
      expect(document.syncStatus, RagDocumentSyncStatus.pending.name);
      expect(
        await harness.service.admin.listRagDocuments(
          baseId: base.id,
          syncStatus: RagDocumentSyncStatus.pending,
        ),
        hasLength(1),
      );
    });

    test('syncs a document successfully and stores segments', () async {
      final harness = await _TestHarness.create(
        backend: _FakeRagEmbeddingsBackend(),
      );
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-1',
        title: 'Doc 1',
        markdown: '# Intro\n\nalpha beta gamma\n\n## More\n\ndelta epsilon',
        sync: false,
      );

      final result = await harness.service.syncRagDocument(
        baseId: base.id,
        documentId: 'doc-1',
      );
      final document = await harness.service.getRagDocument(
        baseId: base.id,
        documentId: 'doc-1',
      );
      final segments = await harness.service.admin.listRagSegments(
        baseId: base.id,
        documentId: 'doc-1',
      );

      expect(result.syncStatus, RagDocumentSyncStatus.synced.name);
      expect(document.syncStatus, RagDocumentSyncStatus.synced.name);
      expect(segments, isNotEmpty);
    });

    test('writes failed status when single-document sync fails', () async {
      final backend = _FakeRagEmbeddingsBackend()..failInsert = true;
      final harness = await _TestHarness.create(backend: backend);
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-1',
        title: 'Doc 1',
        markdown: '# Intro\n\nalpha beta gamma',
        sync: false,
      );

      await expectLater(
        () => harness.service.syncRagDocument(
          baseId: base.id,
          documentId: 'doc-1',
        ),
        throwsA(isA<StateError>()),
      );

      final document = await harness.service.getRagDocument(
        baseId: base.id,
        documentId: 'doc-1',
      );
      expect(document.syncStatus, RagDocumentSyncStatus.failed.name);
    });

    test('syncRagBase and retryFailedRagDocuments process batches', () async {
      final backend = _FakeRagEmbeddingsBackend();
      final harness = await _TestHarness.create(backend: backend);
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-1',
        title: 'Doc 1',
        markdown: '# Intro\n\nalpha beta gamma',
        sync: false,
      );
      await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-2',
        title: 'Doc 2',
        markdown: '# Intro\n\nzeta eta theta',
        sync: false,
      );

      backend.failDocumentIds.add('doc-2');
      final first = await harness.service.syncRagBase(base.id);
      expect(first.successCount, 1);
      expect(first.failedCount, 1);

      backend.failDocumentIds.clear();
      final retry = await harness.service.retryFailedRagDocuments(
        baseId: base.id,
      );
      expect(retry.successCount, 1);
      expect(retry.failedCount, 0);

      final failed = await harness.service.admin.listFailedRagDocuments(
        baseId: base.id,
      );
      expect(failed, isEmpty);
    });

    test('queryRag recalls segments and aggregates by document', () async {
      final backend = _FakeRagEmbeddingsBackend();
      final harness = await _TestHarness.create(backend: backend);
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      await harness.service.upsertRagMarkdownDocuments(
        baseId: base.id,
        documents: const [
          RagMarkdownDocumentInputDto(
            documentId: 'doc-1',
            title: 'Kernel Intro',
            markdown:
                '# Intro\n\nRAG documents are ingested from markdown text.',
          ),
          RagMarkdownDocumentInputDto(
            documentId: 'doc-2',
            title: 'Other Doc',
            markdown: '# Intro\n\nCron tasks are stored in sqlite.',
          ),
        ],
        sync: false,
      );
      await harness.service.syncRagBase(base.id);

      final result = await harness.service.queryRag(
        baseId: base.id,
        query: 'markdown ingested',
      );

      expect(result.hits, isNotEmpty);
      expect(result.hits.first.documentId, 'doc-1');
      expect(result.hits.first.segments, isNotEmpty);
    });

    test('deleting a document clears local segment state', () async {
      final backend = _FakeRagEmbeddingsBackend();
      final harness = await _TestHarness.create(backend: backend);
      addTearDown(harness.dispose);

      final base = await harness.service.createRagBase(name: 'docs');
      await harness.service.upsertRagMarkdownDocument(
        baseId: base.id,
        documentId: 'doc-1',
        title: 'Doc 1',
        markdown: '# Intro\n\nalpha beta gamma',
      );

      expect(
        await harness.service.admin.listRagSegments(
          baseId: base.id,
          documentId: 'doc-1',
        ),
        isNotEmpty,
      );

      await harness.service.deleteRagDocument(
        baseId: base.id,
        documentId: 'doc-1',
      );

      expect(
        await harness.service.admin.listRagSegments(
          baseId: base.id,
          documentId: 'doc-1',
        ),
        isEmpty,
      );
      expect(
        () => harness.service.getRagDocument(
          baseId: base.id,
          documentId: 'doc-1',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('same documentId in different bases does not collide', () async {
      final backend = _FakeRagEmbeddingsBackend();
      final harness = await _TestHarness.create(backend: backend);
      addTearDown(harness.dispose);

      final baseA = await harness.service.createRagBase(name: 'docs-a');
      final baseB = await harness.service.createRagBase(name: 'docs-b');

      await harness.service.upsertRagMarkdownDocument(
        baseId: baseA.id,
        documentId: 'doc-1',
        title: 'Doc A',
        markdown: '# A\n\nalpha',
      );
      await harness.service.upsertRagMarkdownDocument(
        baseId: baseB.id,
        documentId: 'doc-1',
        title: 'Doc B',
        markdown: '# B\n\nbeta',
      );

      final docA = await harness.service.getRagDocument(
        baseId: baseA.id,
        documentId: 'doc-1',
      );
      final docB = await harness.service.getRagDocument(
        baseId: baseB.id,
        documentId: 'doc-1',
      );

      expect(docA.title, 'Doc A');
      expect(docB.title, 'Doc B');
      expect(
        await harness.service.listRagDocuments(baseId: baseA.id),
        hasLength(1),
      );
      expect(
        await harness.service.listRagDocuments(baseId: baseB.id),
        hasLength(1),
      );
    });
  });
}

class _TestHarness {
  final Directory tempDir;
  final KernelService service;

  const _TestHarness({required this.tempDir, required this.service});

  static Future<_TestHarness> create({RagEmbeddingsBackend? backend}) async {
    final tempDir = await Directory.systemTemp.createTemp('rag-test-');
    final memory = DriftMemory.open(path: '${tempDir.path}/memory.sqlite');
    final ragStore = DriftRag.open(path: '${tempDir.path}/rag.sqlite');
    final rag = Rag(store: ragStore, backend: backend);
    final kernel = Kernel(
      openToolDaemonRegistry: OpenToolDaemonRegistry(),
      supervision: PassiveSupervision(),
      memory: memory,
      memoryPipeline: MemoryPipeline(memory: memory),
      preference: InMemoryPreference(),
      preferenceExtractor: OfflinePreferenceExtractor(),
      rag: rag,
    );
    final service = KernelService(kernel, driftMemory: memory);
    return _TestHarness(tempDir: tempDir, service: service);
  }

  Future<void> dispose() async {
    await tempDir.delete(recursive: true);
  }
}

class _FakeRagEmbeddingsBackend implements RagEmbeddingsBackend {
  final Map<String, String> _docsIdByName = {};
  final Map<String, Map<String, _StoredSegment>> _segmentsByDocsId = {};
  final Set<String> failDocumentIds = {};
  bool failInsert = false;

  @override
  Future<void> deleteDocs(String docsId) async {
    _segmentsByDocsId.remove(docsId);
    _docsIdByName.removeWhere((_, value) => value == docsId);
  }

  @override
  Future<void> deleteSegment({
    required String docsId,
    required String segmentId,
  }) async {
    _segmentsByDocsId[docsId]?.remove(segmentId);
  }

  @override
  Future<String> ensureDocsId(String docsName) async {
    return _docsIdByName.putIfAbsent(
      docsName,
      () => 'docs-${_docsIdByName.length + 1}',
    );
  }

  @override
  Future<String> insertSegment({
    required String docsId,
    required String text,
    required Map<String, dynamic> metadata,
  }) async {
    final documentId = metadata['documentId'] as String? ?? '';
    if (failInsert || failDocumentIds.contains(documentId)) {
      throw StateError('insert failed for $documentId');
    }
    final segments = _segmentsByDocsId.putIfAbsent(
      docsId,
      () => <String, _StoredSegment>{},
    );
    final segmentId = 'segment-${segments.length + 1}';
    segments[segmentId] = _StoredSegment(text: text, metadata: metadata);
    return segmentId;
  }

  @override
  Future<RagEmbeddingsQueryResult> queryDocs({
    required String docsId,
    required String queryText,
    required int limit,
  }) async {
    final queryTerms = queryText
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final segments = <RagEmbeddingsQuerySegment>[];
    for (final entry in (_segmentsByDocsId[docsId] ?? const {}).entries) {
      final text = entry.value.text.toLowerCase();
      var matchCount = 0;
      for (final term in queryTerms) {
        if (text.contains(term)) {
          matchCount++;
        }
      }
      if (matchCount <= 0) {
        continue;
      }
      segments.add(
        RagEmbeddingsQuerySegment(
          segmentId: entry.key,
          text: entry.value.text,
          metadata: entry.value.metadata,
          distance: 1 / matchCount,
        ),
      );
    }
    segments.sort((a, b) => a.distance.compareTo(b.distance));
    return RagEmbeddingsQueryResult(
      segments: limit > 0
          ? segments.take(limit).toList(growable: false)
          : segments,
    );
  }

  @override
  Future<void> updateSegment({
    required String docsId,
    required String segmentId,
    required String text,
    required Map<String, dynamic> metadata,
  }) async {
    final documentId = metadata['documentId'] as String? ?? '';
    if (failDocumentIds.contains(documentId)) {
      throw StateError('update failed for $documentId');
    }
    final segments = _segmentsByDocsId.putIfAbsent(
      docsId,
      () => <String, _StoredSegment>{},
    );
    if (!segments.containsKey(segmentId)) {
      throw StateError('missing segment $segmentId');
    }
    segments[segmentId] = _StoredSegment(text: text, metadata: metadata);
  }
}

class _StoredSegment {
  final String text;
  final Map<String, dynamic> metadata;

  const _StoredSegment({required this.text, required this.metadata});
}
