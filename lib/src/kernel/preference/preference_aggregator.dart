import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
import '../agent/model.dart';
import '../logging/logger.dart';
import 'model.dart';
import 'preference.dart';

class PreferenceAggregator {
  final Preference preference;
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final KernelLogger? logger;
  final Duration interval;
  final int maxPerRun;
  final int queueLimit;
  final bool enabled;

  Timer? _timer;
  bool _running = false;
  final List<String> _pendingUsers = [];

  PreferenceAggregator({
    required this.preference,
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    this.llmConfigResolver,
    this.logger,
    this.interval = const Duration(minutes: 5),
    this.maxPerRun = 1,
    this.queueLimit = 500,
    this.enabled = true,
  }) {
    if (enabled) {
      start();
    }
  }

  void start() {
    if (!enabled) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void markDirty(String userId) {
    final normalized = userId.trim();
    if (!enabled || normalized.isEmpty) {
      return;
    }
    if (_pendingUsers.contains(normalized)) {
      return;
    }
    _pendingUsers.add(normalized);
    if (queueLimit > 0 && _pendingUsers.length > queueLimit) {
      _pendingUsers.removeAt(0);
    }
  }

  Future<void> _tick() async {
    if (_running || _pendingUsers.isEmpty) {
      return;
    }
    if (!llmQueue.isIdle) {
      return;
    }
    _running = true;
    try {
      final runs = maxPerRun <= 0 ? 1 : maxPerRun;
      for (var i = 0; i < runs && _pendingUsers.isNotEmpty; i += 1) {
        if (!llmQueue.isIdle) {
          break;
        }
        final userId = _pendingUsers.removeAt(0);
        await aggregateUser(userId: userId);
      }
    } catch (error) {
      logger?.error('Preference aggregation failed.', error);
    } finally {
      _running = false;
    }
  }

  Future<Map<String, dynamic>> aggregateUser({required String userId}) async {
    final signals = await preference.listSignals(userId: userId);
    if (signals.isEmpty) {
      await preference.savePreferences(const {}, userId: userId);
      return const {};
    }

    final currentPreferences = await preference.listPreferences(userId: userId);
    final prompt = _buildPrompt(
      userId: userId,
      currentPreferences: currentPreferences,
      signals: signals,
    );
    final effectiveConfig = normalizeLlmConfigForLiteAgent(
      llmConfigResolver?.call() ?? llmConfig,
    );
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    final response = await llmQueue.enqueue(
      purpose: 'preference_aggregation',
      priority: 6,
      weight: 1,
      modelKey: modelKey,
      userId: userId,
      run: (context) async {
        return client.chatSimple(
          llmConfig: effectiveConfig,
          systemPrompt: _systemPrompt,
          userPrompt: prompt,
          context: context,
        );
      },
    );
    final payload = _parsePayload(response.text);
    final nextPreferences = _extractPreferences(payload);
    await preference.savePreferences(nextPreferences, userId: userId);
    return nextPreferences;
  }

  String _buildPrompt({
    required String userId,
    required Map<String, dynamic> currentPreferences,
    required List<PreferenceSignal> signals,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('User: $userId');
    buffer.writeln('Current preferences: ${jsonEncode(currentPreferences)}');
    buffer.writeln('Signals (JSON lines):');
    for (final signal in signals) {
      buffer.writeln(
        jsonEncode({
          'text': signal.text,
          'metadata': signal.metadata,
          'timestamp': signal.timestamp.toIso8601String(),
        }),
      );
    }
    return buffer.toString();
  }

  Map<String, dynamic> _extractPreferences(Map<String, dynamic>? payload) {
    if (payload == null) {
      return const {};
    }
    final nested = payload['preferences'];
    if (nested is Map<String, dynamic>) {
      return nested;
    }
    if (nested is Map) {
      return nested.cast<String, dynamic>();
    }
    if (payload.containsKey('preferences')) {
      return const {};
    }
    return payload;
  }

  Map<String, dynamic>? _parsePayload(String text) {
    final direct = _tryDecodeJsonMap(text);
    if (direct != null) {
      return direct;
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return _tryDecodeJsonMap(text.substring(start, end + 1));
    }
    return null;
  }

  Map<String, dynamic>? _tryDecodeJsonMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  static const String _systemPrompt =
      'You aggregate user preference signals into a current preference map. '
      'Return JSON only. Prefer the schema {"preferences": {...}}. '
      'Use open-ended keys. '
      'Use signal metadata.preferenceKey or preferenceKeys as hints when present. '
      'Keep only current, supported preferences and avoid redundant wording.';
}
