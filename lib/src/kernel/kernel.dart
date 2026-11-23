import 'memory/drift_memory.dart';
import 'memory/memory_pipeline.dart';
import 'opentool/opentool_daemon_registry.dart';
import 'preference/preference.dart';
import 'preference/preference_extractor.dart';
import 'supervision/supervision.dart';

class Kernel {
  final OpenToolDaemonRegistry openToolDaemonRegistry;
  final Supervision supervision;
  final DriftMemory memory;
  final MemoryPipeline memoryPipeline;
  final Preference preference;
  final PreferenceExtractor preferenceExtractor;

  const Kernel({
    required this.openToolDaemonRegistry,
    required this.supervision,
    required this.memory,
    required this.memoryPipeline,
    required this.preference,
    required this.preferenceExtractor,
  });
}
