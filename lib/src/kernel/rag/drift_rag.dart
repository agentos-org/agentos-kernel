import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'model.dart';

class DriftRag {
  final QueryExecutor _executor;
  final _RagDbUser _user = _RagDbUser();
  Future<void>? _openFuture;

  DriftRag(this._executor);

  factory DriftRag.open({required String path}) {
    return DriftRag(_openConnection(path));
  }

  Future<void> _ensureOpen() {
    _openFuture ??= () async {
      await _executor.ensureOpen(_user);
      await _user.ensureInitialized(_executor);
    }();
    return _openFuture!;
  }

  Future<void> upsertBase(RagBase base) async {
    await _ensureOpen();
    await _executor.runCustom(
      '''
INSERT INTO rag_bases (
  id, name, docs_name, docs_id, metadata_json, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name,
  docs_name = excluded.docs_name,
  docs_id = excluded.docs_id,
  metadata_json = excluded.metadata_json,
  updated_at = excluded.updated_at;
''',
      [
        base.id,
        base.name,
        base.docsName,
        base.docsId,
        _encodeJson(base.metadata),
        base.createdAt.millisecondsSinceEpoch,
        base.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  Future<RagBase?> getBase(String id) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT id, name, docs_name, docs_id, metadata_json, created_at, updated_at
FROM rag_bases
WHERE id = ?
LIMIT 1;
''',
      [id.trim()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _baseFromRow(rows.first);
  }

  Future<List<RagBase>> listBases({int offset = 0, int limit = 50}) async {
    await _ensureOpen();
    final paginationClause = limit > 0
        ? offset > 0
              ? 'LIMIT $limit OFFSET $offset'
              : 'LIMIT $limit'
        : offset > 0
        ? 'LIMIT -1 OFFSET $offset'
        : '';
    final rows = await _executor.runSelect('''
SELECT id, name, docs_name, docs_id, metadata_json, created_at, updated_at
FROM rag_bases
ORDER BY updated_at DESC
$paginationClause;
''', const []);
    return rows.map(_baseFromRow).toList(growable: false);
  }

  Future<void> deleteBase(String id) async {
    await _ensureOpen();
    await _executor.runCustom('DELETE FROM rag_segments WHERE base_id = ?;', [
      id,
    ]);
    await _executor.runCustom('DELETE FROM rag_documents WHERE base_id = ?;', [
      id,
    ]);
    await _executor.runCustom('DELETE FROM rag_bases WHERE id = ?;', [id]);
  }

  Future<void> upsertDocument(RagDocument document) async {
    await _ensureOpen();
    final storageId = _documentStorageId(document.baseId, document.id);
    await _executor.runCustom(
      '''
INSERT INTO rag_documents (
  id, base_id, external_document_id, title, markdown, content_hash, metadata_json,
  created_at, updated_at, indexed_at, sync_status
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  base_id = excluded.base_id,
  external_document_id = excluded.external_document_id,
  title = excluded.title,
  markdown = excluded.markdown,
  content_hash = excluded.content_hash,
  metadata_json = excluded.metadata_json,
  updated_at = excluded.updated_at,
  indexed_at = excluded.indexed_at,
  sync_status = excluded.sync_status;
''',
      [
        storageId,
        document.baseId,
        document.id,
        document.title,
        document.markdown,
        document.contentHash,
        _encodeJson(document.metadata),
        document.createdAt.millisecondsSinceEpoch,
        document.updatedAt.millisecondsSinceEpoch,
        document.indexedAt?.millisecondsSinceEpoch,
        document.syncStatus.name,
      ],
    );
  }

  Future<RagDocument?> getDocument(String id) async {
    throw UnsupportedError('Use getDocumentByBase.');
  }

  Future<RagDocument?> getDocumentByBase(
    String baseId,
    String documentId,
  ) async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      '''
SELECT id, base_id, external_document_id, title, markdown, content_hash, metadata_json,
  created_at, updated_at, indexed_at, sync_status
FROM rag_documents
WHERE base_id = ? AND external_document_id = ?
LIMIT 1;
''',
      [baseId.trim(), documentId.trim()],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _documentFromRow(rows.first);
  }

  Future<List<RagDocument>> listDocuments({
    required String baseId,
    RagDocumentSyncStatus? syncStatus,
    int offset = 0,
    int limit = 50,
  }) async {
    await _ensureOpen();
    final where = <String>['base_id = ?'];
    final args = <Object?>[baseId];
    if (syncStatus != null) {
      where.add('sync_status = ?');
      args.add(syncStatus.name);
    }
    final paginationClause = limit > 0
        ? offset > 0
              ? 'LIMIT $limit OFFSET $offset'
              : 'LIMIT $limit'
        : offset > 0
        ? 'LIMIT -1 OFFSET $offset'
        : '';
    final rows = await _executor.runSelect('''
SELECT id, base_id, external_document_id, title, markdown, content_hash, metadata_json,
  created_at, updated_at, indexed_at, sync_status
FROM rag_documents
WHERE ${where.join(' AND ')}
ORDER BY updated_at DESC
$paginationClause;
''', args);
    return rows.map(_documentFromRow).toList(growable: false);
  }

  Future<void> deleteDocument(String id) async {
    throw UnsupportedError('Use deleteDocumentByBase.');
  }

  Future<void> deleteDocumentByBase(String baseId, String documentId) async {
    await _ensureOpen();
    final storageId = _documentStorageId(baseId, documentId);
    await _executor.runCustom(
      'DELETE FROM rag_segments WHERE document_id = ?;',
      [storageId],
    );
    await _executor.runCustom(
      'DELETE FROM rag_documents WHERE base_id = ? AND external_document_id = ?;',
      [baseId.trim(), documentId.trim()],
    );
  }

  Future<List<RagDocument>> listAllDocuments({
    String? baseId,
    RagDocumentSyncStatus? syncStatus,
  }) async {
    await _ensureOpen();
    final where = <String>[];
    final args = <Object?>[];
    if (baseId != null && baseId.trim().isNotEmpty) {
      where.add('base_id = ?');
      args.add(baseId.trim());
    }
    if (syncStatus != null) {
      where.add('sync_status = ?');
      args.add(syncStatus.name);
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await _executor.runSelect('''
SELECT id, base_id, external_document_id, title, markdown, content_hash, metadata_json,
  created_at, updated_at, indexed_at, sync_status
FROM rag_documents
$whereClause
ORDER BY updated_at DESC;
''', args);
    return rows.map(_documentFromRow).toList(growable: false);
  }

  Future<List<RagSegment>> listSegmentsByDocument(
    String baseId,
    String documentId,
  ) async {
    await _ensureOpen();
    final storageId = _documentStorageId(baseId, documentId);
    final rows = await _executor.runSelect(
      '''
SELECT s.id, s.base_id, s.document_id, d.external_document_id, s.segment_key,
  s.segment_index, s.heading_path, s.text, s.text_hash,
  s.content_fingerprint, s.token_estimate, s.char_start, s.char_end,
  s.vdb_segment_id, s.created_at, s.updated_at
FROM rag_segments s
JOIN rag_documents d ON d.id = s.document_id
WHERE s.document_id = ?
ORDER BY segment_index ASC;
''',
      [storageId],
    );
    return rows.map(_segmentFromRow).toList(growable: false);
  }

  Future<void> replaceDocumentSegments(
    String baseId,
    String documentId,
    List<RagSegment> segments,
  ) async {
    await _ensureOpen();
    final storageId = _documentStorageId(baseId, documentId);
    await _executor.runCustom(
      'DELETE FROM rag_segments WHERE document_id = ?;',
      [storageId],
    );
    for (final segment in segments) {
      await _executor.runCustom(
        '''
INSERT INTO rag_segments (
  id, base_id, document_id, segment_key, segment_index, heading_path,
  text, text_hash, content_fingerprint, token_estimate, char_start, char_end,
  vdb_segment_id, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''',
        [
          segment.id,
          segment.baseId,
          storageId,
          segment.segmentKey,
          segment.segmentIndex,
          segment.headingPath,
          segment.text,
          segment.textHash,
          segment.contentFingerprint,
          segment.tokenEstimate,
          segment.charStart,
          segment.charEnd,
          segment.vdbSegmentId,
          segment.createdAt.millisecondsSinceEpoch,
          segment.updatedAt.millisecondsSinceEpoch,
        ],
      );
    }
  }

  RagBase _baseFromRow(Map<String, Object?> row) {
    return RagBase(
      id: row['id'] as String? ?? '',
      name: row['name'] as String? ?? '',
      docsName: row['docs_name'] as String? ?? '',
      docsId: row['docs_id'] as String? ?? '',
      metadata: _decodeJson(row['metadata_json'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int? ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
    );
  }

  RagDocument _documentFromRow(Map<String, Object?> row) {
    return RagDocument(
      id: row['external_document_id'] as String? ?? '',
      baseId: row['base_id'] as String? ?? '',
      title: row['title'] as String? ?? '',
      markdown: row['markdown'] as String? ?? '',
      contentHash: row['content_hash'] as String? ?? '',
      metadata: _decodeJson(row['metadata_json'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int? ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
      indexedAt: (row['indexed_at'] as int?) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['indexed_at'] as int),
      syncStatus: _parseSyncStatus(row['sync_status'] as String?),
    );
  }

  RagSegment _segmentFromRow(Map<String, Object?> row) {
    return RagSegment(
      id: row['id'] as String? ?? '',
      baseId: row['base_id'] as String? ?? '',
      documentId: row['external_document_id'] as String? ?? '',
      segmentKey: row['segment_key'] as String? ?? '',
      segmentIndex: row['segment_index'] as int? ?? 0,
      headingPath: row['heading_path'] as String? ?? '',
      text: row['text'] as String? ?? '',
      textHash: row['text_hash'] as String? ?? '',
      contentFingerprint: row['content_fingerprint'] as String? ?? '',
      tokenEstimate: row['token_estimate'] as int? ?? 0,
      charStart: row['char_start'] as int? ?? 0,
      charEnd: row['char_end'] as int? ?? 0,
      vdbSegmentId: row['vdb_segment_id'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at'] as int? ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
    );
  }

  RagDocumentSyncStatus _parseSyncStatus(String? value) {
    for (final status in RagDocumentSyncStatus.values) {
      if (status.name == value) {
        return status;
      }
    }
    return RagDocumentSyncStatus.pending;
  }

  String? _encodeJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    return jsonEncode(json);
  }

  Map<String, dynamic>? _decodeJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    return null;
  }

  String _documentStorageId(String baseId, String documentId) {
    return stableHashHex(jsonEncode([baseId.trim(), documentId.trim()]));
  }
}

class _RagDbUser implements QueryExecutorUser {
  Future<void>? _initFuture;

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}

  Future<void> ensureInitialized(QueryExecutor executor) {
    _initFuture ??= _createSchema(executor);
    return _initFuture!;
  }

  Future<void> _createSchema(QueryExecutor executor) async {
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS rag_bases (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  docs_name TEXT NOT NULL,
  docs_id TEXT NOT NULL,
  metadata_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS rag_documents (
  id TEXT PRIMARY KEY,
  base_id TEXT NOT NULL,
  external_document_id TEXT NOT NULL,
  title TEXT NOT NULL,
  markdown TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  metadata_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  indexed_at INTEGER,
  sync_status TEXT NOT NULL
);
''');
    await executor.runCustom('''
CREATE TABLE IF NOT EXISTS rag_segments (
  id TEXT PRIMARY KEY,
  base_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  segment_key TEXT NOT NULL,
  segment_index INTEGER NOT NULL,
  heading_path TEXT NOT NULL,
  text TEXT NOT NULL,
  text_hash TEXT NOT NULL,
  content_fingerprint TEXT NOT NULL,
  token_estimate INTEGER NOT NULL,
  char_start INTEGER NOT NULL,
  char_end INTEGER NOT NULL,
  vdb_segment_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS rag_documents_base_updated_at
  ON rag_documents (base_id, updated_at);
''');
    await executor.runCustom('''
CREATE UNIQUE INDEX IF NOT EXISTS rag_documents_base_external_document
  ON rag_documents (base_id, external_document_id);
''');
    await executor.runCustom('''
CREATE INDEX IF NOT EXISTS rag_segments_document_segment_index
  ON rag_segments (document_id, segment_index);
''');
  }
}

QueryExecutor _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return NativeDatabase(file);
  });
}
