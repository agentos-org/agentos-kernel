import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../supervision/model_profiler.dart';
import 'model.dart';

typedef LlmConfigResolver = LLMConfig Function();

/// liteagent 服务端约定的统一 provider。内核侧发送任何大模型请求都使用它，
/// 真实上游厂商通过 [LLMConfig.adapter] 区分。
const String kLiteAgentProvider = 'lite_oneapi';

const String _kDefaultAdapter = 'openai';

/// 归一化内核下发给 liteagent 的 [LLMConfig]：
/// - 强制 `provider = lite_oneapi`（不再使用 `provider=openai`）；
/// - `adapter` 保留模型自带的上游厂商标识，缺省回落到 `openai`；
/// - 顺带 trim 掉 apiKey 的首尾空白。
LLMConfig normalizeLlmConfigForLiteAgent(LLMConfig config) {
  final apiKey = config.apiKey?.trim();
  final adapter = (config.adapter == null || config.adapter!.trim().isEmpty)
      ? _kDefaultAdapter
      : config.adapter!.trim();
  return LLMConfig(
    provider: kLiteAgentProvider,
    baseUrl: config.baseUrl,
    apiKey: (apiKey == null || apiKey.isEmpty) ? null : apiKey,
    model: config.model,
    adapter: adapter,
    headers: config.headers,
    temperature: config.temperature,
    maxTokens: config.maxTokens,
    contextWindowSize: config.contextWindowSize,
    topP: config.topP,
    supportsToolCall: config.supportsToolCall,
    supportsReasoning: config.supportsReasoning,
  );
}

/// 由 [KernelLlmModel] 构造 liteagent [LLMConfig]，统一写入
/// `provider=lite_oneapi` 且 `adapter=model.provider`。
LLMConfig _buildLiteAgentConfig(KernelLlmModel model) {
  return LLMConfig(
    provider: kLiteAgentProvider,
    baseUrl: model.baseUrl,
    apiKey: model.apiKey ?? '',
    model: model.model,
    adapter: model.provider,
    contextWindowSize: model.contextWindowSize,
  );
}

class LlmConfigHolder {
  LLMConfig _value;

  LlmConfigHolder(this._value);

  LLMConfig get value => _value;

  void updateModel(String model) {
    _value = LLMConfig(
      provider: _value.provider,
      baseUrl: _value.baseUrl,
      apiKey: _value.apiKey,
      model: model,
      adapter: _value.adapter,
      headers: _value.headers,
      temperature: _value.temperature,
      maxTokens: _value.maxTokens,
      contextWindowSize: _value.contextWindowSize,
      topP: _value.topP,
      supportsToolCall: _value.supportsToolCall,
      supportsReasoning: _value.supportsReasoning,
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
              config: _buildLiteAgentConfig(m),
              source: m.source,
            ),
          )
          .toList() {
    registerKernelLlmModels(models);
  }

  List<LLMConfig> get configs =>
      _entries.map((e) => e.config).toList(growable: false);

  void update(List<LLMConfig> configs) {
    _entries = configs
        .map((c) => _PoolEntry(config: c, source: LlmModelSource.local))
        .toList();
  }

  void updateFromModels(List<KernelLlmModel> models) {
    registerKernelLlmModels(models);
    _entries = models
        .map(
          (m) => _PoolEntry(
            config: _buildLiteAgentConfig(m),
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
