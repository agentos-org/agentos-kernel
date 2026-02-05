class RawInput {
  final String? jobId;
  final String? userId;
  final String? sessionId;
  final String source;
  final String? text;
  final Map<String, dynamic>? data;

  const RawInput({
    this.jobId,
    this.userId,
    this.sessionId,
    required this.source,
    this.text,
    this.data,
  });
}
