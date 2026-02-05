import '../memory/model.dart';
import '../perception/model.dart';
import '../preference/model.dart';
import '../job_manager.dart';

class ExecutionRequest {
  final String jobId;
  final Intent intent;
  final ExecutionContext context;

  const ExecutionRequest({
    required this.jobId,
    required this.intent,
    required this.context,
  });
}

class ExecutionContext {
  final String? userId;
  final String? sessionId;
  final String? source;
  final MemorySnapshot memory;
  final PreferenceSnapshot preference;
  final Map<String, dynamic>? metadata;
  final ToolCallReporter? toolReporter;

  const ExecutionContext({
    this.userId,
    this.sessionId,
    this.source,
    required this.memory,
    required this.preference,
    this.metadata,
    this.toolReporter,
  });
}

class ExecutionFeedback {
  final String jobId;
  final Map<String, dynamic>? data;
  final String? message;

  const ExecutionFeedback({
    required this.jobId,
    this.data,
    this.message,
  });
}

class ExecutionResult {
  final bool success;
  final JobResult? result;
  final String? error;

  const ExecutionResult({
    required this.success,
    this.result,
    this.error,
  });

  factory ExecutionResult.ok({JobResult? result}) {
    return ExecutionResult(success: true, result: result);
  }

  factory ExecutionResult.fail(String error) {
    return ExecutionResult(success: false, error: error);
  }
}

enum ToolCallStatus {
  started,
  done,
  failed,
}

class ToolCallEvent {
  final ToolCallStatus status;
  final String jobId;
  final String toolId;
  final String function;
  final Map<String, dynamic>? arguments;
  final Map<String, dynamic>? result;
  final String? error;
  final DateTime startedAt;
  final DateTime? completedAt;

  const ToolCallEvent({
    required this.status,
    required this.jobId,
    required this.toolId,
    required this.function,
    this.arguments,
    this.result,
    this.error,
    required this.startedAt,
    this.completedAt,
  });

  Duration? get duration {
    if (completedAt == null) {
      return null;
    }
    return completedAt!.difference(startedAt);
  }
}

typedef ToolCallReporter = void Function(ToolCallEvent event);
