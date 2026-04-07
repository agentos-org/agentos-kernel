import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:opentool_dart/opentool_client.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
import '../agent/model.dart';
import 'model.dart';
import 'preference.dart';
import 'preference_extractor.dart';

class AgentPreferenceExtractor implements PreferenceExtractor {
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final Preference preference;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final String systemPrompt;
  final List<String>? skills;

  AgentPreferenceExtractor({
    required this.llmQueue,
    required this.client,
    required this.preference,
    required this.llmConfig,
    required this.systemPrompt,
    this.llmConfigResolver,
    this.skills,
  });

  @override
  Future<List<PreferenceEntry>> consume(PreferenceSourceRecord record) async {
    if (record.userId == null || record.userId!.trim().isEmpty) {
      return const [];
    }
    final effectiveConfig = normalizeLlmConfigForLiteAgent(
      llmConfigResolver?.call() ?? llmConfig,
    );
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    final taskContent = _buildTaskContent(record);
    try {
      final preferences = await llmQueue.enqueue(
        purpose: 'preference_extraction',
        priority: 9,
        weight: 1,
        modelKey: modelKey,
        jobId: record.jobId,
        run: (context) async {
          final sdk = client.sdk;
          final capability = Capability(
            llmConfig: effectiveConfig,
            systemPrompt: systemPrompt,
            skills: skills,
            callbackOpenTool: CallbackOpenTool(opentool: _toolSpecJson()),
          );
          final session = await sdk.initSession(capability: capability);
          final task = UserTask(content: taskContent, isChunk: true);
          final completer = Completer<List<String>>();
          final handler = _PreferenceExtractionToolHandler(
            onFirstToken: context.markFirstToken,
            onMessageCallback: (message) => _recordTokenUsage(message, context),
            onPreferences: (items) {
              if (!completer.isCompleted) {
                completer.complete(items);
              }
            },
            onDoneCallback: () {
              if (!completer.isCompleted) {
                completer.complete(const []);
              }
            },
          );
          await sdk.chat(session, task, handler);
          return completer.future;
        },
      );
      if (preferences.isEmpty) {
        return const [];
      }
      return preference.addTexts(
        userId: record.userId!.trim(),
        texts: preferences,
        updatedAt: record.timestamp,
      );
    } catch (_) {
      return const [];
    }
  }

  List<Content> _buildTaskContent(PreferenceSourceRecord record) {
    final rawContent = record.data?['content'];
    final contentLines = rawContent is List
        ? rawContent
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final extraData = record.data == null
        ? null
        : () {
            final next = Map<String, dynamic>.from(record.data!);
            next.remove('content');
            return next.isEmpty ? null : next;
          }();
    final intro = StringBuffer();
    intro.writeln('You extract stable user preferences.');
    intro.writeln('Call generate_preference with a text array.');
    intro.writeln('If no stable preference exists, return an empty array.');
    intro.writeln('Event type: ${record.type}');
    final taskContent = <Content>[
      Content(type: ContentType.text, message: intro.toString()),
    ];
    if (contentLines.isNotEmpty) {
      taskContent.add(
        Content(
          type: ContentType.text,
          message: 'Event content:\n${contentLines.join('\n\n')}',
        ),
      );
    }
    if (extraData != null && extraData.isNotEmpty) {
      taskContent.add(
        Content(
          type: ContentType.text,
          message: 'Event data: ${jsonEncode(extraData)}',
        ),
      );
    }
    return taskContent;
  }

  String _toolSpecJson() {
    final spec = {
      'opentool': '1.1.0',
      'info': {
        'title': 'Kernel Preference Extraction Tools',
        'description': 'Emit preference signals from source records.',
        'version': '1.0.0',
      },
      'functions': [
        {
          'name': 'generate_preference',
          'description': 'Generate durable preference texts for the user.',
          'parameters': [
            {
              'name': 'text',
              'description': 'Preference texts to store.',
              'required': true,
              'schema': {
                'type': 'array',
                'items': {'type': 'string'},
              },
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

class _PreferenceExtractionToolHandler extends AgentMessageHandler {
  final void Function() onFirstToken;
  final void Function(AgentMessage message) onMessageCallback;
  final void Function(List<String> items) onPreferences;
  final void Function() onDoneCallback;

  _PreferenceExtractionToolHandler({
    required this.onFirstToken,
    required this.onMessageCallback,
    required this.onPreferences,
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
      case 'generate_preference':
        onPreferences(_buildPreferences(args));
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
    onPreferences(const []);
  }

  List<String> _buildPreferences(Map<String, dynamic> args) {
    final text = args['text'];
    if (text is! List) {
      return const [];
    }
    return text
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}
