import 'dart:async';

import 'events.dart';
import 'execution/execution.dart';
import 'execution/model.dart';
import 'learning/learning.dart';
import 'learning/model.dart';
import 'memory/memory.dart';
import 'memory/model.dart';
import 'logging/logger.dart';
import 'perception/input.dart';
import 'perception/model.dart';
import 'perception/perception.dart';
import 'planning/model.dart';
import 'planning/planning.dart';
import 'preference/model.dart';
import 'preference/preference.dart';
import 'supervision/model.dart';
import 'supervision/supervision.dart';
import 'job_manager.dart';
import 'tool_call/queued_tool_call_store.dart';
import 'tool_call/tool_call_store.dart';

class Kernel {
  final Perception perception;
  final Planning planning;
  final Execution execution;
  final Supervision supervision;
  final Memory memory;
  final Preference preference;
  final Learning learning;
  final JobManager jobManager;
  final ToolCallStore? toolCallStore;
  final KernelLogger? logger;

  Kernel({
    required this.perception,
    required this.planning,
    required this.execution,
    required this.supervision,
    required this.memory,
    required this.preference,
    required this.learning,
    required this.jobManager,
    ToolCallStore? toolCallStore,
    this.logger,
  }) : toolCallStore = _wrapToolCallStore(
          toolCallStore,
          supervision,
          logger,
        );

  static ToolCallStore? _wrapToolCallStore(
    ToolCallStore? store,
    Supervision supervision,
    KernelLogger? logger,
  ) {
    if (store == null) {
      return null;
    }
    if (store is QueuedToolCallStore) {
      return store;
    }
    return QueuedToolCallStore(
      delegate: store,
      supervision: supervision,
      logger: logger,
    );
  }

  JobHandle input(RawInput input) {
    if (input.jobId != null) {
      return continueJob(input.jobId!, input);
    }
    final job = jobManager.createJob(
      source: input.source,
      userId: input.userId,
      sessionId: input.sessionId,
    );
    final enriched = RawInput(
      jobId: job.jobId,
      userId: input.userId,
      sessionId: input.sessionId,
      source: input.source,
      text: input.text,
      data: input.data,
    );
    unawaited(_processInput(enriched));
    return job;
  }

  JobHandle continueJob(String jobId, RawInput input) {
    final snapshot = jobManager.getSnapshot(jobId);
    final enriched = RawInput(
      jobId: jobId,
      userId: input.userId ?? snapshot.userId,
      sessionId: input.sessionId ?? snapshot.sessionId,
      source: input.source.isNotEmpty ? input.source : snapshot.source,
      text: input.text,
      data: input.data,
    );
    unawaited(_processInput(enriched));
    return jobManager.getHandle(jobId);
  }

  @Deprecated(
    'Planning-driven confirmation is deprecated and will be removed in a '
    'future release. Prefer direct execution-oriented APIs.',
  )
  JobHandle confirmJob(String jobId, {required bool confirmed}) {
    final snapshot = jobManager.getSnapshot(jobId);
    if (snapshot.status != JobStatus.NEEDS_CONFIRMATION) {
      return jobManager.getHandle(jobId);
    }
    if (!confirmed) {
      final handle = jobManager.cancel(jobId, reason: 'User declined.');
      final cancelledEvent = JobCancelledEvent(
        jobId: jobId,
        userId: snapshot.userId,
        sessionId: snapshot.sessionId,
        source: snapshot.source,
        reason: 'User declined confirmation.',
      );
      unawaited(_recordAll(cancelledEvent));
      return handle;
    }
    final intent = snapshot.pendingIntent;
    if (intent == null) {
      return jobManager.getHandle(jobId);
    }
    unawaited(_queueExecution(jobId, snapshot, intent));
    return jobManager.getHandle(jobId);
  }

