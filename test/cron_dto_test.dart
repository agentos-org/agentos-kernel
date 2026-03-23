import 'package:agentos_kernel/src/service/dto.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Cron DTO JSON', () {
    test('AgentCronSpecDto preserves llmConfig through json round trip', () {
      final json = {
        'systemPrompt': 'You are a cron agent.',
        'content': [
          {'type': 'text', 'message': 'Generate the nightly report.'},
        ],
        'timeoutSeconds': 3600,
        'llmConfig': {
          'baseUrl': 'https://api.example.com/v1',
          'apiKey': 'external-key',
          'model': 'external-model',
          'contextWindowSize': 64000,
        },
      };

      final spec = AgentCronSpecDto.fromJson(json);
      final encoded = spec.toJson();

      expect(spec.llmConfig, isNotNull);
      expect(spec.llmConfig!.baseUrl, 'https://api.example.com/v1');
      expect(spec.llmConfig!.model, 'external-model');
      expect(spec.llmConfig!.contextWindowSize, 64000);
      expect(encoded['llmConfig'], isA<Map<String, dynamic>>());
      final llmConfig = encoded['llmConfig'] as Map<String, dynamic>;
      expect(llmConfig['baseUrl'], 'https://api.example.com/v1');
      expect(llmConfig['model'], 'external-model');
      expect(llmConfig['contextWindowSize'], 64000);
    });

    test(
      'CronTaskDto preserves nested spec llmConfig through json round trip',
      () {
        final task = CronTaskDto(
          cronId: 'cron-1',
          name: 'nightly-report',
          schedule: '0 9 * * *',
          source: 'api',
          enabled: true,
          status: 'active',
          concurrency: CronTaskConcurrencyDto.skipIfRunning,
          createdAt: DateTime.parse('2026-03-17T09:00:00.000Z'),
          updatedAt: DateTime.parse('2026-03-17T09:00:00.000Z'),
          spec: AgentCronSpecDto(
            systemPrompt: 'You are a cron agent.',
            content: [
              Content(
                type: ContentType.text,
                message: 'Generate the nightly report.',
              ),
            ],
            llmConfig: LLMConfig(
              baseUrl: 'https://api.example.com/v1',
              apiKey: 'external-key',
              model: 'external-model',
              contextWindowSize: 64000,
            ),
          ),
        );

        final encoded = task.toJson();
        final decoded = CronTaskDto.fromJson(encoded);

        expect(decoded.spec.llmConfig, isNotNull);
        expect(decoded.spec.llmConfig!.baseUrl, 'https://api.example.com/v1');
        expect(decoded.spec.llmConfig!.model, 'external-model');
        expect(decoded.spec.llmConfig!.contextWindowSize, 64000);
      },
    );

    test('CronRunDto preserves llmConfig through json round trip', () {
      final run = CronRunDto(
        runId: 'run-1',
        cronId: 'cron-1',
        trigger: 'manual',
        status: 'succeeded',
        scheduledAt: DateTime.parse('2026-03-17T09:00:00.000Z'),
        startedAt: DateTime.parse('2026-03-17T09:00:01.000Z'),
        finishedAt: DateTime.parse('2026-03-17T09:00:10.000Z'),
        llmConfig: LLMConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'external-key',
          model: 'external-model',
          contextWindowSize: 64000,
        ),
        hasDisplayableResult: true,
        displayText: 'done',
      );

      final encoded = run.toJson();
      final decoded = CronRunDto.fromJson(encoded);

      expect(decoded.llmConfig, isNotNull);
      expect(decoded.llmConfig!.baseUrl, 'https://api.example.com/v1');
      expect(decoded.llmConfig!.model, 'external-model');
      expect(decoded.llmConfig!.contextWindowSize, 64000);
    });
  });
}
