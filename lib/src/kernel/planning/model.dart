import '../perception/model.dart';

enum PlanDecision {
  ready,
  needsConfirmation,
  rejected,
}

class ConfirmationRequest {
  final String prompt;

  const ConfirmationRequest({
    required this.prompt,
  });
}

class PlanResult {
  final Intent? intent;
  final PlanDecision decision;
  final String? reason;
  final ConfirmationRequest? confirmation;

  const PlanResult({
    required this.intent,
    required this.decision,
    this.reason,
    this.confirmation,
  });
}