  Future<void> _processInput(RawInput input) async {
    final percept = await perception.process(input);
    final perceptEvent = PerceptReadyEvent(
      jobId: input.jobId!,
      userId: input.userId,
      sessionId: input.sessionId,
      source: input.source,
      input: input,
      percept: percept,
    );
    await _recordAll(perceptEvent);

    final memorySnapshot = await memory.getSnapshot(scope: input.source);
    final preferenceSnapshot = await preference.getSnapshot(
      userId: input.userId,
    );
    final planResult = await planning.create(
      percept,
      memorySnapshot,
      preferenceSnapshot,
    );
    final planEvent = PlanReadyEvent(
      jobId: input.jobId!,
      userId: input.userId,
      sessionId: input.sessionId,
      source: input.source,
      planResult: planResult,
    );
    await _recordAll(planEvent);
    await _handlePlanResult(input, planResult);
  }

  Future<void> _handlePlanResult(
      RawInput input,
      PlanResult plan,
      ) async {
    if (plan.decision == PlanDecision.needsConfirmation) {
      final prompt = JobPrompt(
        message: plan.confirmation?.prompt ??
            plan.reason ??
            'Do you want to proceed?',
      );
      jobManager.markNeedsConfirmation(input.jobId!, prompt, plan.intent!);
      final confirmationEvent = JobNeedsConfirmationEvent(
        jobId: input.jobId!,
        userId: input.userId,
        sessionId: input.sessionId,
        source: input.source,
        confirmation: plan.confirmation ??
            ConfirmationRequest(prompt: prompt.message),
        intent: plan.intent!,
      );
      await _recordAll(confirmationEvent);
      return;
    }
    if (plan.decision == PlanDecision.rejected) {
      final reason = plan.reason ?? 'Plan was rejected.';
      jobManager.markFailed(input.jobId!, reason);
      final failedEvent = JobFailedEvent(
        jobId: input.jobId!,
        userId: input.userId,
        sessionId: input.sessionId,
        source: input.source,
        reason: reason,
      );
      await _recordAll(failedEvent);
      return;
    }
    if (plan.intent == null) {
      final reason = plan.reason ?? 'Intent is missing.';
      jobManager.markFailed(input.jobId!, reason);
      final failedEvent = JobFailedEvent(
        jobId: input.jobId!,
        userId: input.userId,
        sessionId: input.sessionId,
        source: input.source,
        reason: reason,
      );
      await _recordAll(failedEvent);
      return;
    }
    final snapshot = jobManager.getSnapshot(input.jobId!);
    await _queueExecution(input.jobId!, snapshot, plan.intent!);
  }

  Future<void> _queueExecution(
      String jobId,
      JobSnapshot snapshot,
      Intent intent,
      ) async {
    jobManager.markQueued(jobId);
    final queuedEvent = JobQueuedEvent(
      jobId: jobId,
      userId: snapshot.userId,
      sessionId: snapshot.sessionId,
      source: snapshot.source,
      intent: intent,
    );
    await _recordAll(queuedEvent);

    jobManager.markRunning(jobId);
    final runningEvent = JobRunningEvent(
      jobId: jobId,
      userId: snapshot.userId,
      sessionId: snapshot.sessionId,
      source: snapshot.source,
    );
    await _recordAll(runningEvent);

    final memorySnapshot = await memory.getSnapshot(scope: snapshot.source);
    final preferenceSnapshot = await preference.getSnapshot(
      userId: snapshot.userId,
    );
    try {
      final result = await execution.run(
        ExecutionRequest(
          jobId: jobId,
          intent: intent,
          context: ExecutionContext(
            userId: snapshot.userId,
            sessionId: snapshot.sessionId,
            source: snapshot.source,
            memory: memorySnapshot,
            preference: preferenceSnapshot,
            toolReporter: (event) {
              unawaited(_recordToolEvent(event, snapshot));
            },
          ),
        ),
      );
      if (result.success) {
        final jobResult = result.result ??
            const JobResult(message: 'Execution completed.');
        jobManager.markDone(jobId, jobResult);
        final doneEvent = JobDoneEvent(
          jobId: jobId,
          userId: snapshot.userId,
          sessionId: snapshot.sessionId,
          source: snapshot.source,
          result: jobResult,
        );
        await _recordAll(doneEvent);
        return;
      }
      final reason = result.error ?? 'Execution failed.';
      jobManager.markFailed(jobId, reason);
      final failedEvent = JobFailedEvent(
        jobId: jobId,
        userId: snapshot.userId,
        sessionId: snapshot.sessionId,
        source: snapshot.source,
        reason: reason,
      );
      await _recordAll(failedEvent);
    } catch (error) {
      final reason = 'Execution threw: $error';
      jobManager.markFailed(jobId, reason);
      final failedEvent = JobFailedEvent(
        jobId: jobId,
        userId: snapshot.userId,
        sessionId: snapshot.sessionId,
        source: snapshot.source,
        reason: reason,
      );
      await _recordAll(failedEvent);
    }
  }

