import '../agent/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

bool modelSupportsImageInput(LLMConfig config) {
  final registered = lookupModelSupportsImageInput(
    baseUrl: config.baseUrl,
    model: config.model,
    apiKey: config.apiKey,
  );
  if (registered != null) {
    return registered;
  }
  final model = config.model.toLowerCase();
  const visionMarkers = <String>[
    'gpt-4o',
    'gpt-4.1',
    'gpt-4.5',
    'gpt-5',
    'claude-3',
    'claude-3.5',
    'claude-3.7',
    'gemini',
    'vision',
    'vl',
    'llava',
    'minicpm-v',
    'internvl',
    'qwen-vl',
    'glm-4v',
    'pixtral',
    'kimi-vl',
  ];
  return visionMarkers.any(model.contains);
}

List<Content> normalizeContentForModel(
  List<Content> content,
  LLMConfig config,
) {
  final supportsImage = modelSupportsImageInput(config);
  return content
      .map(
        (item) => Content.fromJson(
          _normalizeContentItem(item.toJson(), supportsImage),
        ),
      )
      .toList(growable: false);
}

Map<String, dynamic>? normalizeStructuredDataForModel(
  Map<String, dynamic>? data,
  LLMConfig config,
) {
  final normalized = normalizeStructuredValueForModel(data, config);
  if (normalized is Map<String, dynamic>) {
    return normalized;
  }
  if (normalized is Map) {
    return normalized.cast<String, dynamic>();
  }
  return null;
}

Object? normalizeStructuredValueForModel(Object? value, LLMConfig config) {
  return _normalizeValue(value, modelSupportsImageInput(config));
}

List<Content> contentFromStructuredData(
  Map<String, dynamic>? data,
  LLMConfig config,
) {
  final raw = data?['content'];
  if (raw is! List) {
    return const [];
  }
  final supportsImage = modelSupportsImageInput(config);
  return raw
      .whereType<Map>()
      .map(
        (item) => Content.fromJson(
          _normalizeContentItem(Map<String, dynamic>.from(item), supportsImage),
        ),
      )
      .toList(growable: false);
}

Map<String, dynamic>? omitStructuredContent(Map<String, dynamic>? data) {
  if (data == null || data.isEmpty) {
    return data;
  }
  final next = Map<String, dynamic>.from(data);
  next.remove('content');
  next.remove('contentList');
  return next;
}

Object? _normalizeValue(Object? value, bool supportsImage) {
  if (value is Map) {
    final normalized = <String, dynamic>{};
    value.forEach((key, entry) {
      final stringKey = key.toString();
      if ((stringKey == 'content' || stringKey == 'contentList') &&
          entry is List) {
        normalized[stringKey] = entry
            .whereType<Map>()
            .map(
              (item) => _normalizeContentItem(
                Map<String, dynamic>.from(item),
                supportsImage,
              ),
            )
            .toList(growable: false);
        return;
      }
      normalized[stringKey] = _normalizeValue(entry, supportsImage);
    });
    return normalized;
  }
  if (value is List) {
    return value
        .map((entry) => _normalizeValue(entry, supportsImage))
        .toList(growable: false);
  }
  return value;
}

Map<String, dynamic> _normalizeContentItem(
  Map<String, dynamic> item,
  bool supportsImage,
) {
  final type = item['type'];
  if (!supportsImage && type is String && type.toLowerCase() == 'image') {
    return const {'type': 'text', 'message': '[image]'};
  }
  return Map<String, dynamic>.from(item);
}
