import '../kernel/memory/model.dart';
import '../kernel/preference/model.dart';
import '../kernel/job_manager.dart';
import '../kernel/kernel.dart';

class KernelAdminService {
  final Kernel _kernel;

  /// Admin/debug wrapper with access to internal snapshots.
  KernelAdminService(this._kernel);

  /// Get the latest job snapshot from the JobManager.
  ///
  /// [jobId] is the job identifier.
  JobSnapshot getJobSnapshot(String jobId) {
    return _kernel.jobManager.getSnapshot(jobId);
  }

  /// Get a memory snapshot, optionally scoped by source.
  ///
  /// [scope] limits the snapshot to a specific source.
  Future<MemorySnapshot> getMemorySnapshot({String? scope}) {
    return _kernel.memory.getSnapshot(scope: scope);
  }

  /// Get a preference snapshot for a specific user.
  ///
  /// [userId] identifies the user whose preferences should be fetched.
  Future<PreferenceSnapshot> getPreferenceSnapshot({String? userId}) {
    return _kernel.preference.getSnapshot(userId: userId);
  }
}
