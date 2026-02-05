import 'package:lite_embeddings_sdk_dart/lite_embeddings_sdk_dart.dart' as embeddings;

import 'vector_store.dart';

class LiteEmbeddingsVectorStore implements VectorStore {
  final embeddings.LiteEmbeddingsClient client;
  final String docsId;
  final embeddings.LLMConfig llmConfig;

  LiteEmbeddingsVectorStore({
    required this.client,
    required this.docsId,
    required this.llmConfig,
  });

  @override
  Future<void> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) async {
    final text = payload?['text'];
    if (text is! String || text.trim().isEmpty) {
      throw ArgumentError(
        'LiteEmbeddingsVectorStore requires payload.text for inserts.',
      );
    }
    final metadata = <String, dynamic>{
      if (payload != null) ...payload,
      'id': id,
    };
    await client.insertSegment(
      embeddings.InsertSegmentRequest(
        docsId: docsId,
        segment: embeddings.Segment(
          text: text,
          metadata: metadata,
        ),
        llmConfig: llmConfig,
      ),
    );
  }

  @override
  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  }) {
    throw UnsupportedError(
      'LiteEmbeddingsVectorStore does not support vector query. Use queryByText.',
    );
  }

  Future<List<VectorMatch>> queryByText(
    String text, {
    int limit = 5,
  }) async {
    final result = await client.queryDocs(
      embeddings.QueryRequest(
        docsId: docsId,
        queryText: text,
        nResults: limit,
        llmConfig: llmConfig,
      ),
    );
    return result.segmentResultList.map((segment) {
      final payload = <String, dynamic>{
        if (segment.metadata != null) ...segment.metadata!,
      };
      payload.putIfAbsent('text', () => segment.text);
      payload['distance'] = segment.distance;
      return VectorMatch(
        id: segment.segmentId,
        score: -segment.distance,
        payload: payload.isEmpty ? null : payload,
      );
    }).toList(growable: false);
  }
}
