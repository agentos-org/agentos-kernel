import 'package:hive/hive.dart';

import 'perception/model.dart';
import 'job_manager.dart';

class HiveJobManager implements JobManager {
  final InMemoryJobManager _inner;
  final Box<Map> _box;

  HiveJobManager({
    required Box<Map> box,
    InMemoryJobManager? inner,
  })  : _box = box,
        _inner = inner ?? InMemoryJobManager();

  @override
  JobHandle createJob({
    required String source,
    String? userId,
    String? sessionId,
  }) {
    final handle = _inner.createJob(
      source: source,
      userId: userId,
      sessionId: sessionId,
    );
    _persist(handle.jobId);
    return handle;
  }

  @override
  JobHandle markQueued(String jobId) {
    final handle = _inner.markQueued(jobId);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle markRunning(String jobId) {
    final handle = _inner.markRunning(jobId);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle markDone(String jobId, JobResult result) {
    final handle = _inner.markDone(jobId, result);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle markFailed(String jobId, String reason) {
    final handle = _inner.markFailed(jobId, reason);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle markNeedsConfirmation(
    String jobId,
    JobPrompt prompt,
    Intent intent,
  ) {
    final handle = _inner.markNeedsConfirmation(jobId, prompt, intent);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle cancel(String jobId, {String? reason}) {
    final handle = _inner.cancel(jobId, reason: reason);
    _persist(jobId);
    return handle;
  }

  @override
  JobHandle getHandle(String jobId) => _inner.getHandle(jobId);

  @override
  JobStatus getStatus(String jobId) => _inner.getStatus(jobId);

  @override
  JobSnapshot getSnapshot(String jobId) => _inner.getSnapshot(jobId);

  void _persist(String jobId) {
    final snapshot = _inner.getSnapshot(jobId);
    _box.put(jobId, _snapshotToMap(snapshot));
  }

  Map<String, dynamic> _snapshotToMap(JobSnapshot snapshot) {
    return {
      'jobId': snapshot.jobId,
      'source': snapshot.source,
      'userId': snapshot.userId,
      'sessionId': snapshot.sessionId,
      'status': snapshot.status.name,
      'result': _resultToMap(snapshot.result),
      'failureReason': snapshot.failureReason,
      'prompt': _promptToMap(snapshot.prompt),
      'pendingIntent': _intentToMap(snapshot.pendingIntent),
      'createdAt': snapshot.createdAt,
      'updatedAt': snapshot.updatedAt,
    };
  }

  Map<String, dynamic>? _resultToMap(JobResult? result) {
    if (result == null) {
      return null;
    }
    return {
      'data': result.data,
      'message': result.message,
    };
  }

  Map<String, dynamic>? _promptToMap(JobPrompt? prompt) {
    if (prompt == null) {
      return null;
    }
    return {
      'message': prompt.message,
      'fields': prompt.fields,
      'choices': prompt.choices,
    };
  }

  Map<String, dynamic>? _intentToMap(Intent? intent) {
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
}
