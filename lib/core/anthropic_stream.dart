import 'dart:convert';

/// Pure, network-free accumulator for the Anthropic Messages streaming
/// (`"stream": true`) Server-Sent-Events protocol, scoped to the guardian's
/// single-tool-per-turn design.
///
/// The guardian's user-facing text lives in the tool call's `message` field
/// (tool_choice:any, disable_parallel_tool_use, exactly one tool per turn). The
/// model streams the tool's INPUT JSON as a sequence of `input_json_delta`
/// fragments. This class:
///   1. accumulates those fragments per content-block index into the full
///      tool-input JSON string,
///   2. captures the tool's `name` + `id` from `content_block_start`,
///   3. after each delta, re-extracts the CURRENT value of the `message` key
///      via [extractPartialJsonStringField] (injected) so the UI can render it
///      live.
///
/// With adaptive thinking enabled (tool_choice:auto), a turn can also contain a
/// `thinking` block (streamed via `thinking_delta` + a `signature_delta`) and a
/// `text` block (streamed via `text_delta`) BEFORE the optional `tool_use`
/// block. This accumulator captures all three per content-block index, in
/// arrival order, so the engine can:
///   1. reconstruct the ORDERED assistant content `[thinking(+signature),
///      text?, tool_use?]` to commit to history (thinking blocks WITH their
///      signature MUST be preserved before a tool_use, or the follow-up
///      tool_result turn 400s), and
///   2. surface the user-facing text (the tool's `message`, else the streamed
///      text block) live — never the thinking text.
///
/// Feed it raw SSE event types + their decoded `data` JSON via [handleEvent].
/// It carries NO network code so it is fully unit-testable with canned events.
class AnthropicStreamAccumulator {
  AnthropicStreamAccumulator({required this.extractMessage});

  /// Injected incremental extractor — in production this is
  /// `extractPartialJsonStringField` from guardian_tools.dart. Returns the
  /// current (possibly partial) value of a top-level string field, or null.
  final String? Function(String partialJson, String field) extractMessage;

  /// Per-block-index accumulated `input_json_delta` partial_json fragments.
  final Map<int, StringBuffer> _toolInputByIndex = {};

  /// Per-block-index accumulated `thinking_delta` text and the captured
  /// `signature_delta` signature.
  final Map<int, StringBuffer> _thinkingByIndex = {};
  final Map<int, String> _signatureByIndex = {};

  /// Per-block-index accumulated `text_delta` text.
  final Map<int, StringBuffer> _textByIndex = {};

  /// Content-block indices in the order they were opened, so we can rebuild the
  /// ordered assistant content list the API requires.
  final List<int> _blockOrder = [];

  /// The content-block index of the tool_use block (the only one we care about
  /// for the guardian; there is at most one per turn).
  int? _toolBlockIndex;

  String? _toolName;
  String? _toolUseId;
  String? _stopReason;

  /// Last emitted message snapshot — used to suppress duplicate onDelta calls.
  String? _lastMessageSnapshot;

  String? get toolName => _toolName;
  String? get toolUseId => _toolUseId;
  String? get stopReason => _stopReason;

  /// The accumulated streamed `text` block (plain text the model wrote outside
  /// any tool call), or null if no text block streamed. Used as the user-facing
  /// message ONLY when no tool was produced (a keep-talking `auto` reply).
  String? get textBlock {
    for (final index in _blockOrder) {
      final buf = _textByIndex[index];
      if (buf != null) return buf.toString();
    }
    return null;
  }

  /// Reconstruct the ORDERED assistant content blocks exactly as the API
  /// returned them, ready to append to history: `thinking(+signature)`, then any
  /// `text`, then any `tool_use`, in arrival order. Only blocks that actually
  /// appeared are included. Thinking blocks carry their `signature` verbatim so
  /// the next turn's tool_result is valid. Pass the fully-decoded [toolInput]
  /// (the engine decodes it once at stream end) so the tool_use block embeds the
  /// parsed input rather than the raw JSON string.
  List<Map<String, dynamic>> orderedContent(Map<String, dynamic> toolInput) {
    final content = <Map<String, dynamic>>[];
    for (final index in _blockOrder) {
      final thinking = _thinkingByIndex[index];
      if (thinking != null) {
        final block = <String, dynamic>{
          'type': 'thinking',
          'thinking': thinking.toString(),
        };
        final sig = _signatureByIndex[index];
        if (sig != null) block['signature'] = sig;
        content.add(block);
        continue;
      }
      final text = _textByIndex[index];
      if (text != null) {
        content.add({'type': 'text', 'text': text.toString()});
        continue;
      }
      if (index == _toolBlockIndex && _toolName != null) {
        content.add({
          'type': 'tool_use',
          'id': _toolUseId,
          'name': _toolName,
          'input': toolInput,
        });
      }
    }
    return content;
  }

