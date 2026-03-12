import 'model.dart';

abstract class Preference {
  Future<PreferenceSnapshot> getSnapshot({String? userId});
  Future<void> recordSignal(PreferenceSignal signal);
  Future<Map<String, dynamic>> listPreferences({String? userId});
  Future<void> deletePreferenceKey(String key, {String? userId});
}

class InMemoryPreference extends Preference {
  final Map<String, Map<String, dynamic>> _preferences = {};

  @override
  Future<PreferenceSnapshot> getSnapshot({String? userId}) async {
    return PreferenceSnapshot(
      userId: userId,
      preferences: userId == null ? const {} : _preferences[userId] ?? const {},
    );
  }

  @override
  Future<void> recordSignal(PreferenceSignal signal) async {
    final prefs = _preferences.putIfAbsent(
      signal.userId,
      () => <String, dynamic>{},
    );
    final signals =
        (prefs['signals'] as List<dynamic>?)?.toList() ?? <dynamic>[];
    signals.add({
      'text': signal.text,
      'metadata': signal.metadata,
      'timestamp': signal.timestamp,
    });
    prefs['signals'] = signals;
  }

  @override
  Future<Map<String, dynamic>> listPreferences({String? userId}) async {
    if (userId == null) {
      return const {};
    }
    return Map<String, dynamic>.from(_preferences[userId] ?? const {});
  }

  @override
  Future<void> deletePreferenceKey(String key, {String? userId}) async {
    if (userId == null) {
      return;
    }
    final prefs = _preferences[userId];
    prefs?.remove(key);
    final signals = (prefs?['signals'] as List<dynamic>?)?.toList();
    if (signals == null) {
      return;
    }
    final updatedSignals = <dynamic>[];
    for (final signal in signals) {
      final updatedSignal = _removePreferenceKeyFromSignal(signal, key);
      if (updatedSignal != null) {
        updatedSignals.add(updatedSignal);
      }
    }
    prefs!['signals'] = updatedSignals;
  }

  Map<String, dynamic>? _removePreferenceKeyFromSignal(
    Object? signal,
    String key,
  ) {
    if (signal is! Map) {
      return null;
    }
    final signalMap = Map<String, dynamic>.from(signal);
    final metadata = signalMap['metadata'];
    if (metadata is! Map<String, dynamic>) {
      return signalMap;
    }
    final nextMetadata = _removePreferenceKeyFromMetadata(metadata, key);
    if (nextMetadata == null) {
      return null;
    }
    signalMap['metadata'] = nextMetadata;
    return signalMap;
  }

  Map<String, dynamic>? _removePreferenceKeyFromMetadata(
    Map<String, dynamic> metadata,
    String key,
  ) {
    final nextMetadata = Map<String, dynamic>.from(metadata);
    final singleKey = nextMetadata['preferenceKey'];
    if (singleKey is String && singleKey.trim() == key) {
      nextMetadata.remove('preferenceKey');
    }

    final multipleKeys = nextMetadata['preferenceKeys'];
    if (multipleKeys is List) {
      final retainedKeys = multipleKeys
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty && item != key)
          .toList(growable: false);
      if (retainedKeys.isEmpty) {
        nextMetadata.remove('preferenceKeys');
      } else {
        nextMetadata['preferenceKeys'] = retainedKeys;
      }
    }

    if (preferenceSignalKeys(nextMetadata).isEmpty) {
      return null;
    }
    return nextMetadata;
  }
}
