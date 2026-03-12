class VectorMatch {
  final String id;
  final double score;
  final Map<String, dynamic>? payload;

  const VectorMatch({required this.id, required this.score, this.payload});
}

abstract class VectorStore {
  Future<String> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  });

  Future<void> delete(String id);

  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  });
}

abstract class TextQueryVectorStore implements VectorStore {
  Future<List<VectorMatch>> queryByText(String text, {int limit = 5});
}

class SwitchableTextQueryVectorStore implements TextQueryVectorStore {
  TextQueryVectorStore _delegate;

  SwitchableTextQueryVectorStore(this._delegate);

  TextQueryVectorStore get delegate => _delegate;

  set delegate(TextQueryVectorStore delegate) {
    _delegate = delegate;
  }

  @override
  Future<String> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) {
    return _delegate.upsert(id: id, vector: vector, payload: payload);
  }

  @override
  Future<void> delete(String id) {
    return _delegate.delete(id);
  }

  @override
  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  }) {
    return _delegate.query(vector: vector, limit: limit);
  }

  @override
  Future<List<VectorMatch>> queryByText(String text, {int limit = 5}) {
    return _delegate.queryByText(text, limit: limit);
  }
}

class ThrowingTextQueryVectorStore implements TextQueryVectorStore {
  final String message;

  ThrowingTextQueryVectorStore({this.message = 'Embeddings not configured.'});

  @override
  Future<String> upsert({
    required String id,
    required List<double> vector,
    Map<String, dynamic>? payload,
  }) {
    throw StateError(message);
  }

  @override
  Future<void> delete(String id) {
    throw StateError(message);
  }

  @override
  Future<List<VectorMatch>> query({
    required List<double> vector,
    int limit = 5,
  }) {
    throw StateError(message);
  }

  @override
  Future<List<VectorMatch>> queryByText(String text, {int limit = 5}) {
    throw StateError(message);
  }
}
