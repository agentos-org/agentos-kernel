import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../supervision/model_profiler.dart';
import 'model.dart';

typedef LlmConfigResolver = LLMConfig Function();

LLMConfig normalizeLlmConfigForLiteAgent(LLMConfig config) {
  final apiKey = config.apiKey?.trim();
  if (apiKey == config.apiKey) {
    return config;
  }
  return LLMConfig(
    baseUrl: config.baseUrl,
    apiKey: (apiKey == null || apiKey.isEmpty) ? null : apiKey,
    model: config.model,
    contextWindowSize: config.contextWindowSize,
  );
}

class LlmConfigHolder {
  LLMConfig _value;

  LlmConfigHolder(this._value);

  LLMConfig get value => _value;

  void updateModel(String model) {
    _value = LLMConfig(
      baseUrl: _value.baseUrl,
      apiKey: _value.apiKey,
      model: model,
      contextWindowSize: _value.contextWindowSize,
    );
  }
}

class _PoolEntry {
  final LLMConfig config;
  final LlmModelSource source;
  final String modelKey;

  _PoolEntry({required this.config, required this.source})
    : modelKey = buildLlmModelKey(
        baseUrl: config.baseUrl,
        model: config.model,
        apiKey: config.apiKey ?? '',
      );
}

class LlmConfigPool {
  List<_PoolEntry> _entries;

  LlmConfigPool(List<LLMConfig> configs)
    : _entries = configs
          .map((c) => _PoolEntry(config: c, source: LlmModelSource.local))
          .toList();

  LlmConfigPool.fromModels(List<KernelLlmModel> models)
    : _entries = models
          .map(
            (m) => _PoolEntry(
              config: LLMConfig(
                baseUrl: m.baseUrl,
                apiKey: m.apiKey ?? '',
                model: m.model,
                contextWindowSize: m.contextWindowSize,
              ),
              source: m.source,
            ),
          )
          .toList();

  List<LLMConfig> get configs =>
      _entries.map((e) => e.config).toList(growable: false);

  void update(List<LLMConfig> configs) {
    _entries = configs
        .map((c) => _PoolEntry(config: c, source: LlmModelSource.local))
        .toList();
  }

  void updateFromModels(List<KernelLlmModel> models) {
    _entries = models
        .map(
          (m) => _PoolEntry(
            config: LLMConfig(
              baseUrl: m.baseUrl,
              apiKey: m.apiKey ?? '',
              model: m.model,
              contextWindowSize: m.contextWindowSize,
            ),
            source: m.source,
          ),
        )
        .toList();
  }

  LLMConfig pick({bool Function(LLMConfig config)? isAvailable}) {
    if (_entries.isEmpty) {
      throw StateError('LLM config pool is empty.');
    }
    if (isAvailable == null) {
      return _entries.first.config;
    }
    for (final entry in _entries) {
      if (isAvailable(entry.config)) {
        return entry.config;
      }
    }
    return _entries.first.config;
  }

  LLMConfig? pickForPurpose({
    required KernelMode mode,
    required String purpose,
    bool Function(LLMConfig config)? isAvailable,
    ModelProfiler? profiler,
    Map<String, KernelLlmModel>? modelCatalog,
    double successRateThreshold = 0.4,
    bool allowProfilerSkip = true,
  }) {
    if (_entries.isEmpty) return null;

    final sourcePriority = _sourcePriority(mode);

    for (final source in sourcePriority) {
      final tier = _entries.where((e) => e.source == source).toList();
      if (tier.isEmpty) continue;

      final filtered = tier.where((e) {
        if (isAvailable != null && !isAvailable(e.config)) return false;

        if (mode == KernelMode.balanced &&
            purpose == 'planning' &&
            e.source == LlmModelSource.local) {
          final catalogModel = modelCatalog?[e.modelKey];
          if (catalogModel != null && catalogModel.paramsB < 14) {
            return false;
          }
        }

        if (profiler != null &&
            allowProfilerSkip &&
            mode != KernelMode.economy &&
            profiler.shouldSkip(
              modelKey: e.modelKey,
              purpose: purpose,
              successRateThreshold: successRateThreshold,
            )) {
          return false;
        }

        return true;
      }).toList();

      if (filtered.isEmpty) continue;

      if (profiler != null && filtered.length > 1) {
        filtered.sort((a, b) {
          final scoreA = profiler.rankScore(a.modelKey, purpose);
          final scoreB = profiler.rankScore(b.modelKey, purpose);
          return scoreB.compareTo(scoreA);
        });
      }

      return filtered.first.config;
    }

    return null;
  }

  List<LlmModelSource> _sourcePriority(KernelMode mode) {
    switch (mode) {
      case KernelMode.economy:
        return const [
          LlmModelSource.local,
          LlmModelSource.custom,
          LlmModelSource.remote,
        ];
      case KernelMode.balanced:
        return const [
          LlmModelSource.local,
          LlmModelSource.custom,
          LlmModelSource.remote,
        ];
      case KernelMode.performance:
        return const [
          LlmModelSource.remote,
          LlmModelSource.custom,
          LlmModelSource.local,
        ];
    }
  }
}
