class CandidateIntent {
  final String action;
  final String? target;
  final Map<String, dynamic>? params;
  final double confidence;

  const CandidateIntent({
    required this.action,
    this.target,
    this.params,
    required this.confidence,
  });
}

class Percept {
  final List<CandidateIntent> candidates;
  final double confidence;

  const Percept({
    required this.candidates,
    required this.confidence,
  });
}

class Intent {
  final String action;
  final String? target;
  final Map<String, dynamic>? params;
  final double confidence;

  const Intent({
    required this.action,
    this.target,
    this.params,
    required this.confidence,
  });
}
