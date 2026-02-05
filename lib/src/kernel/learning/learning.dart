import 'model.dart';

abstract class Learning {
  Future<void> consume(LearningRecord record);
}

class SwitchableLearning implements Learning {
  Learning _delegate;

  SwitchableLearning(this._delegate);

  Learning get delegate => _delegate;

  set delegate(Learning delegate) {
    _delegate = delegate;
  }

  @override
  Future<void> consume(LearningRecord record) => _delegate.consume(record);
}

class ThrowingLearning implements Learning {
  final String message;

  ThrowingLearning({
    this.message = 'LLM models not configured.',
  });

  @override
  Future<void> consume(LearningRecord record) {
    throw StateError(message);
  }
}

class OfflineLearning implements Learning {
  @override
  Future<void> consume(LearningRecord record) async {
    // Intentionally no-op in the default stub.
  }
}
