import 'package:agentos_kernel/src/kernel/cron/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('AgentCronSpec.toUserTask', () {
    test('appends current time to trailing text content', () {
      final spec = AgentCronSpec(
        systemPrompt: 'You are a cron agent.',
        content: [Content(type: ContentType.text, message: '网络搜索关于AI的新闻')],
      );

      final task = spec.toUserTask(now: DateTime(2021, 2, 4, 12, 33, 22));

      expect(task.content, hasLength(1));
      expect(
        task.content.single.message,
        '网络搜索关于AI的新闻\n*Current Time: 2021-02-04 12:33:22*',
      );
    });

    test(
      'adds separate current time text when trailing content is non-text',
      () {
        final spec = AgentCronSpec(
          systemPrompt: 'You are a cron agent.',
          content: [
            Content(
              type: ContentType.imageUrl,
              message: 'https://example.com/a.png',
            ),
          ],
        );

        final task = spec.toUserTask(now: DateTime(2021, 2, 4, 12, 33, 22));

        expect(task.content, hasLength(2));
        expect(task.content.last.type, ContentType.text);
        expect(
          task.content.last.message,
          '\n[Current Time: 2021-02-04 12:33:22]',
        );
      },
    );
  });
}
