import 'model.dart';

abstract class Learning {
  Future<void> consume(LearningRecord record);
}

class OfflineLearning implements Learning {
  @override
  Future<void> consume(LearningRecord record) async {
    // Intentionally no-op in the default stub.
  }
}