  Future<void> _recordAll(KernelEvent event) async {
    final advice = supervision.observe(event);
    logger?.log(event, data: _eventData(event));
    await _recordMemory(event);
    if (advice != null) {
      await _recordSupervision(event, advice);
    }
    await _recordPreference(event);
    await _recordLearning(event);
  }

  Map<String, dynamic>? _eventData(KernelEvent event) {
    if (event is PerceptReadyEvent) {
      return {
        'confidence': event.percept.confidence,
        'candidates': event.percept.candidates
            .map(
              (candidate) => {
            'action': candidate.action,
            'target': candidate.target,
            'confidence': candidate.confidence,
          },
        )
            .toList(),
      };
    }
    if (event is PlanReadyEvent) {
      return {
        'decision': event.planResult.decision.name,
        'reason': event.planResult.reason,
        'intent': _intentData(event.planResult.intent),
      };
    }
    if (event is JobNeedsConfirmationEvent) {
      return {
        'prompt': event.confirmation.prompt,
        'intent': _intentData(event.intent),
      };
    }
    if (event is JobQueuedEvent) {
      return {
        'intent': _intentData(event.intent),
      };
    }
    if (event is JobDoneEvent) {
      return {
        'message': event.result.message,
        'data': event.result.data,
      };
    }
    if (event is JobFailedEvent) {
      return {'reason': event.reason};
    }
    if (event is JobCancelledEvent) {
      return {'reason': event.reason};
    }
    if (event is ToolCallStartedEvent) {
      return {
        'toolId': event.toolId,
        'function': event.function,
        'arguments': event.arguments,
        'startedAt': event.startedAt.toIso8601String(),
      };
    }
    if (event is ToolCallDoneEvent) {
      return {
        'toolId': event.toolId,
        'function': event.function,
        'result': event.result,
        'startedAt': event.startedAt.toIso8601String(),
        'completedAt': event.completedAt.toIso8601String(),
        'durationMs':
            event.completedAt.difference(event.startedAt).inMilliseconds,
      };
    }
    if (event is ToolCallFailedEvent) {
      return {
        'toolId': event.toolId,
        'function': event.function,
        'error': event.error,
        'startedAt': event.startedAt.toIso8601String(),
        'completedAt': event.completedAt.toIso8601String(),
        'durationMs':
            event.completedAt.difference(event.startedAt).inMilliseconds,
      };
    }
    return null;
  }

  Map<String, dynamic>? _intentData(Intent? intent) {
    if (intent == null) {
      return null;
    }
    return {
      'action': intent.action,
      'target': intent.target,
      'params': intent.params,
      'confidence': intent.confidence,
    };
  }

  Future<void> _recordMemory(KernelEvent event) async {
    try {
      await memory.record(
        MemoryRecord(
          jobId: event.jobId,
          userId: event.userId,
          sessionId: event.sessionId,
          scope: event.source,
          type: event.type,
          data: _eventData(event),
          timestamp: DateTime.now(),
        ),
      );
    } catch (error) {
      logger?.error('Failed to record memory.', error);
    }
  }

