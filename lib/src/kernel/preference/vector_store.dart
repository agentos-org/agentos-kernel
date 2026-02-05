class VectorMatch {
  final String id;
  final double score;
  final Map<String, dynamic>? payload;

  const VectorMatch({
    required this.id,
    required this.score,
    this.payload,
  });
}

abstract class VectorStore {
  Future<void> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  });

  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  });
}
