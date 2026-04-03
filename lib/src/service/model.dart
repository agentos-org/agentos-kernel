import '../kernel/memory/model.dart';
import '../kernel/preference/model.dart';

class KernelSources {
  static const String cli = 'cli';
  static const String web = 'web';
  static const String mobile = 'mobile';
  static const String api = 'api';
  static const String test = 'test';

  const KernelSources._();
}

class DaemonToolSyncItem {
  final String toolId;
  final String alias;
  final String status;
  final String endpoint;
  final DateTime updatedAt;

  const DaemonToolSyncItem({
    required this.toolId,
    required this.alias,
    required this.status,
    required this.endpoint,
    required this.updatedAt,
  });
}

class DaemonToolSyncSnapshot {
  final bool running;
  final String host;
  final int port;
  final int revision;
  final List<DaemonToolSyncItem> activeTools;

  const DaemonToolSyncSnapshot({
    required this.running,
    required this.host,
    required this.port,
    required this.revision,
    required this.activeTools,
  });
}

class RelevantContext {
  final bool embeddingsAvailable;
  final List<MemorySummary> memorySummaries;
  final List<PreferenceEntry> preferences;

  const RelevantContext({
    required this.embeddingsAvailable,
    required this.memorySummaries,
    required this.preferences,
  });
}
