enum LlmModelSource { local, remote, custom }

enum KernelMode { economy, balanced, performance }

class LlmRequestMeta {
  final String id;
  final String purpose;
  final int priority;
  final int weight;
  final String modelKey;
  final String? jobId;
  final String? userId;
  final DateTime enqueuedAt;

  LlmRequestMeta({
    required this.id,
    required this.purpose,
    required this.priority,
    required this.weight,
    required this.modelKey,
    this.jobId,
    this.userId,
    DateTime? enqueuedAt,
  }) : enqueuedAt = enqueuedAt ?? DateTime.now();
}

class LlmQueueSnapshot {
  final int inFlight;
  final int queued;
  final int totalInFlight;
  final int totalQueued;

  const LlmQueueSnapshot({
    required this.inFlight,
    required this.queued,
    required this.totalInFlight,
    required this.totalQueued,
  });
}

class LlmCallMetrics {
  final LlmRequestMeta meta;
  final DateTime startedAt;
  final DateTime? firstTokenAt;
  final DateTime doneAt;
  final int? totalTokens;
  final double? contextUsageRatio;
  final Duration? ttft;
  final double? tps;
  final bool success;
  final String? error;

  const LlmCallMetrics({
    required this.meta,
    required this.startedAt,
    required this.doneAt,
    required this.success,
    this.firstTokenAt,
    this.totalTokens,
    this.contextUsageRatio,
    this.ttft,
    this.tps,
    this.error,
  });
}

class LlmCallContext {
  final LlmRequestMeta meta;
  final void Function(DateTime firstTokenAt) onFirstToken;
  DateTime? firstTokenAt;
  int? totalTokens;
  double? contextUsageRatio;

  LlmCallContext({required this.meta, required this.onFirstToken});

  void markFirstToken() {
    if (firstTokenAt != null) {
      return;
    }
    firstTokenAt = DateTime.now();
    onFirstToken(firstTokenAt!);
  }

  void setTotalTokens(int total) {
    totalTokens = total;
  }

  void setContextUsageRatio(double ratio) {
    contextUsageRatio = ratio;
  }
}

class KernelLlmModel {
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String? type;
  final String description;
  final String parameters;
  final num paramsB;
  final String quantization;
  final num sizeGB;
  final int? contextWindowSize;
  final LlmModelSource source;

  /// Canonical upstream provider name supplied by agentos-api
  /// (`openai/deepseek/glm/kimi/mimo/minimax/qwen`).
  ///
  /// When building a liteagent [LLMConfig] this value becomes the liteagent `adapter`
  /// Defaults to `openai`.
  final String provider;

  const KernelLlmModel({
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.type,
    required this.description,
    required this.parameters,
    required this.paramsB,
    required this.quantization,
    required this.sizeGB,
    this.contextWindowSize,
    this.source = LlmModelSource.local,
    this.provider = 'openai',
  });

  String modelKey({String? apiKeyOverride}) {
    return buildLlmModelKey(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKeyOverride ?? apiKey ?? '',
    );
  }

  bool get supportsImageInput {
    final normalizedType = type?.trim().toLowerCase();
    return normalizedType == 'image_text_to_text' ||
        normalizedType == 'imagetexttotext';
  }
}

final Map<String, bool> _supportsImageInputByModelKey = {};

void registerKernelLlmModels(Iterable<KernelLlmModel> models) {
  _supportsImageInputByModelKey
    ..clear()
    ..addEntries(
      models.map(
        (model) => MapEntry(model.modelKey(), model.supportsImageInput),
      ),
    );
}

bool? lookupModelSupportsImageInput({
  required String baseUrl,
  required String model,
  String? apiKey,
}) {
  final modelKey = buildLlmModelKey(
    baseUrl: baseUrl,
    model: model,
    apiKey: apiKey,
  );
  return _supportsImageInputByModelKey[modelKey];
}

String buildLlmModelKey({
  required String baseUrl,
  required String model,
  String? apiKey,
}) {
  final normalizedApiKey = apiKey ?? '';
  final apiHash = normalizedApiKey.hashCode.toUnsigned(32);
  return '$baseUrl|$model|$apiHash';
}
