import 'package:hive/hive.dart';

import '../agent/model.dart';

class ModelPurposeStats {
  int totalCalls;
  int successCount;
  int failureCount;

  ModelPurposeStats({
    this.totalCalls = 0,
    this.successCount = 0,
    this.failureCount = 0,
  });

  double get successRate =>
      totalCalls == 0 ? 0.0 : successCount / totalCalls;

  Map<String, dynamic> toMap() => {
    'totalCalls': totalCalls,
    'successCount': successCount,
    'failureCount': failureCount,
  };

  factory ModelPurposeStats.fromMap(Map<String, dynamic> map) =>
      ModelPurposeStats(
        totalCalls: map['totalCalls'] as int? ?? 0,
        successCount: map['successCount'] as int? ?? 0,
        failureCount: map['failureCount'] as int? ?? 0,
      );
}

class ModelProfile {
  int totalCalls;
  int successCount;
  int failureCount;
  double avgTtftMs;
  double avgTps;
  int maxSuccessTokens;
  final Map<String, ModelPurposeStats> purposeStats;

  ModelProfile({
    this.totalCalls = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.avgTtftMs = 0.0,
    this.avgTps = 0.0,
    this.maxSuccessTokens = 0,
    Map<String, ModelPurposeStats>? purposeStats,
  }) : purposeStats = purposeStats ?? {};

  double get overallSuccessRate =>
      totalCalls == 0 ? 0.0 : successCount / totalCalls;

  double purposeSuccessRate(String purpose) {
    final stats = purposeStats[purpose];
    if (stats == null) return 0.0;
    return stats.successRate;
  }

  int purposeTotalCalls(String purpose) {
    return purposeStats[purpose]?.totalCalls ?? 0;
  }

  Map<String, dynamic> toMap() => {
    'totalCalls': totalCalls,
    'successCount': successCount,
    'failureCount': failureCount,
    'avgTtftMs': avgTtftMs,
    'avgTps': avgTps,
    'maxSuccessTokens': maxSuccessTokens,
    'purposeStats': purposeStats.map(
      (key, value) => MapEntry(key, value.toMap()),
    ),
  };

  factory ModelProfile.fromMap(Map<String, dynamic> map) {
    final rawPurpose = map['purposeStats'];
    final purposeStats = <String, ModelPurposeStats>{};
    if (rawPurpose is Map) {
      rawPurpose.forEach((key, value) {
        if (value is Map) {
          purposeStats[key.toString()] = ModelPurposeStats.fromMap(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return ModelProfile(
      totalCalls: map['totalCalls'] as int? ?? 0,
      successCount: map['successCount'] as int? ?? 0,
      failureCount: map['failureCount'] as int? ?? 0,
      avgTtftMs: (map['avgTtftMs'] as num?)?.toDouble() ?? 0.0,
      avgTps: (map['avgTps'] as num?)?.toDouble() ?? 0.0,
      maxSuccessTokens: map['maxSuccessTokens'] as int? ?? 0,
      purposeStats: purposeStats,
    );
  }
}

class ModelProfiler {
  final Box<Map>? _box;
  final Map<String, ModelProfile> _profiles = {};
  static const int _explorationThreshold = 10;

  ModelProfiler({Box<Map>? box}) : _box = box {
    _loadFromBox();
  }

  void _loadFromBox() {
    final box = _box;
    if (box == null) return;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        _profiles[key as String] = ModelProfile.fromMap(
          Map<String, dynamic>.from(raw),
        );
      }
    }
  }

  void record(LlmCallMetrics metrics) {
    final modelKey = metrics.meta.modelKey;
    final purpose = metrics.meta.purpose;
    final profile = _profiles.putIfAbsent(modelKey, () => ModelProfile());

    profile.totalCalls += 1;
    final purposeEntry = profile.purposeStats.putIfAbsent(
      purpose,
      () => ModelPurposeStats(),
    );
    purposeEntry.totalCalls += 1;

    if (metrics.success) {
      profile.successCount += 1;
      purposeEntry.successCount += 1;
      final tokens = metrics.totalTokens;
      if (tokens != null && tokens > profile.maxSuccessTokens) {
        profile.maxSuccessTokens = tokens;
      }
    } else {
      profile.failureCount += 1;
      purposeEntry.failureCount += 1;
    }

    final ttftMs = metrics.ttft?.inMilliseconds;
    if (ttftMs != null) {
      profile.avgTtftMs = _runningAvg(
        profile.avgTtftMs,
        ttftMs.toDouble(),
        profile.totalCalls,
      );
    }

    final tps = metrics.tps;
    if (tps != null) {
      profile.avgTps = _runningAvg(
        profile.avgTps,
        tps,
        profile.totalCalls,
      );
    }

    _persist(modelKey, profile);
  }

  ModelProfile? getProfile(String modelKey) => _profiles[modelKey];

  bool shouldSkip({
    required String modelKey,
    required String purpose,
    required double successRateThreshold,
  }) {
    final profile = _profiles[modelKey];
    if (profile == null) return false;
    if (profile.purposeTotalCalls(purpose) < _explorationThreshold) {
      return false;
    }
    return profile.purposeSuccessRate(purpose) < successRateThreshold;
  }

  double rankScore(String modelKey, String purpose) {
    final profile = _profiles[modelKey];
    if (profile == null) return 0.5;
    if (profile.purposeTotalCalls(purpose) < _explorationThreshold) {
      return 0.5;
    }
    return profile.purposeSuccessRate(purpose);
  }

  Map<String, ModelProfile> get profiles =>
      Map<String, ModelProfile>.unmodifiable(_profiles);

  double _runningAvg(double currentAvg, double newValue, int totalCount) {
    if (totalCount <= 1) return newValue;
    return currentAvg + (newValue - currentAvg) / totalCount;
  }

  void _persist(String modelKey, ModelProfile profile) {
    _box?.put(modelKey, profile.toMap());
  }
}
