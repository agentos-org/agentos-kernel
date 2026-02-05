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

  LlmCallContext({
    required this.meta,
    required this.onFirstToken,
  });

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
}

class KernelLlmModel {
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String description;
  final String parameters;
  final num paramsB;
  final String quantization;
  final num sizeGB;

  const KernelLlmModel({
    required this.baseUrl,
    required this.model,
    this.apiKey,
    required this.description,
    required this.parameters,
    required this.paramsB,
    required this.quantization,
    required this.sizeGB,
  });

  String modelKey({String? apiKeyOverride}) {
    return buildLlmModelKey(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKeyOverride ?? apiKey ?? '',
    );
  }
}

String buildLlmModelKey({
  required String baseUrl,
  required String model,
  required String apiKey,
}) {
  final apiHash = apiKey.hashCode.toUnsigned(32);
  return '$baseUrl|$model|$apiHash';
}
