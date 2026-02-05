import 'job_manager.dart';
import 'perception/input.dart';
import 'perception/model.dart';
import 'planning/model.dart';

abstract class KernelEvent {
  final String type;
  final String jobId;
  final String? userId;
  final String? sessionId;
  final String? source;
  final DateTime timestamp;

  KernelEvent({
    required this.type,
    required this.jobId,
    this.userId,
    this.sessionId,
    this.source,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class KernelEventTypes {
  static const perceptReady = 'PERCEPT_READY';
  static const planReady = 'PLAN_READY';
  static const jobNeedsConfirmation = 'JOB_NEEDS_CONFIRMATION';
  static const jobQueued = 'JOB_QUEUED';
  static const jobRunning = 'JOB_RUNNING';
  static const jobDone = 'JOB_DONE';
  static const jobFailed = 'JOB_FAILED';
  static const jobCancelled = 'JOB_CANCELLED';
  static const toolCallStarted = 'TOOL_CALL_STARTED';
  static const toolCallDone = 'TOOL_CALL_DONE';
  static const toolCallFailed = 'TOOL_CALL_FAILED';
}

class PerceptReadyEvent extends KernelEvent {
  final RawInput input;
  final Percept percept;

  PerceptReadyEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.input,
    required this.percept,
  }) : super(type: KernelEventTypes.perceptReady);
}

class PlanReadyEvent extends KernelEvent {
  final PlanResult planResult;

  PlanReadyEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.planResult,
  }) : super(type: KernelEventTypes.planReady);
}

class JobNeedsConfirmationEvent extends KernelEvent {
  final ConfirmationRequest confirmation;
  final Intent intent;

  JobNeedsConfirmationEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.confirmation,
    required this.intent,
  }) : super(type: KernelEventTypes.jobNeedsConfirmation);
}

class JobQueuedEvent extends KernelEvent {
  final Intent intent;

  JobQueuedEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.intent,
  }) : super(type: KernelEventTypes.jobQueued);
}

class JobRunningEvent extends KernelEvent {
  JobRunningEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
  }) : super(type: KernelEventTypes.jobRunning);
}

class JobDoneEvent extends KernelEvent {
  final JobResult result;

  JobDoneEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.result,
  }) : super(type: KernelEventTypes.jobDone);
}

class JobFailedEvent extends KernelEvent {
  final String reason;

  JobFailedEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.reason,
  }) : super(type: KernelEventTypes.jobFailed);
}

class JobCancelledEvent extends KernelEvent {
  final String? reason;

  JobCancelledEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    this.reason,
  }) : super(type: KernelEventTypes.jobCancelled);
}

class ToolCallStartedEvent extends KernelEvent {
  final String toolId;
  final String function;
  final Map<String, dynamic>? arguments;
  final DateTime startedAt;

  ToolCallStartedEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.toolId,
    required this.function,
    this.arguments,
    required this.startedAt,
  }) : super(type: KernelEventTypes.toolCallStarted);
}

class ToolCallDoneEvent extends KernelEvent {
  final String toolId;
  final String function;
  final Map<String, dynamic>? result;
  final DateTime startedAt;
  final DateTime completedAt;

  ToolCallDoneEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.toolId,
    required this.function,
    this.result,
    required this.startedAt,
    required this.completedAt,
  }) : super(type: KernelEventTypes.toolCallDone);
}

class ToolCallFailedEvent extends KernelEvent {
  final String toolId;
  final String function;
  final String error;
  final DateTime startedAt;
  final DateTime completedAt;

  ToolCallFailedEvent({
    required super.jobId,
    super.userId,
    super.sessionId,
    super.source,
    required this.toolId,
    required this.function,
    required this.error,
    required this.startedAt,
    required this.completedAt,
  }) : super(type: KernelEventTypes.toolCallFailed);
}
