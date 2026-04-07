import 'model.dart';
import 'token_estimator.dart';

class MarkdownSegmenter {
  final RagSegmentationConfig config;
  final TokenEstimator estimator;

  const MarkdownSegmenter({
    this.config = const RagSegmentationConfig(),
    this.estimator = const TokenEstimator(),
  });

  List<MarkdownSegmentPlanItem> segment({
    required String documentId,
    required String title,
    required String markdown,
  }) {
    final normalizedTitle = title.trim().isEmpty ? documentId : title.trim();
    final lines = markdown.split('\n');
    final sections = <_Section>[];
    final headingStack = <String>[];
    final buffer = <String>[];
    var sectionCharStart = 0;
    var offset = 0;

    void flushSection() {
      final text = buffer.join('\n').trim();
      if (text.isNotEmpty) {
        sections.add(
          _Section(
            headingPath: headingStack.join(' / '),
            text: text,
            charStart: sectionCharStart,
          ),
        );
      }
      buffer.clear();
      sectionCharStart = offset;
    }

    for (final line in lines) {
      final headingMatch = RegExp(r'^(#{1,6})\s+(.+?)\s*$').firstMatch(line);
      if (headingMatch != null) {
        flushSection();
        final level = headingMatch.group(1)!.length;
        final heading = headingMatch.group(2)!.trim();
        while (headingStack.length >= level) {
          headingStack.removeLast();
        }
        headingStack.add(heading);
        buffer.add(line);
      } else {
        buffer.add(line);
      }
      offset += line.length + 1;
    }
    flushSection();

    if (sections.isEmpty) {
      sections.add(
        _Section(headingPath: '', text: markdown.trim(), charStart: 0),
      );
    }

    final planned = <MarkdownSegmentPlanItem>[];
    var segmentIndex = 0;
    for (final section in sections) {
      planned.addAll(
        _chunkSection(
          documentId: documentId,
          title: normalizedTitle,
          section: section,
          startingIndex: segmentIndex,
        ),
      );
      segmentIndex = planned.length;
    }
    return planned;
  }

  List<MarkdownSegmentPlanItem> _chunkSection({
    required String documentId,
    required String title,
    required _Section section,
    required int startingIndex,
  }) {
    final paragraphs = section.text
        .split(RegExp(r'\n\s*\n'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.isEmpty) {
      return const [];
    }
    final chunks = <String>[];
    final buffer = <String>[];
    var currentTokens = 0;

    void flushChunk() {
      if (buffer.isEmpty) {
        return;
      }
      chunks.add(buffer.join('\n\n').trim());
      if (config.overlapTokens <= 0) {
        buffer.clear();
        currentTokens = 0;
        return;
      }
      final overlap = <String>[];
      var overlapTokens = 0;
      for (final item in buffer.reversed) {
        final itemTokens = estimator.estimate(item);
        overlap.insert(0, item);
        overlapTokens += itemTokens;
        if (overlapTokens >= config.overlapTokens) {
          break;
        }
      }
      buffer
        ..clear()
        ..addAll(overlap);
      currentTokens = overlapTokens;
    }

    for (final paragraph in paragraphs) {
      final paragraphTokens = estimator.estimate(paragraph);
      final nextTokens = currentTokens + paragraphTokens;
      if (buffer.isNotEmpty && nextTokens > config.maxTokens) {
        flushChunk();
      }
      buffer.add(paragraph);
      currentTokens += paragraphTokens;
      if (currentTokens >= config.targetTokens) {
        flushChunk();
      }
    }
    flushChunk();

    final planned = <MarkdownSegmentPlanItem>[];
    var cursor = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final headingPath = section.headingPath;
      final text = [
        '# $title',
        if (headingPath.isNotEmpty) '## $headingPath',
        chunk,
      ].join('\n\n').trim();
      final chunkStart = section.text.indexOf(chunk, cursor);
      final safeChunkStart = chunkStart < 0 ? cursor : chunkStart;
      cursor = safeChunkStart + chunk.length;
      final textHash = stableHashHex(normalizeRagText(text));
      final fingerprint = stableHashHex(
        '${headingPath.trim()}|$i|${normalizeRagText(text)}',
      );
      final boundaryStart = normalizeRagText(
        text.substring(0, text.length < 64 ? text.length : 64),
      );
      final boundaryEnd = normalizeRagText(
        text.substring(text.length < 64 ? 0 : text.length - 64),
      );
      final segmentKey = stableHashHex(
        '$documentId|$headingPath|$i|$boundaryStart|$boundaryEnd',
      );
      planned.add(
        MarkdownSegmentPlanItem(
          segmentKey: segmentKey,
          segmentIndex: startingIndex + i,
          headingPath: headingPath,
          text: text,
          textHash: textHash,
          contentFingerprint: fingerprint,
          tokenEstimate: estimator.estimate(text),
          charStart: section.charStart + safeChunkStart,
          charEnd: section.charStart + safeChunkStart + chunk.length,
        ),
      );
    }
    return planned;
  }
}

class MarkdownSegmentPlanItem {
  final String segmentKey;
  final int segmentIndex;
  final String headingPath;
  final String text;
  final String textHash;
  final String contentFingerprint;
  final int tokenEstimate;
  final int charStart;
  final int charEnd;

  const MarkdownSegmentPlanItem({
    required this.segmentKey,
    required this.segmentIndex,
    required this.headingPath,
    required this.text,
    required this.textHash,
    required this.contentFingerprint,
    required this.tokenEstimate,
    required this.charStart,
    required this.charEnd,
  });
}

class _Section {
  final String headingPath;
  final String text;
  final int charStart;

  const _Section({
    required this.headingPath,
    required this.text,
    required this.charStart,
  });
}