  /// The full accumulated tool-input JSON string (may be empty / incomplete if
  /// the stream ended early). Decode this at stream end.
  String get toolInputJson =>
      (_toolBlockIndex != null ? _toolInputByIndex[_toolBlockIndex] : null)
          ?.toString() ??
      '';

  /// Decode the accumulated tool-input JSON. Returns an empty map on failure so
  /// callers can fall back safely rather than throw.
  Map<String, dynamic> decodeToolInput() {
    final raw = toolInputJson;
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Malformed / truncated — fall back to empty.
    }
    return <String, dynamic>{};
  }

  /// The current best-effort `message` snapshot from whatever tool-input JSON
  /// has streamed so far, or null if the message key/value hasn't appeared yet.
  String? get currentMessage {
    final raw = toolInputJson;
    if (raw.isEmpty) return null;
    return extractMessage(raw, 'message');
  }

  /// Feed a single SSE event. [type] is the value of the `event:` line; [data]
  /// is the decoded `data:` JSON (already `jsonDecode`d by the caller). Returns
  /// the NEW `message` snapshot when it changed as a result of this event
  /// (so callers can fire onDelta), otherwise null.
  ///
  /// Tolerates unknown event types and `ping` events (they are no-ops).
  String? handleEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'content_block_start':
        final index = (data['index'] as num?)?.toInt();
        final block = data['content_block'];
        if (index != null && block is Map) {
          _trackBlockOrder(index);
          final type = block['type'];
          if (type == 'tool_use') {
            _toolBlockIndex = index;
            _toolName = block['name'] as String?;
            _toolUseId = block['id'] as String?;
            _toolInputByIndex.putIfAbsent(index, () => StringBuffer());
          } else if (type == 'thinking') {
            _thinkingByIndex.putIfAbsent(index, () => StringBuffer());
            // A signature may already be present on the start block in some
            // shapes; capture it if so.
            final sig = block['signature'];
            if (sig is String && sig.isNotEmpty) _signatureByIndex[index] = sig;
          } else if (type == 'text') {
            _textByIndex.putIfAbsent(index, () => StringBuffer());
          }
        }
        return null;
      case 'content_block_delta':
        final index = (data['index'] as num?)?.toInt();
        final delta = data['delta'];
        if (index == null || delta is! Map) return null;
        final deltaType = delta['type'];
        if (deltaType == 'input_json_delta') {
          final partial = delta['partial_json'];
          if (partial is String) {
            _trackBlockOrder(index);
            _toolInputByIndex.putIfAbsent(index, () => StringBuffer()).write(
                  partial,
                );
            // Only the tool block drives the live message; if we haven't seen a
            // content_block_start for a tool_use yet, treat this
            // input_json_delta block as the tool block.
            _toolBlockIndex ??= index;
            return _maybeEmitMessage();
          }
          return null;
        }
        if (deltaType == 'thinking_delta') {
          final partial = delta['thinking'];
          if (partial is String) {
            _trackBlockOrder(index);
            _thinkingByIndex
                .putIfAbsent(index, () => StringBuffer())
                .write(partial);
          }
          // Thinking text is NEVER surfaced as the user-facing message (the UI
          // shows a thinking indicator already).
          return null;
        }
        if (deltaType == 'signature_delta') {
          final sig = delta['signature'];
          if (sig is String && sig.isNotEmpty) {
            _trackBlockOrder(index);
            // The signature arrives whole (not fragmented); capture it verbatim.
            _signatureByIndex[index] = sig;
          }
          return null;
        }
        if (deltaType == 'text_delta') {
          final partial = delta['text'];
          if (partial is String) {
            _trackBlockOrder(index);
            _textByIndex
                .putIfAbsent(index, () => StringBuffer())
                .write(partial);
            // Surface streamed text live ONLY while no tool is being produced —
            // a tool's `message` takes precedence once it appears.
            return _maybeEmitTextMessage();
          }
          return null;
        }
        return null;
      case 'message_delta':
        final delta = data['delta'];
        if (delta is Map && delta['stop_reason'] != null) {
          _stopReason = delta['stop_reason'] as String?;
        }
        return null;
      case 'content_block_stop':
        // Some shapes carry the thinking signature on the stop event (or on a
        // trailing content_block). Capture it if we haven't already.
        final index = (data['index'] as num?)?.toInt();
        final block = data['content_block'];
        if (index != null && block is Map) {
          final sig = block['signature'];
          if (sig is String && sig.isNotEmpty) _signatureByIndex[index] = sig;
        }
        return null;
      case 'message_start':
      case 'message_stop':
      case 'ping':
      default:
        return null;
    }
  }

  /// Record a content-block index the first time it is seen so [orderedContent]
  /// can rebuild the assistant content in arrival order.
  void _trackBlockOrder(int index) {
    if (!_blockOrder.contains(index)) _blockOrder.add(index);
  }

  String? _maybeEmitMessage() {
    final snapshot = currentMessage;
    if (snapshot == null) return null;
    if (snapshot == _lastMessageSnapshot) return null;
    _lastMessageSnapshot = snapshot;
    return snapshot;
  }

  /// Emit the streamed text block as the live message, but only while no tool
  /// is being produced (the tool's `message` field wins once it appears). This
  /// surfaces a keep-talking `auto` reply live without leaking thinking text.
  String? _maybeEmitTextMessage() {
    if (_toolBlockIndex != null) return null;
    final snapshot = textBlock;
    if (snapshot == null) return null;
    if (snapshot == _lastMessageSnapshot) return null;
    _lastMessageSnapshot = snapshot;
    return snapshot;
  }
}