  Future<void> _recordSupervision(
      KernelEvent event,
      SupervisionAdvice advice,
      ) async {
    try {
      await memory.record(
        MemoryRecord(
          jobId: event.jobId,
          userId: event.userId,
          sessionId: event.sessionId,
          scope: event.source,
          type: 'SUPERVISION_ADVICE',
          data: {
            'message': advice.message,
            'requiresIntervention': advice.requiresIntervention,
            'metadata': advice.metadata,
          },
          timestamp: DateTime.now(),
        ),
      );
    } catch (error) {
      logger?.error('Failed to record supervision advice.', error);
    }
  }

  Future<void> _recordLearning(KernelEvent event) async {
    try {
      await learning.consume(
        LearningRecord(
          jobId: event.jobId,
          userId: event.userId,
          type: event.type,
          data: _eventData(event),
          timestamp: DateTime.now(),
        ),
      );
    } catch (error) {
      logger?.error('Failed to record learning.', error);
    }
  }

  Future<void> _recordPreference(KernelEvent event) async {
    if (event is! JobDoneEvent) {
      return;
    }
    final userId = event.userId;
    if (userId == null) {
      return;
    }
    final data = event.result.data;
    if (data == null) {
      return;
    }
    try {
      final signalMap = data['preferenceSignal'];
      if (signalMap is Map) {
        final text = signalMap['text'];
        if (text is String && text.isNotEmpty) {
          await preference.recordSignal(
            PreferenceSignal(
              userId: userId,
              text: text,
              metadata: signalMap['metadata'] as Map<String, dynamic>?,
            ),
          );
        }
        return;
      }
      final text = data['preferenceText'];
      if (text is String && text.isNotEmpty) {
          await preference.recordSignal(
            PreferenceSignal(
              userId: userId,
              text: text,
              metadata: {
                'jobId': event.jobId,
              },
            ),
          );
      }
    } catch (error) {
      logger?.error('Failed to record preference signal.', error);
    }
  }

  Future<void> _recordToolEvent(
    ToolCallEvent event,
    JobSnapshot snapshot,
  ) async {
    final startedAt = event.startedAt;
    final completedAt = event.completedAt ?? DateTime.now();
    KernelEvent kernelEvent;
    switch (event.status) {
      case ToolCallStatus.started:
        kernelEvent = ToolCallStartedEvent(
          jobId: event.jobId,
          userId: snapshot.userId,
          sessionId: snapshot.sessionId,
          source: snapshot.source,
          toolId: event.toolId,
          function: event.function,
          arguments: event.arguments,
          startedAt: startedAt,
        );
        break;
      case ToolCallStatus.done:
        kernelEvent = ToolCallDoneEvent(
          jobId: event.jobId,
          userId: snapshot.userId,
          sessionId: snapshot.sessionId,
          source: snapshot.source,
          toolId: event.toolId,
          function: event.function,
          result: event.result,
          startedAt: startedAt,
          completedAt: completedAt,
        );
        break;
      case ToolCallStatus.failed:
        kernelEvent = ToolCallFailedEvent(
          jobId: event.jobId,
          userId: snapshot.userId,
          sessionId: snapshot.sessionId,
          source: snapshot.source,
          toolId: event.toolId,
          function: event.function,
          error: event.error ?? 'Unknown tool error.',
          startedAt: startedAt,
          completedAt: completedAt,
        );
        break;
    }
    await _recordAll(kernelEvent);
    if (toolCallStore != null) {
      try {
        await toolCallStore!.record(
          ToolCallRecord.fromEvent(
            event: event,
            source: snapshot.source,
            userId: snapshot.userId,
            sessionId: snapshot.sessionId,
          ),
        );
      } catch (error) {
        logger?.error('Failed to record tool call.', error);
      }
    }
  }
}
