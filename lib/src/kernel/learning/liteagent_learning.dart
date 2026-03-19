import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
import '../agent/model.dart';
import '../content/content_normalizer.dart';
import '../preference/model.dart';
import '../preference/preference.dart';
import 'learning.dart';
import 'model.dart';

class LiteAgentLearning implements Learning {
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final Preference preference;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final String systemPrompt;

  LiteAgentLearning({
    required this.llmQueue,
    required this.client,
    required this.preference,
    required this.llmConfig,
    required this.systemPrompt,
    this.llmConfigResolver,
  });

  @override
  Future<void> consume(LearningRecord record) async {
    if (record.userId == null || record.userId!.trim().isEmpty) {
      return;
    }
    final effectiveConfig = normalizeLlmConfigForLiteAgent(
      llmConfigResolver?.call() ?? llmConfig,
    );
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    final taskContent = _buildTaskContent(record, effectiveConfig);
    try {
      final signal = await llmQueue.enqueue(
        purpose: 'learning',
        priority: 5,
        weight: 1,
        modelKey: modelKey,
        jobId: record.jobId,
        run: (context) async {
          final sdk = client.sdk;
          final capability = Capability(
            llmConfig: effectiveConfig,
            systemPrompt: systemPrompt,
            callbackOpenTool: CallbackOpenTool(
              opentool: _learningToolSpecJson(),
            ),
          );
          final session = await sdk.initSession(capability: capability);
          final task = UserTask(content: taskContent, isChunk: true);
          final completer = Completer<PreferenceSignal?>();
          final handler = _LearningToolHandler(
            record: record,
            onFirstToken: context.markFirstToken,
            onMessageCallback: (message) => _recordTokenUsage(message, context),
            onSignal: (signal) {
              if (!completer.isCompleted) {
                completer.complete(signal);
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
      if (signal == null) {
        return;
      }
      await preference.recordSignal(signal);
    } catch (_) {
      return;
    }
  }

  List<Content> _buildTaskContent(LearningRecord record, LLMConfig llmConfig) {
    final normalizedData = normalizeStructuredDataForModel(
      record.data,
      llmConfig,
    );
    final content = contentFromStructuredData(record.data, llmConfig);
    final extraData = omitStructuredContent(normalizedData);
    final intro = StringBuffer();
    intro.writeln('You extract user preference signals.');
    intro.writeln('Call emit_preference with text/metadata.');
    intro.writeln('If no preference signal, call reject_preference.');
    intro.writeln('Event type: ${record.type}');
    final taskContent = <Content>[
      Content(type: ContentType.text, message: intro.toString()),
    ];
    if (content.isNotEmpty) {
      taskContent.addAll(content);
    }
    if (extraData != null && extraData.isNotEmpty) {
      taskContent.add(
        Content(
          type: ContentType.text,
          message: 'Event data: ${jsonEncode(extraData)}',
        ),
      );
    } else if (content.isEmpty &&
        normalizedData != null &&
        normalizedData.isNotEmpty) {
      taskContent.add(
        Content(
          type: ContentType.text,
          message: 'Event data: ${jsonEncode(normalizedData)}',
        ),
      );
    }
    return taskContent;
  }

  String _learningToolSpecJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Learning Tools',
        'description': 'Emit preference signals for learning.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'emit_preference',
          'description': 'Emit a preference signal for the user.',
          'parameters': [
            {
              'name': 'text',
              'description': 'Preference text to store.',
              'required': true,
              'schema': {'type': 'string'},
            },
            {
              'name': 'metadata',
              'description': 'Optional metadata payload.',
              'required': false,
              'schema': {'type': 'object', 'properties': {}},
            },
          ],
        },
        {
          'name': 'reject_preference',
          'description': 'Reject emitting a preference signal.',
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

class _LearningToolHandler extends AgentMessageHandler {
  final LearningRecord record;
  final void Function() onFirstToken;
  final void Function(AgentMessage message) onMessageCallback;
  final void Function(PreferenceSignal? signal) onSignal;
  final void Function() onDoneCallback;

  _LearningToolHandler({
    required this.record,
    required this.onFirstToken,
    required this.onMessageCallback,
    required this.onSignal,
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
      case 'emit_preference':
        final signal = _buildSignal(args);
        if (signal != null) {
          onSignal(signal);
          return ToolReturn(
            id: functionCall.id,
            result: {'status': 'accepted'},
          );
        }
        return ToolReturn(
          id: functionCall.id,
          result: {'status': 'error', 'message': 'Invalid preference payload.'},
        );
      case 'reject_preference':
        onSignal(null);
        return ToolReturn(id: functionCall.id, result: {'status': 'accepted'});
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

  PreferenceSignal? _buildSignal(Map<String, dynamic> args) {
    final text = args['text'];
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    final metadata = args['metadata'];
    return PreferenceSignal(
      userId: record.userId ?? 'unknown',
      text: text,
      metadata: metadata is Map<String, dynamic> ? metadata : null,
    );
  }
}
