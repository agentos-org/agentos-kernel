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
