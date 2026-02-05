import 'dart:convert';

import 'package:http/http.dart' as http;

import 'vector_store.dart';

class QdrantVectorStore implements VectorStore {
  final http.Client _client;
  final Uri _baseUri;
  final String collection;

  QdrantVectorStore({
    required String baseUrl,
    required this.collection,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _baseUri = Uri.parse(baseUrl);

  @override
  Future<void> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) async {
    final uri = _baseUri.replace(path: '/collections/$collection/points');
    final body = jsonEncode({
      'points': [
        {
          'id': id,
          'vector': vector,
          'payload': payload ?? const <String, dynamic>{},
        },
      ],
    });
    final response = await _client.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Qdrant upsert failed: ${response.statusCode}');
    }
  }

  @override
  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  }) async {
    final uri = _baseUri.replace(path: '/collections/$collection/points/search');
    final body = jsonEncode({
      'vector': vector,
      'limit': limit,
      'with_payload': true,
    });
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Qdrant query failed: ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final result = decoded['result'] as List<dynamic>? ?? const [];
    return result
        .map(
          (entry) => VectorMatch(
            id: entry['id'].toString(),
            score: (entry['score'] as num).toDouble(),
            payload: entry['payload'] as Map<String, dynamic>?,
          ),
        )
        .toList(growable: false);
  }
}
