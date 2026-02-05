import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
import '../agent/model.dart';
import 'input.dart';
import 'model.dart';
import 'perception.dart';

class LiteAgentPerception implements Perception {
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final String systemPrompt;
  final List<String>? actionHints;
  final Perception? fallback;

  LiteAgentPerception({
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    required this.systemPrompt,
    this.llmConfigResolver,
    this.actionHints,
    this.fallback,
  });

  @override
  Future<Percept> process(RawInput input) async {
    final prompt = _buildPrompt(input);
    try {
      final baseConfig = llmConfigResolver?.call() ?? llmConfig;
      final override = _overrideConfig(input, baseConfig);
      final effectiveConfig = override ?? baseConfig;
      final modelKey = buildLlmModelKey(
        baseUrl: effectiveConfig.baseUrl,
        model: effectiveConfig.model,
        apiKey: effectiveConfig.apiKey,
      );
      final candidate = await llmQueue.enqueue(
        purpose: 'perception',
        priority: 0,
        weight: 10,
        modelKey: modelKey,
        jobId: input.jobId,
        userId: input.userId,
        run: (context) async {
          final sdk = LiteAgentSDK(
            baseUrl: client.baseUrl,
            apiKey: client.apiKey,
          );
          final capability = Capability(
            llmConfig: effectiveConfig,
            systemPrompt: systemPrompt,
            callbackOpenTool: CallbackOpenTool(
              opentool: _perceptionToolSpecJson(),
            ),
          );
          final session = await sdk.initSession(capability: capability);
          final task = UserTask(
            content: [
              Content(type: ContentType.text, message: prompt),
            ],
            isChunk: true,
          );
          final completer = Completer<CandidateIntent?>();
          final handler = _PerceptionToolHandler(
            onFirstToken: context.markFirstToken,
            onMessageCallback: (message) => _recordTokenUsage(message, context),
            onCandidate: (candidate) {
              if (!completer.isCompleted) {
                completer.complete(candidate);
              }
            },
            onDoneCallback: () {
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            },
          );
          await sdk.chat(session, task, handler);
          return completer.future;
        },
      );
      if (candidate == null) {
        return await _fallback(input);
      }
      return Percept(
        candidates: [candidate],
        confidence: candidate.confidence,
      );
    } catch (_) {
      return await _fallback(input);
    }
  }

  Future<Percept> _fallback(RawInput input) async {
    if (fallback != null) {
      return await fallback!.process(input);
    }
    return const Percept(
      candidates: [
        CandidateIntent(
          action: 'noop',
          target: null,
          params: null,
          confidence: 0.1,
        ),
      ],
      confidence: 0.1,
    );
  }

  String _buildPrompt(RawInput input) {
    final buffer = StringBuffer();
    buffer.writeln('User input:');
    if (input.text != null) {
      buffer.writeln(input.text);
    }
    if (input.data != null && input.data!.isNotEmpty) {
      buffer.writeln('Structured data: ${jsonEncode(input.data)}');
    }
    if (actionHints != null && actionHints!.isNotEmpty) {
      buffer.writeln('Allowed actions: ${actionHints!.join(', ')}');
    }
    buffer.writeln('Call emit_intent with action/target/params/confidence.');
    buffer.writeln('If no intent should be emitted, call reject_intent.');
    return buffer.toString();
  }

  LLMConfig? _overrideConfig(RawInput input, LLMConfig baseConfig) {
    final data = input.data;
    if (data == null) {
      return null;
    }
    final llm = data['llm'];
    if (llm is! Map) {
      return null;
    }
    final baseUrl = llm['baseUrl'];
    final apiKey = llm['apiKey'];
    final model = llm['model'];
    if (baseUrl is! String || model is! String) {
      return null;
    }
    return LLMConfig(
      baseUrl: baseUrl,
      apiKey: apiKey is String ? apiKey : baseConfig.apiKey,
      model: model,
      contextWindowSize: baseConfig.contextWindowSize,
    );
  }

  String _perceptionToolSpecJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Perception Tools',
        'description': 'Emit intent candidates for kernel perception.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'emit_intent',
          'description': 'Emit a single intent candidate.',
          'parameters': [
            {
              'name': 'action',
              'description': 'Intent action name.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'target',
              'description': 'Intent target (optional).',
              'required': false,
              'schema': {'type': 'string'},
            },
            {
              'name': 'params',
              'description': 'Intent parameters payload.',
              'required': false,
              'schema': {'type': 'object'},
            },
            {
              'name': 'confidence',
              'description': 'Confidence 0-1.',
              'required': false,
              'schema': {'type': 'number'},
            },
          ],
        },
        {
          'name': 'reject_intent',
          'description': 'Reject intent emission when no action applies.',
          'parameters': [
            {
              'name': 'reason',
              'description': 'Reason for rejecting.',
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

class _PerceptionToolHandler extends AgentMessageHandler {
  final void Function() onFirstToken;
  final void Function(AgentMessage message) onMessageCallback;
  final void Function(CandidateIntent? candidate) onCandidate;
  final void Function() onDoneCallback;

  _PerceptionToolHandler({
    required this.onFirstToken,
    required this.onMessageCallback,
    required this.onCandidate,
    required this.onDoneCallback,
  });

  @override
  Future<ToolReturn> onFunctionCall(
    String sessionId,
    FunctionCall functionCall,
  ) async {
    onFirstToken();
    final args = Map<String, dynamic>.from(functionCall.arguments);
    switch (functionCall.name) {
      case 'emit_intent':
        final candidate = _buildCandidate(args);
        if (candidate != null) {
          onCandidate(candidate);
          return ToolReturn(
            id: functionCall.id,
            result: {'status': 'accepted'},
          );
        }
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'error', 'message': 'Invalid intent payload.'},
        );
      case 'reject_intent':
        onCandidate(null);
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'accepted'},
        );
      default:
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'ignored', 'message': 'Unknown function.'},
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
    onDoneCallback();
  }

  CandidateIntent? _buildCandidate(Map<String, dynamic> args) {
    final action = args['action'];
    if (action is! String || action.trim().isEmpty) {
      return null;
    }
    final target = args['target'];
    final params = args['params'];
    final confidence = args['confidence'];
    return CandidateIntent(
      action: action,
      target: target is String ? target : null,
      params: params is Map<String, dynamic> ? params : null,
      confidence: confidence is num
          ? confidence.toDouble().clamp(0.0, 1.0)
          : 0.5,
    );
  }
}
