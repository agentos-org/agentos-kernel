import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../kernel.dart';
import '../agent/llm_queue.dart';
import '../agent/config.dart';
import '../agent/model.dart';
import '../logging/logger.dart';
import '../perception/input.dart';
import '../job_manager.dart';

class PerceptionAgentRunner {
  final Kernel kernel;
  final LlmQueue llmQueue;
  final LiteAgentSDK liteAgentSdk;
  final LLMConfig llmConfig;
  final String systemPrompt;
  final KernelLogger? logger;
  final String? openToolJson;

  final Map<String, Session> _sessions = {};
  final Map<String, _PerceptionContext> _contexts = {};

  PerceptionAgentRunner({
    required this.kernel,
    required this.llmQueue,
    required this.liteAgentSdk,
    required this.llmConfig,
    required this.systemPrompt,
    this.logger,
    this.openToolJson,
  });

  JobHandle submitRaw({
    required String source,
    required List<Content> content,
    Map<String, dynamic>? data,
    String? userId,
    String? sessionId,
    String? jobId,
  }) {
    final handle = _ensureJob(
      source: source,
      userId: userId,
      sessionId: sessionId,
      jobId: jobId,
    );
    final effectiveSessionId = sessionId ?? handle.jobId;
    final context = _PerceptionContext(
      jobId: handle.jobId,
      userId: userId,
      sessionId: effectiveSessionId,
      source: source,
      content: content,
      data: data,
    );
    _contexts[effectiveSessionId] = context;
    unawaited(_sendToAgent(context));
    return handle;
  }

  Future<void> _sendToAgent(_PerceptionContext context) async {
    final effectiveConfig = normalizeLlmConfigForLiteAgent(llmConfig);
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    await llmQueue.enqueue(
      purpose: 'perception_chat',
      priority: 0,
      weight: 10,
      modelKey: modelKey,
      jobId: context.jobId,
      userId: context.userId,
      run: (callContext) async {
        final session = await _getOrCreateSession(context.sessionId);
        final task = UserTask(content: context.content, isChunk: true);
        final handler = _PerceptionAgentHandler(
          context: context,
          kernel: kernel,
          onFirstToken: callContext.markFirstToken,
          onMessageCallback: (message) =>
              _recordTokenUsage(message, callContext),
          logger: logger,
        );
        await liteAgentSdk.chat(session, task, handler);
        return null;
      },
    );
  }

  JobHandle _ensureJob({
    required String source,
    String? userId,
    String? sessionId,
    String? jobId,
  }) {
    if (jobId != null) {
      return kernel.jobManager.getHandle(jobId);
    }
    return kernel.jobManager.createJob(
      source: source,
      userId: userId,
      sessionId: sessionId,
    );
  }

  Future<Session> _getOrCreateSession(String sessionId) async {
    final existing = _sessions[sessionId];
    if (existing != null) {
      return existing;
    }
    final effectiveConfig = normalizeLlmConfigForLiteAgent(llmConfig);
    final capability = Capability(
      llmConfig: effectiveConfig,
      systemPrompt: systemPrompt,
      callbackOpenTool: CallbackOpenTool(
        opentool: openToolJson ?? _defaultOpenToolJson(),
      ),
    );
    final session = await liteAgentSdk.initSession(capability: capability);
    _sessions[sessionId] = session;
    return session;
  }

  String _defaultOpenToolJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Intent Tool',
        'description': 'Submit confirmed intent to kernel planning.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'submit_intent',
          'description': 'Submit a confirmed intent (action + payload).',
          'parameters': [
            {
              'name': 'action',
              'description': 'Intent action name.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'payload',
              'description': 'Intent payload object.',
              'required': true,
              'schema': {
                'type': 'object',
                'properties': {},
              },
            },
            {
              'name': 'confidence',
              'description': 'Confidence score 0-1.',
              'required': false,
              'schema': {'type': 'number'},
            },
            {
              'name': 'reason',
              'description': 'Short explanation for the intent.',
              'required': false,
              'schema': {'type': 'string'},
            },
          ],
        },
      ],
    };
    return jsonEncode(spec);
  }
}

class _PerceptionContext {
  final String jobId;
  final String? userId;
  final String sessionId;
  final String source;
  final List<Content> content;
  final Map<String, dynamic>? data;

  _PerceptionContext({
    required this.jobId,
    required this.userId,
    required this.sessionId,
    required this.source,
    required this.content,
    this.data,
  });
}

void _recordTokenUsage(AgentMessage message, LlmCallContext context) {
  final usage = message.completions?.usage;
  if (usage == null) {
    return;
  }
  context.setTotalTokens(usage.totalTokens);
  final contextUsageRatio = usage.contextUsageRatio;
  if (contextUsageRatio != null) {
    context.setContextUsageRatio(contextUsageRatio.toDouble());
  }
}

class _PerceptionAgentHandler extends AgentMessageHandler {
  final _PerceptionContext context;
  final Kernel kernel;
  final void Function() onFirstToken;
  final void Function(AgentMessage message) onMessageCallback;
  final KernelLogger? logger;

  _PerceptionAgentHandler({
    required this.context,
    required this.kernel,
    required this.onFirstToken,
    required this.onMessageCallback,
    this.logger,
  });

  @override
  Future<ToolReturn> onFunctionCall(
    String sessionId,
    FunctionCall functionCall,
  ) async {
    onFirstToken();
    if (functionCall.name != 'submit_intent') {
      return ToolReturn(
        id: functionCall.id,
        result: {'status': 'ignored', 'message': 'Unknown function.'},
      );
    }
    final args = Map<String, dynamic>.from(functionCall.arguments);
    final action = args['action'];
    final payload = args['payload'];
    if (action is! String || payload is! Map<String, dynamic>) {
      return ToolReturn(
        id: functionCall.id,
        result: {'status': 'error', 'message': 'Invalid intent payload.'},
      );
    }
    final target = payload['target'];
    final mergedParams = <String, dynamic>{};
    mergedParams.addAll(payload);
    final extra = context.data;
    if (extra != null && extra.isNotEmpty) {
      extra.forEach((key, value) {
        if (!mergedParams.containsKey(key)) {
          mergedParams[key] = value;
        }
      });
    }
    final rawInput = RawInput(
      jobId: context.jobId,
      userId: context.userId,
      sessionId: context.sessionId,
      source: context.source,
      data: {
        'action': action,
        if (target is String) 'target': target,
        'params': mergedParams,
      },
    );
    kernel.input(rawInput);
    return ToolReturn(
      id: functionCall.id,
      result: {
        'status': 'accepted',
        'jobId': context.jobId,
        'message': 'Intent accepted, planning started.',
      },
    );
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
  Future<void> onDone() async {}

  @override
  Future<void> onError(Exception e) async {
    logger?.error('Perception agent error.', e);
  }
}
