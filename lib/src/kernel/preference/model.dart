class PreferenceEntry {
  final String id;
  final String text;
  final DateTime updatedAt;

  const PreferenceEntry({
    required this.id,
    required this.text,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PreferenceEntry.fromJson(Map<String, dynamic> json) {
    return PreferenceEntry(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class PreferenceExtractionTriggerResult {
  static const String reasonEmpty = 'empty';
  static const String reasonInsufficientRecords = 'insufficient_records';
  static const String reasonNoNewPreference = 'no_new_preference';
  static const String reasonGenerated = 'generated';

  final List<PreferenceEntry> preferences;
  final int sourceRecordCount;
  final int minRequired;
  final String reason;

  const PreferenceExtractionTriggerResult({
    required this.preferences,
    required this.sourceRecordCount,
    required this.minRequired,
    required this.reason,
  });
}

String normalizePreferenceText(String text) {
  return text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

String buildPreferenceId(String userId, String text, DateTime? updatedAt) {
  final effectiveUpdatedAt = updatedAt ?? DateTime.now();
  final normalizedText = normalizePreferenceText(text);
  return [
    userId.trim(),
    effectiveUpdatedAt.microsecondsSinceEpoch.toString(),
    normalizedText.hashCode.toUnsigned(32).toRadixString(16),
  ].join('_');
}
