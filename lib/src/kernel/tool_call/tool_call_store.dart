import 'dart:convert';

import '../execution/model.dart';

class ToolCallRecord {
  final String jobId;
  final String? userId;
  final String? sessionId;
  final String? source;
  final String toolId;
  final String function;
  final String status;
  final String? argumentsJson;
  final String? resultJson;
  final String? error;
  final DateTime startedAt;
  final DateTime completedAt;
  final int durationMs;

  const ToolCallRecord({
    required this.jobId,
    required this.toolId,
    required this.function,
    required this.status,
    required this.startedAt,
    required this.completedAt,
    required this.durationMs,
    this.userId,
    this.sessionId,
    this.source,
    this.argumentsJson,
    this.resultJson,
    this.error,
  });

  factory ToolCallRecord.fromEvent({
    required ToolCallEvent event,
    required String? source,
    required String? userId,
    required String? sessionId,
  }) {
    final completedAt = event.completedAt ?? DateTime.now();
    return ToolCallRecord(
      jobId: event.jobId,
      userId: userId,
      sessionId: sessionId,
      source: source,
      toolId: event.toolId,
      function: event.function,
      status: event.status.name,
      argumentsJson: _encodeJson(event.arguments),
      resultJson: _encodeJson(event.result),
      error: event.error,
      startedAt: event.startedAt,
      completedAt: completedAt,
      durationMs: completedAt.difference(event.startedAt).inMilliseconds,
    );
  }

  static String? _encodeJson(Object? value) {
    if (value == null) {
      return null;
    }
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}

abstract class ToolCallStore {
  Future<void> record(ToolCallRecord record);
}
