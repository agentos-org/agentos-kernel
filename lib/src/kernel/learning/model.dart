class LearningRecord {
  final String jobId;
  final String? userId;
  final String type;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  const LearningRecord({
    required this.jobId,
    this.userId,
    required this.type,
    this.data,
    required this.timestamp,
  });
}
