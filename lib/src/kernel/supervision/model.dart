class SupervisionAdvice {
  final String message;
  final bool requiresIntervention;
  final Map<String, dynamic>? metadata;

  const SupervisionAdvice({
    required this.message,
    required this.requiresIntervention,
    this.metadata,
  });
}

enum ExternalServiceType {
  llm,
  liteagent,
  opentoolDaemon,
  embeddings,
}

class ExternalServiceHealth {
  final String id;
  final ExternalServiceType type;
  final bool available;
  final String? version;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final String? message;
  final String? endpoint;
  final String? modelKey;

  const ExternalServiceHealth({
    required this.id,
    required this.type,
    required this.available,
    this.version,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.message,
    this.endpoint,
    this.modelKey,
  });

  ExternalServiceHealth copyWith({
    bool? available,
    String? version,
    DateTime? lastSuccessAt,
    DateTime? lastFailureAt,
    String? message,
    String? endpoint,
    String? modelKey,
  }) {
    return ExternalServiceHealth(
      id: id,
      type: type,
      available: available ?? this.available,
      version: version ?? this.version,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      lastFailureAt: lastFailureAt ?? this.lastFailureAt,
      message: message ?? this.message,
      endpoint: endpoint ?? this.endpoint,
      modelKey: modelKey ?? this.modelKey,
    );
  }
}

class ExternalServiceHealthSnapshot {
  final Map<String, ExternalServiceHealth> items;

  const ExternalServiceHealthSnapshot({
    required this.items,
  });
}

typedef ExternalServiceHealthListener = void Function(
  ExternalServiceHealth health,
);

class ExternalServiceHealthSubscription {
  final void Function() _cancel;

  const ExternalServiceHealthSubscription(this._cancel);

  void cancel() => _cancel();
}
