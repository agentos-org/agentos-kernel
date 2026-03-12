import 'model.dart';
import 'preference.dart';

class AggregatingPreference implements Preference {
  final Preference delegate;
  void Function(String userId)? onSignalRecorded;

  AggregatingPreference({required this.delegate, this.onSignalRecorded});

  @override
  Future<void> deletePreferenceKey(String key, {String? userId}) {
    return delegate.deletePreferenceKey(key, userId: userId);
  }

  @override
  Future<PreferenceSnapshot> getSnapshot({String? userId}) {
    return delegate.getSnapshot(userId: userId);
  }

  @override
  Future<List<PreferenceSignal>> listSignals({String? userId}) {
    return delegate.listSignals(userId: userId);
  }

  @override
  Future<Map<String, dynamic>> listPreferences({String? userId}) {
    return delegate.listPreferences(userId: userId);
  }

  @override
  Future<void> recordSignal(PreferenceSignal signal) async {
    await delegate.recordSignal(signal);
    onSignalRecorded?.call(signal.userId);
  }

  @override
  Future<void> savePreferences(
    Map<String, dynamic> preferences, {
    String? userId,
  }) {
    return delegate.savePreferences(preferences, userId: userId);
  }
}
