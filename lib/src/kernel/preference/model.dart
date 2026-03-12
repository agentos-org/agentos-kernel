class PreferenceSnapshot {
  final String? userId;
  final Map<String, dynamic> preferences;

  const PreferenceSnapshot({this.userId, Map<String, dynamic>? preferences})
    : preferences = preferences ?? const {};
}

Set<String> preferenceSignalKeys(Map<String, dynamic>? metadata) {
  if (metadata == null || metadata.isEmpty) {
    return const <String>{};
  }

  final keys = <String>{};

  final singleKey = metadata['preferenceKey'];
  if (singleKey is String && singleKey.trim().isNotEmpty) {
    keys.add(singleKey.trim());
  }

  final multipleKeys = metadata['preferenceKeys'];
  if (multipleKeys is List) {
    for (final item in multipleKeys) {
      if (item is String && item.trim().isNotEmpty) {
        keys.add(item.trim());
      }
    }
  }

  return keys;
}

class PreferenceSignal {
  final String userId;
  final String text;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;

  PreferenceSignal({
    required this.userId,
    required this.text,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
