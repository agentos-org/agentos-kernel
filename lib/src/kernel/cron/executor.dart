import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import 'model.dart';

abstract class CronTaskExecutor {
  Future<CronExecutionResult> run(
    CronTaskDefinition task, {
    DateTime? scheduledAt,
    Future<void> Function(AgentMessage message)? onMessage,
  });
}
