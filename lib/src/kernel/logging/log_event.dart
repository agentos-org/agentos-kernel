abstract class KernelLogEvent {
  final String type;
  final String requestId;
  final String? userId;
  final String? sessionId;
  final String? source;
  final DateTime timestamp;

  KernelLogEvent({
    required this.type,
    required this.requestId,
    this.userId,
    this.sessionId,
    this.source,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
