import '../perception/model.dart';

@Deprecated(
  'Planning is deprecated and will be removed in a future release. '
  'Prefer direct execution-oriented flow.',
)
enum PlanDecision {
  ready,
  needsConfirmation,
  rejected,
}

@Deprecated(
  'Planning is deprecated and will be removed in a future release. '
  'Prefer direct execution-oriented flow.',
)
class ConfirmationRequest {
  final String prompt;

  const ConfirmationRequest({
    required this.prompt,
  });
}

@Deprecated(
  'Planning is deprecated and will be removed in a future release. '
  'Prefer direct execution-oriented flow.',
)
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
