import 'input.dart';
import 'model.dart';
import 'perception.dart';

typedef ContextEnricher = Future<Map<String, dynamic>?> Function(RawInput input);

class ContextualPerception implements Perception {
  final Perception delegate;
  final ContextEnricher enrich;

  ContextualPerception({
    required this.delegate,
    required this.enrich,
  });

  @override
  Future<Percept> process(RawInput input) async {
    final extra = await enrich(input);
    if (extra == null || extra.isEmpty) {
      return delegate.process(input);
    }
    final merged = <String, dynamic>{};
    if (input.data != null) {
      merged.addAll(input.data!);
    }
    merged.addAll(extra);
    return delegate.process(
      RawInput(
        jobId: input.jobId,
        userId: input.userId,
        sessionId: input.sessionId,
        source: input.source,
        text: input.text,
        data: merged,
      ),
    );
  }
}
