import 'dart:convert';

import '../events.dart';

abstract class KernelLogger {
  void log(KernelEvent event, {Map<String, dynamic>? data});
  void error(String message, Object error, {Map<String, dynamic>? data});
  void warn(String message, {Map<String, dynamic>? data});
}

class ConsoleKernelLogger implements KernelLogger {
  @override
  void log(KernelEvent event, {Map<String, dynamic>? data}) {
    final payload = <String, dynamic>{
      'level': 'info',
      'type': event.type,
      'jobId': event.jobId,
      'userId': event.userId,
      'sessionId': event.sessionId,
      'source': event.source,
      'timestamp': event.timestamp.toIso8601String(),
      if (data != null) 'data': data,
    };
    print(jsonEncode(payload));
  }

  @override
  void error(String message, Object error, {Map<String, dynamic>? data}) {
    final payload = <String, dynamic>{
      'level': 'error',
      'message': message,
      'error': error.toString(),
      'timestamp': DateTime.now().toIso8601String(),
      if (data != null) 'data': data,
    };
    print(jsonEncode(payload));
  }

  @override
  void warn(String message, {Map<String, dynamic>? data}) {
    final payload = <String, dynamic>{
      'level': 'warn',
      'message': message,
      'timestamp': DateTime.now().toIso8601String(),
      if (data != null) 'data': data,
    };
    print(jsonEncode(payload));
  }
}
