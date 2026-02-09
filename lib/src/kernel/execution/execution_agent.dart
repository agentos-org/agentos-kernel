import 'dart:async';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../job_manager.dart';
import '../agent/llm_queue.dart';
import '../agent/model.dart';
import 'model.dart';
import 'open_tool_directory.dart';

class ExecutionAgentTemplate {
  final String id;
  final String name;
  final String? description;
  final Capability capability;
  final OpenToolDirectory? openToolDirectory;

  const ExecutionAgentTemplate({
    required this.id,
    required this.name,
    required this.capability,
    this.description,
    this.openToolDirectory,
  });
}

class ExecutionAgentRegistry {
  final Map<String, ExecutionAgentTemplate> _byId;

  ExecutionAgentRegistry(List<ExecutionAgentTemplate> templates)
    : _byId = {for (final template in templates) template.id: template};

  ExecutionAgentTemplate? byId(String id) => _byId[id];

  List<Map<String, dynamic>> summaries() {
    return _byId.values
        .map(
          (template) => {
            'id': template.id,
            'name': template.name,
            'description': template.description,
          },
        )
        .toList();
  }
}

class ExecutionAgentRunner {
  final LiteAgentSDK liteAgentSdk;
  final LlmQueue llmQueue;
  final ExecutionAgentRegistry registry;
  final LLMConfig? Function()? getAvailableLlmConfig;

  ExecutionAgentRunner({
    required this.liteAgentSdk,
    required this.llmQueue,
    required this.registry,
    this.getAvailableLlmConfig,
  });

  Future<ExecutionResult> run(ExecutionRequest request) async {
    final params = request.intent.params ?? const {};
    final agentId = params['agentId'] ?? params['agent_id'];
    if (agentId is! String || agentId.isEmpty) {
      return ExecutionResult.fail('Missing agentId for execution_agent.');
    }
    final template = registry.byId(agentId);
    if (template == null) {
      return ExecutionResult.fail('Unknown agentId: $agentId');
    }
    final content = _parseContent(params);
    if (content.isEmpty) {
      return ExecutionResult.fail('Missing content for execution_agent.');
    }
    final llmConfig =
        template.capability.llmConfig ?? getAvailableLlmConfig?.call();
    if (llmConfig == null) {
      return ExecutionResult.fail(
        'LLM config is required for execution_agent (agentId: $agentId).',
      );
    }
    final modelKey = buildLlmModelKey(
      baseUrl: llmConfig.baseUrl,
      model: llmConfig.model,
      apiKey: llmConfig.apiKey,
    );
    return llmQueue.enqueue(
      purpose: 'execution_agent',
      priority: 0,
      weight: 10,
      modelKey: modelKey,
      jobId: request.jobId,
      userId: request.context.userId,
      run: (context) async {
        final session = await liteAgentSdk.initSession(
          capability: template.capability,
        );
        final task = UserTask(content: content, isChunk: true);
        final completer = Completer<ExecutionResult>();
        AgentMessage? lastMessage;
        final handler = _ExecutionAgentHandler(
          onFirstToken: context.markFirstToken,
          template: template,
          toolReporter: request.context.toolReporter,
          jobId: request.jobId,
          onMessageCallback: (message) {
            lastMessage = message;
          },
          onErrorCallback: (error) {
            if (!completer.isCompleted) {
              completer.complete(
                ExecutionResult.fail('Execution agent error: $error'),
              );
            }
          },
          onDoneCallback: () {
            if (completer.isCompleted) {
              return;
            }
            if (lastMessage == null) {
              completer.complete(
                ExecutionResult.fail('Execution agent returned no message.'),
              );
              return;
            }
            final text = _messageToText(lastMessage!);
            completer.complete(
              ExecutionResult.ok(
                result: JobResult(
                  message: 'Execution agent completed.',
                  data: {'output': text},
                ),
              ),
            );
          },
        );
        await liteAgentSdk.chat(session, task, handler);
        return completer.future;
      },
    );
  }

  List<Content> _parseContent(Map<String, dynamic> params) {
    final raw = params['content'] ?? params['task'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => Content.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }
    final text = params['text'];
    if (text is String && text.trim().isNotEmpty) {
      return [Content(type: ContentType.text, message: text)];
    }
    return [];
  }

  String _messageToText(AgentMessage message) {
    final content = message.content;
    if (content is String) {
      return content;
    }
    return content.toString();
  }
}

class _ExecutionAgentHandler extends AgentMessageHandler {
  final void Function() onFirstToken;
  final ExecutionAgentTemplate template;
  final ToolCallReporter? toolReporter;
  final String jobId;
  final void Function(AgentMessage message) onMessageCallback;
  final void Function(Object error) onErrorCallback;
  final void Function() onDoneCallback;

  _ExecutionAgentHandler({
    required this.onFirstToken,
    required this.template,
    required this.toolReporter,
    required this.jobId,
    required this.onMessageCallback,
    required this.onErrorCallback,
    required this.onDoneCallback,
  });

  @override
  Future<ToolReturn> onFunctionCall(
    String sessionId,
    FunctionCall functionCall,
  ) async {
    onFirstToken();
    final directory = template.openToolDirectory;
    if (directory == null) {
      return ToolReturn(
        id: functionCall.id,
        result: {
          'status': 'error',
          'message': 'No OpenTool directory configured.',
        },
      );
    }
    await directory.ensureLoaded();
    final toolId =
        functionCall.arguments['toolId'] ??
        directory.resolveToolIdForFunction(functionCall.name);
    if (toolId is! String) {
      return ToolReturn(
        id: functionCall.id,
        result: {
          'status': 'error',
          'message': 'Unable to resolve OpenTool for function.',
        },
      );
    }
    final args = Map<String, dynamic>.from(functionCall.arguments);
    final startedAt = DateTime.now();
    toolReporter?.call(
      ToolCallEvent(
        status: ToolCallStatus.started,
        jobId: jobId,
        toolId: toolId,
        function: functionCall.name,
        arguments: args,
        startedAt: startedAt,
      ),
    );
    try {
      final toolReturn = await directory.call(
        toolId: toolId,
        function: functionCall.name,
        arguments: args,
        callId: functionCall.id,
      );
      toolReporter?.call(
        ToolCallEvent(
          status: ToolCallStatus.done,
          jobId: jobId,
          toolId: toolId,
          function: functionCall.name,
          arguments: args,
          result: toolReturn.result,
          startedAt: startedAt,
          completedAt: DateTime.now(),
        ),
      );
      return ToolReturn(id: toolReturn.id, result: toolReturn.result);
    } catch (error) {
      toolReporter?.call(
        ToolCallEvent(
          status: ToolCallStatus.failed,
          jobId: jobId,
          toolId: toolId,
          function: functionCall.name,
          arguments: args,
          error: error.toString(),
          startedAt: startedAt,
          completedAt: DateTime.now(),
        ),
      );
      return ToolReturn(
        id: functionCall.id,
        result: {'status': 'error', 'message': error.toString()},
      );
    }
  }

  @override
  Future<void> onMessage(String sessionId, AgentMessage agentMessage) async {
    onFirstToken();
    onMessageCallback(agentMessage);
  }

  @override
  Future<void> onChunk(
    String sessionId,
    AgentMessageChunk agentMessageChunk,
  ) async {
    onFirstToken();
  }

  @override
  Future<void> onDone() async {
    onDoneCallback();
  }

  @override
  Future<void> onError(Exception e) async {
    onErrorCallback(e);
  }
}
