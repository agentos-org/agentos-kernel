import 'package:hive/hive.dart';

import 'embedder.dart';
import 'model.dart';
import 'preference.dart';
import 'vector_store.dart';

class HivePreference implements Preference {
  final Box<Map> _box;
  final VectorStore _vectorStore;
  final PreferenceEmbedder _embedder;
  final int signalRetention;

  HivePreference({
    required Box<Map> box,
    required VectorStore vectorStore,
    PreferenceEmbedder? embedder,
    this.signalRetention = 50,
  })  : _box = box,
        _vectorStore = vectorStore,
        _embedder = embedder ?? HashEmbedder();

  @override
  Future<PreferenceSnapshot> getSnapshot({String? userId}) async {
    if (userId == null) {
      return const PreferenceSnapshot();
    }
    final record = _box.get(userId);
    final preferences =
        (record?['preferences'] as Map<String, dynamic>?) ?? const {};
    return PreferenceSnapshot(userId: userId, preferences: preferences);
  }

  @override
  Future<void> recordSignal(PreferenceSignal signal) async {
    final record = _box.get(signal.userId) ?? <String, dynamic>{};
    final signals =
        (record['signals'] as List<dynamic>?)?.toList() ?? <dynamic>[];
    signals.add(_signalToMap(signal));
    if (signals.length > signalRetention) {
      signals.removeAt(0);
    }
    record['signals'] = signals;
    record.putIfAbsent('preferences', () => <String, dynamic>{});
    await _box.put(signal.userId, record);
    final embedding = signal.embedding ?? _embedder.embed(signal.text);
    await _vectorStore.upsert(
      id: '${signal.userId}-${signal.timestamp.microsecondsSinceEpoch}',
      vector: embedding,
      payload: {
        'userId': signal.userId,
        'text': signal.text,
        'metadata': signal.metadata,
        'timestamp': signal.timestamp.toIso8601String(),
      },
    );
  }

  Map<String, dynamic> _signalToMap(PreferenceSignal signal) {
    return {
      'userId': signal.userId,
      'text': signal.text,
      'embedding': signal.embedding,
      'metadata': signal.metadata,
      'timestamp': signal.timestamp,
    };
  }
}
