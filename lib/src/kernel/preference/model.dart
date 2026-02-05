class PreferenceSnapshot {
  final String? userId;
  final Map<String, dynamic> preferences;

  const PreferenceSnapshot({
    this.userId,
    Map<String, dynamic>? preferences,
  }) : preferences = preferences ?? const {};
}

class PreferenceSignal {
  final String userId;
  final String text;
  final List<double>? embedding;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;

  PreferenceSignal({
    required this.userId,
    required this.text,
    this.embedding,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
