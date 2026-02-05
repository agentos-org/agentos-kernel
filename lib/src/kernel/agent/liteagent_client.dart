import 'dart:async';
import 'dart:convert';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import '../logging/logger.dart';
import 'model.dart';

class LiteAgentClient {
  final String baseUrl;
  final String? apiKey;
  final KernelLogger? logger;

  LiteAgentClient({
    required this.baseUrl,
    this.apiKey,
    this.logger,
  });

  Future<LiteAgentResponse> chatSimple({
    required LLMConfig llmConfig,
    required String systemPrompt,
    required String userPrompt,
    required LlmCallContext context,
  }) async {
    final liteagent = LiteAgentSDK(baseUrl: baseUrl, apiKey: apiKey);
    final session = await liteagent.initSimple(
      SimpleCapability(
        llmConfig: llmConfig,
        systemPrompt: systemPrompt,
      ),
    );
    final task = UserTask(
      content: [
        Content(type: ContentType.text, message: userPrompt),
      ],
      isChunk: true,
    );
    final message = await liteagent.chatSimple(session, task);
    final totalTokens = message.completions?.usage?.totalTokens;
    if (totalTokens != null) {
      context.setTotalTokens(totalTokens);
    }
    return LiteAgentResponse(
      message: message,
      text: _messageToText(message),
    );
  }

  Future<LiteAgentResponse> chatStreaming({
    required LLMConfig llmConfig,
    required String systemPrompt,
    required String userPrompt,
    required LlmCallContext context,
  }) async {
    final liteagent = LiteAgentSDK(baseUrl: baseUrl, apiKey: apiKey);
    final session = await liteagent.initSimple(
      SimpleCapability(
        llmConfig: llmConfig,
        systemPrompt: systemPrompt,
      ),
    );
    final task = UserTask(
      content: [
        Content(type: ContentType.text, message: userPrompt),
      ],
      isChunk: true,
    );
    final completer = Completer<AgentMessage>();
    AgentMessage? lastMessage;
    final handler = _LiteAgentMessageHandler(
      onChunk: () {
        context.markFirstToken();
      },
      onMessage: (message) {
        context.markFirstToken();
        lastMessage = message;
      },
      onDone: () {
        if (lastMessage != null) {
          completer.complete(lastMessage);
        } else {
          completer.completeError(StateError('No LLM message received.'));
        }
      },
      onError: (error) {
        completer.completeError(error);
      },
    );
    await liteagent.chat(session, task, handler);
    final message = await completer.future;
    final totalTokens = message.completions?.usage?.totalTokens;
    if (totalTokens != null) {
      context.setTotalTokens(totalTokens);
    }
    return LiteAgentResponse(
      message: message,
      text: _messageToText(message),
    );
  }

  String _messageToText(AgentMessage message) {
    final content = message.content;
    if (content is String) {
      return content;
    }
    try {
      return jsonEncode(content);
    } catch (_) {
      return content.toString();
    }
  }
}

class LiteAgentResponse {
  final AgentMessage message;
  final String text;

  const LiteAgentResponse({
    required this.message,
    required this.text,
  });
}

class _LiteAgentMessageHandler extends AgentMessageHandler {
  final void Function() _onChunk;
  final void Function(AgentMessage message) _onMessage;
  final void Function() _onDone;
  final void Function(Exception error) _onError;

  _LiteAgentMessageHandler({
    required void Function() onChunk,
    required void Function(AgentMessage message) onMessage,
    required void Function() onDone,
    required void Function(Exception error) onError,
  })  : _onChunk = onChunk,
        _onMessage = onMessage,
        _onDone = onDone,
        _onError = onError;

  @override
  Future<void> onChunk(String sessionId, AgentMessageChunk agentMessageChunk) async {
    _onChunk();
  }

  @override
  Future<void> onDone() async {
    _onDone();
  }

  @override
  Future<void> onError(Exception e) async {
    _onError(e);
  }

  @override
  Future<void> onMessage(String sessionId, AgentMessage agentMessage) async {
    _onMessage(agentMessage);
  }
}
