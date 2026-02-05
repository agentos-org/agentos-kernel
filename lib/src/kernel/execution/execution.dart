import '../execution/execution_agent.dart';
import '../execution/open_tool_directory.dart';
import '../job_manager.dart';
import 'model.dart';

abstract class Execution {
  Future<ExecutionResult> run(ExecutionRequest request);
}

class OpenToolExecution implements Execution {
  final OpenToolDirectory openToolDirectory;
  final ExecutionAgentRunner? executionAgentRunner;

  OpenToolExecution({
    required this.openToolDirectory,
    this.executionAgentRunner,
  });

  @override
  Future<ExecutionResult> run(ExecutionRequest request) async {
    final action = request.intent.action;
    if (action == 'open_tool') {
      final params = request.intent.params ?? const {};
      final toolId = params['toolId'];
      final functionName = params['function'];
      final arguments = params['arguments'];
      if (toolId is! String || functionName is! String) {
        return ExecutionResult.fail('Missing toolId or function for open_tool.');
      }
      final args = arguments is Map<String, dynamic>
          ? arguments
          : <String, dynamic>{};
      final reporter = request.context.toolReporter;
      final startedAt = DateTime.now();
      reporter?.call(
        ToolCallEvent(
          status: ToolCallStatus.started,
          jobId: request.jobId,
          toolId: toolId,
          function: functionName,
          arguments: args,
          startedAt: startedAt,
        ),
      );
      try {
        final toolReturn = await openToolDirectory.call(
          toolId: toolId,
          function: functionName,
          arguments: args,
          callId: request.jobId,
        );
        reporter?.call(
          ToolCallEvent(
            status: ToolCallStatus.done,
            jobId: request.jobId,
            toolId: toolId,
            function: functionName,
            arguments: args,
            result: toolReturn.result,
            startedAt: startedAt,
            completedAt: DateTime.now(),
          ),
        );
        return ExecutionResult.ok(
          result: JobResult(
            data: toolReturn.result,
            message: 'OpenTool executed.',
          ),
        );
      } catch (error) {
        reporter?.call(
          ToolCallEvent(
            status: ToolCallStatus.failed,
            jobId: request.jobId,
            toolId: toolId,
            function: functionName,
            arguments: args,
            error: error.toString(),
            startedAt: startedAt,
            completedAt: DateTime.now(),
          ),
        );
        return ExecutionResult.fail('OpenTool call failed: $error');
      }
    }
    if (action == 'execution_agent') {
      final runner = executionAgentRunner;
      if (runner == null) {
        return ExecutionResult.fail('Execution agent runner not configured.');
      }
      return runner.run(request);
    }
    return ExecutionResult.fail('Unknown action: $action');
  }
}
