import 'input.dart';
import 'model.dart';

abstract class Perception {
  Future<Percept> process(RawInput input);
}

class SwitchablePerception implements Perception {
  Perception _delegate;

  SwitchablePerception(this._delegate);

  Perception get delegate => _delegate;

  set delegate(Perception delegate) {
    _delegate = delegate;
  }

  @override
  Future<Percept> process(RawInput input) => _delegate.process(input);
}

class ThrowingPerception implements Perception {
  final String message;

  ThrowingPerception({
    this.message = 'LLM models not configured.',
  });

  @override
  Future<Percept> process(RawInput input) {
    throw StateError(message);
  }
}

class RuleBasedPerception implements Perception {
  final double minTextConfidence;
  final double structuredConfidence;

  RuleBasedPerception({
    this.minTextConfidence = 0.6,
    this.structuredConfidence = 0.9,
  });

  @override
  Future<Percept> process(RawInput input) async {
    final candidates = <CandidateIntent>[];
    final text = input.text?.trim();
    final data = input.data;
    if (data != null && data['action'] is String) {
      final params = data['params'];
      candidates.add(
        CandidateIntent(
          action: data['action'] as String,
          target: data['target'] as String?,
          params: params is Map<String, dynamic> ? params : null,
          confidence: structuredConfidence,
        ),
      );
    }
    if (text != null && text.isNotEmpty) {
      candidates.addAll(_candidatesFromText(text));
      if (candidates.isEmpty) {
        candidates.add(
          CandidateIntent(
            action: 'message',
            target: null,
            params: {'text': text},
            confidence: minTextConfidence,
          ),
        );
      }
    }
    if (candidates.isEmpty && input.data != null && input.data!.isNotEmpty) {
      candidates.add(
        CandidateIntent(
          action: 'data',
          target: null,
          params: input.data,
          confidence: 0.4,
        ),
      );
    }
    if (candidates.isEmpty) {
      candidates.add(
        const CandidateIntent(
          action: 'noop',
          target: null,
          params: null,
          confidence: 0.1,
        ),
      );
    }
    final confidence = candidates
        .map((candidate) => candidate.confidence)
        .reduce((a, b) => a > b ? a : b);
    return Percept(candidates: candidates, confidence: confidence);
  }

  List<CandidateIntent> _candidatesFromText(String text) {
    final lower = text.toLowerCase();
    final candidates = <CandidateIntent>[];
    final id = _firstInt(lower);
    final createMatch =
        RegExp(r'\bcreate\b\s+(.*)$', caseSensitive: false).firstMatch(text);
    if (lower.contains('create') || lower.contains('add')) {
      final createText = createMatch?.group(1)?.trim();
      candidates.add(
        CandidateIntent(
          action: 'create',
          target: null,
          params: {
            if (createText != null && createText.isNotEmpty) 'text': createText,
          },
          confidence: 0.7,
        ),
      );
    }
    if (lower.contains('read') || lower.contains('get') || lower.contains('show')) {
      candidates.add(
        CandidateIntent(
          action: 'read',
          target: null,
          params: {
            if (id != null) 'id': id,
          },
          confidence: 0.7,
        ),
      );
    }
    if (lower.contains('update') || lower.contains('edit')) {
      final updateText = _extractUpdateText(text);
      candidates.add(
        CandidateIntent(
          action: 'update',
          target: null,
          params: {
            if (id != null) 'id': id,
            if (updateText != null) 'text': updateText,
          },
          confidence: 0.7,
        ),
      );
    }
    if (lower.contains('delete') || lower.contains('remove')) {
      candidates.add(
        CandidateIntent(
          action: 'delete',
          target: null,
          params: {
            if (id != null) 'id': id,
          },
          confidence: 0.7,
        ),
      );
    }
    if (lower.contains('list') || lower.contains('all')) {
      candidates.add(
        const CandidateIntent(
          action: 'list',
          target: null,
          params: null,
          confidence: 0.6,
        ),
      );
    }
    if (lower.contains('count')) {
      candidates.add(
        const CandidateIntent(
          action: 'count',
          target: null,
          params: null,
          confidence: 0.6,
        ),
      );
    }
    if (lower.contains('stream') || lower.contains('sequence')) {
      candidates.add(
        const CandidateIntent(
          action: 'sequentiallyRead',
          target: null,
          params: null,
          confidence: 0.5,
        ),
      );
    }
    if (lower.contains('run')) {
      candidates.add(
        const CandidateIntent(
          action: 'run',
          target: null,
          params: null,
          confidence: 0.4,
        ),
      );
    }
    return candidates;
  }

  int? _firstInt(String text) {
    final match = RegExp(r'\b\d+\b').firstMatch(text);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(0)!);
  }

  String? _extractUpdateText(String text) {
    final match = RegExp(r'\bupdate\b.*?\bto\b\s+(.*)$', caseSensitive: false)
        .firstMatch(text);
    if (match != null) {
      return match.group(1)?.trim();
    }
    final parts = text.split(RegExp(r'\bupdate\b', caseSensitive: false));
    if (parts.length > 1) {
      return parts.last.trim();
    }
    return null;
  }
}
