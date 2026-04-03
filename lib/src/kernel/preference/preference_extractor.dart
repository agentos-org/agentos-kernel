import 'model.dart';

class PreferenceSourceRecord {
  final String jobId;
  final String? userId;
  final String type;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  const PreferenceSourceRecord({
    required this.jobId,
    this.userId,
    required this.type,
    this.data,
    required this.timestamp,
  });
}

abstract class PreferenceExtractor {
  Future<List<PreferenceEntry>> consume(PreferenceSourceRecord record);
}

class SwitchablePreferenceExtractor implements PreferenceExtractor {
  PreferenceExtractor delegate;

  SwitchablePreferenceExtractor(this.delegate);

  @override
  Future<List<PreferenceEntry>> consume(PreferenceSourceRecord record) =>
      delegate.consume(record);
}

class ThrowingPreferenceExtractor implements PreferenceExtractor {
  final String message;

  ThrowingPreferenceExtractor({
    this.message = 'LLM models not configured.',
  });

  @override
  Future<List<PreferenceEntry>> consume(PreferenceSourceRecord record) {
    throw StateError(message);
  }
}

class OfflinePreferenceExtractor implements PreferenceExtractor {
  @override
  Future<List<PreferenceEntry>> consume(PreferenceSourceRecord record) async =>
      const [];
}
