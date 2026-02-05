import 'dart:async';
import 'dart:convert';

import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import '../agent/config.dart';
import '../agent/llm_queue.dart';
import '../agent/liteagent_client.dart';
import '../agent/model.dart';
import '../logging/logger.dart';
import 'drift_memory.dart';
import 'model.dart';

class MemorySummarizer {
  final DriftMemory memory;
  final LlmQueue llmQueue;
  final LiteAgentClient client;
  final LLMConfig llmConfig;
  final LlmConfigResolver? llmConfigResolver;
  final KernelLogger? logger;
  final Duration interval;
  final Duration recentWindow;
  final int maxRecords;
  final int minRecords;
  final int maxScopesPerRun;
  final bool enabled;

  Timer? _timer;
  bool _running = false;
  int _scopeCursor = 0;

  MemorySummarizer({
    required this.memory,
    required this.llmQueue,
    required this.client,
    required this.llmConfig,
    this.llmConfigResolver,
    this.logger,
    this.interval = const Duration(minutes: 5),
    this.recentWindow = const Duration(hours: 24),
    this.maxRecords = 200,
    this.minRecords = 20,
    this.maxScopesPerRun = 1,
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

  Future<void> _tick() async {
    if (_running) {
      return;
    }
    if (!llmQueue.isIdle) {
      return;
    }
    _running = true;
    try {
      final scopes = await memory.listScopes();
      if (scopes.isEmpty) {
        return;
      }
      final runs = maxScopesPerRun <= 0 ? 1 : maxScopesPerRun;
      for (var i = 0; i < runs && scopes.isNotEmpty; i += 1) {
        final index = _scopeCursor % scopes.length;
        final scope = scopes[index];
        _scopeCursor = (_scopeCursor + 1) % scopes.length;
        await summarizeScope(scope: scope);
        if (!llmQueue.isIdle) {
          break;
        }
      }
    } catch (error) {
      logger?.error('Memory summarization failed.', error);
    } finally {
      _running = false;
    }
  }

  Future<MemoryRecord?> summarizeScope({
    required String scope,
    String? userId,
  }) async {
    final cutoff = DateTime.now().subtract(recentWindow);
    final latestSummaryTs = await memory.getLatestSummaryTimestamp(
      scope: scope,
      userId: userId,
    );
    final records = await memory.listRecords(
      scope: scope,
      userId: userId,
      after: latestSummaryTs,
      before: cutoff,
      limit: maxRecords,
      includeSummaries: false,
    );
    if (records.length < minRecords) {
      return null;
    }
    final prompt = _buildSummaryPrompt(
      records: records,
      scope: scope,
      userId: userId,
    );
    final effectiveConfig = llmConfigResolver?.call() ?? llmConfig;
    final modelKey = buildLlmModelKey(
      baseUrl: effectiveConfig.baseUrl,
      model: effectiveConfig.model,
      apiKey: effectiveConfig.apiKey,
    );
    final response = await llmQueue.enqueue(
      purpose: 'memory_summary',
      priority: 2,
      weight: 2,
      modelKey: modelKey,
      userId: userId,
      run: (context) async {
        return client.chatSimple(
          llmConfig: effectiveConfig,
          systemPrompt: _memorySummarySystemPrompt,
          userPrompt: prompt,
          context: context,
        );
      },
    );
    final summaryPayload = _parseSummaryPayload(response.text);
    final summaryText = _extractSummaryText(summaryPayload) ?? response.text;
    final summaryStart = records.first.timestamp;
    final summaryEnd = records.last.timestamp;
    final summaryRecord = MemoryRecord(
      jobId: 'summary-${DateTime.now().microsecondsSinceEpoch}',
      userId: userId,
      sessionId: null,
      scope: scope,
      type: 'MEMORY_SUMMARY',
      data: {
        'summaryText': summaryText,
        'summaryJson': summaryPayload,
        'summaryStart': summaryStart.toIso8601String(),
        'summaryEnd': summaryEnd.toIso8601String(),
        'recordCount': records.length,
      },
      timestamp: summaryEnd,
    );
    await memory.record(summaryRecord);
    return summaryRecord;
  }

  String _buildSummaryPrompt({
    required List<MemoryRecord> records,
    required String scope,
    String? userId,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Summarize these memory records for future planning.');
    buffer.writeln('Scope: $scope');
    if (userId != null && userId.isNotEmpty) {
      buffer.writeln('User: $userId');
    }
    buffer.writeln('Records (JSON lines):');
    for (final record in records) {
      buffer.writeln(
        jsonEncode({
          'type': record.type,
          'data': record.data,
          'timestamp': record.timestamp.toIso8601String(),
        }),
      );
    }
    return buffer.toString();
  }

  String? _extractSummaryText(Map<String, dynamic>? payload) {
    if (payload == null) {
      return null;
    }
    final value = payload['summaryText'];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    return null;
  }

  Map<String, dynamic>? _parseSummaryPayload(String text) {
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

  static const String _memorySummarySystemPrompt =
      'You summarize memory records for future planning and preference learning. '
      'Return JSON only with fields: summaryText, keyFacts, preferences, openQuestions, '
      'intents, toolsUsed, timeRangeStart, timeRangeEnd, recordCount.';
}