/// A single parsed SSE event: the `event:` type plus the raw `data:` payload
/// (concatenated across multiple `data:` lines, newline-joined per spec).
class SseEvent {
  SseEvent(this.type, this.data);
  final String type;
  final String data;
}

/// Incremental SSE line/buffer parser. Feed it raw decoded chunks via [add];
/// it yields complete events (delimited by a blank line) as they become
/// available. Pure and network-free for unit testing.
///
/// Per the SSE spec, an event is a run of lines terminated by a blank line.
/// Within an event, `event:` sets the type (default `message`) and `data:`
/// lines are accumulated (joined with `\n`). Lines starting with `:` are
/// comments and ignored. We buffer partial lines across chunk boundaries.
class SseParser {
  final StringBuffer _buffer = StringBuffer();

  /// Add a decoded chunk and return any COMPLETE events it produced. Partial
  /// trailing data stays buffered for the next [add].
  List<SseEvent> add(String chunk) {
    _buffer.write(chunk);
    final content = _buffer.toString();

    // Normalize CRLF -> LF so the \n\n event delimiter works regardless of the
    // server's line endings.
    final normalized = content.replaceAll('\r\n', '\n');

    final events = <SseEvent>[];
    var start = 0;
    while (true) {
      final boundary = normalized.indexOf('\n\n', start);
      if (boundary < 0) break;
      final block = normalized.substring(start, boundary);
      final parsed = _parseBlock(block);
      if (parsed != null) events.add(parsed);
      start = boundary + 2;
    }

    // Re-buffer the unconsumed tail.
    _buffer
      ..clear()
      ..write(normalized.substring(start));
    return events;
  }

  /// Flush any trailing event not terminated by a blank line (e.g. at stream
  /// end). Returns the event if the remaining buffer parses to one.
  SseEvent? flush() {
    final remaining = _buffer.toString().trim();
    _buffer.clear();
    if (remaining.isEmpty) return null;
    return _parseBlock(remaining);
  }

  SseEvent? _parseBlock(String block) {
    String type = 'message';
    final dataLines = <String>[];
    for (final rawLine in block.split('\n')) {
      final line = rawLine;
      if (line.isEmpty) continue;
      if (line.startsWith(':')) continue; // comment
      if (line.startsWith('event:')) {
        type = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isEmpty) return null;
    return SseEvent(type, dataLines.join('\n'));
  }
}
