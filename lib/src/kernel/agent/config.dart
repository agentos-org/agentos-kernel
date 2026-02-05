import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

typedef LlmConfigResolver = LLMConfig Function();

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

class LlmConfigPool {
  List<LLMConfig> _configs;

  LlmConfigPool(List<LLMConfig> configs)
      : _configs = List<LLMConfig>.from(configs);

  List<LLMConfig> get configs => List<LLMConfig>.unmodifiable(_configs);

  void update(List<LLMConfig> configs) {
    _configs = List<LLMConfig>.from(configs);
  }

  LLMConfig pick({bool Function(LLMConfig config)? isAvailable}) {
    if (_configs.isEmpty) {
      throw StateError('LLM config pool is empty.');
    }
    if (isAvailable == null) {
      return _configs.first;
    }
    for (final config in _configs) {
      if (isAvailable(config)) {
        return config;
      }
    }
    return _configs.first;
  }
}
