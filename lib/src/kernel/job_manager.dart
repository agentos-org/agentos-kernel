import 'perception/model.dart';

enum JobStatus {
  CREATED,
  NEEDS_CONFIRMATION,
  QUEUED,
  RUNNING,
  DONE,
  FAILED,
  CANCELLED,
}

class JobPrompt {
  final String message;
  final List<String> fields;
  final List<String> choices;

  const JobPrompt({
    required this.message,
    this.fields = const [],
    this.choices = const [],
  });
}

class JobHandle {
  final String jobId;
  final JobStatus status;

  const JobHandle({
    required this.jobId,
    required this.status,
  });
}

class JobResult {
  final Map<String, dynamic>? data;
  final String? message;

  const JobResult({
    this.data,
    this.message,
  });
}

class JobSnapshot {
  final String jobId;
  final String source;
  final String? userId;
  final String? sessionId;
  final JobStatus status;
  final JobResult? result;
  final String? failureReason;
  final JobPrompt? prompt;
  final Intent? pendingIntent;
  final DateTime createdAt;
  final DateTime updatedAt;

  const JobSnapshot({
    required this.jobId,
    required this.source,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.userId,
    this.sessionId,
    this.result,
    this.failureReason,
    this.prompt,
    this.pendingIntent,
  });
}

abstract class JobManager {
  JobHandle createJob({
    required String source,
    String? userId,
    String? sessionId,
  });

  JobHandle markQueued(String jobId);
  JobHandle markRunning(String jobId);
  JobHandle markDone(String jobId, JobResult result);
  JobHandle markFailed(String jobId, String reason);
  JobHandle markNeedsConfirmation(
    String jobId,
    JobPrompt prompt,
    Intent intent,
  );

  JobHandle cancel(String jobId, {String? reason});

  JobHandle getHandle(String jobId);
  JobStatus getStatus(String jobId);
  JobSnapshot getSnapshot(String jobId);
}

class InMemoryJobManager implements JobManager {
  final Map<String, _JobState> _jobs = {};
  int _counter = 0;

  @override
  JobHandle createJob({
    required String source,
    String? userId,
    String? sessionId,
  }) {
    final jobId = 'job-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    _jobs[jobId] = _JobState(
      status: JobStatus.CREATED,
      source: source,
      userId: userId,
      sessionId: sessionId,
    );
    return JobHandle(
      jobId: jobId,
      status: JobStatus.CREATED,
    );
  }

  @override
  JobHandle markQueued(String jobId) {
    return _transition(jobId, JobStatus.QUEUED);
  }

  @override
  JobHandle markRunning(String jobId) {
    return _transition(jobId, JobStatus.RUNNING);
  }

  @override
  JobHandle markDone(String jobId, JobResult result) {
    return _transition(jobId, JobStatus.DONE, result: result);
  }

  @override
  JobHandle markFailed(String jobId, String reason) {
    return _transition(jobId, JobStatus.FAILED, failureReason: reason);
  }

  @override
  JobHandle markNeedsConfirmation(
    String jobId,
    JobPrompt prompt,
    Intent intent,
  ) {
    return _transition(
      jobId,
      JobStatus.NEEDS_CONFIRMATION,
      prompt: prompt,
      pendingIntent: intent,
    );
  }

  @override
  JobHandle cancel(String jobId, {String? reason}) {
    return _transition(
      jobId,
      JobStatus.CANCELLED,
      failureReason: reason,
    );
  }

  @override
  JobHandle getHandle(String jobId) {
    final state = _jobs[jobId];
    if (state == null) {
      throw StateError('Unknown jobId: $jobId');
    }
    return JobHandle(
      jobId: jobId,
      status: state.status,
    );
  }

  @override
  JobStatus getStatus(String jobId) {
    return getHandle(jobId).status;
  }

  @override
  JobSnapshot getSnapshot(String jobId) {
    final state = _jobs[jobId];
    if (state == null) {
      throw StateError('Unknown jobId: $jobId');
    }
    return JobSnapshot(
      jobId: jobId,
      source: state.source,
      userId: state.userId,
      sessionId: state.sessionId,
      status: state.status,
      result: state.result,
      failureReason: state.failureReason,
      prompt: state.prompt,
      pendingIntent: state.pendingIntent,
      createdAt: state.createdAt,
      updatedAt: state.updatedAt,
    );
  }

  JobHandle _transition(
    String jobId,
    JobStatus target, {
    JobResult? result,
    String? failureReason,
    JobPrompt? prompt,
    Intent? pendingIntent,
  }) {
    final state = _jobs[jobId];
    if (state == null) {
      throw StateError('Unknown jobId: $jobId');
    }
    if (!_isLegalTransition(state.status, target)) {
      return JobHandle(
        jobId: jobId,
        status: state.status,
      );
    }
    state.status = target;
    state.result = result ?? state.result;
    state.failureReason = failureReason ?? state.failureReason;
    state.prompt = prompt ?? state.prompt;
    state.pendingIntent = pendingIntent ?? state.pendingIntent;
    if (target == JobStatus.QUEUED ||
        target == JobStatus.RUNNING ||
        target == JobStatus.DONE ||
        target == JobStatus.FAILED ||
        target == JobStatus.CANCELLED) {
      state.prompt = null;
      state.pendingIntent = null;
    }
    state.updatedAt = DateTime.now();
    return JobHandle(
      jobId: jobId,
      status: target,
    );
  }

  bool _isLegalTransition(JobStatus from, JobStatus to) {
    if (from == to) {
      return true;
    }
    switch (from) {
      case JobStatus.CREATED:
        return to == JobStatus.NEEDS_CONFIRMATION ||
            to == JobStatus.QUEUED ||
            to == JobStatus.FAILED ||
            to == JobStatus.CANCELLED;
      case JobStatus.NEEDS_CONFIRMATION:
        return to == JobStatus.QUEUED ||
            to == JobStatus.FAILED ||
            to == JobStatus.CANCELLED;
      case JobStatus.QUEUED:
        return to == JobStatus.RUNNING ||
            to == JobStatus.DONE ||
            to == JobStatus.FAILED ||
            to == JobStatus.CANCELLED;
      case JobStatus.RUNNING:
        return to == JobStatus.DONE ||
            to == JobStatus.FAILED ||
            to == JobStatus.CANCELLED;
      case JobStatus.DONE:
      case JobStatus.FAILED:
      case JobStatus.CANCELLED:
        return false;
    }
  }
}

class _JobState {
  JobStatus status;
  final String source;
  final String? userId;
  final String? sessionId;
  JobResult? result;
  String? failureReason;
  JobPrompt? prompt;
  Intent? pendingIntent;
  final DateTime createdAt;
  DateTime updatedAt;

  _JobState({
    required this.status,
    required this.source,
    this.userId,
    this.sessionId,
  })  : createdAt = DateTime.now(),
        updatedAt = DateTime.now();
}
