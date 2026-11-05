import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

enum ClipboardProbeCase { plainText, urlText, unicodeText }

extension ClipboardProbeCaseLabel on ClipboardProbeCase {
  String get label => switch (this) {
    ClipboardProbeCase.plainText => 'Plain text',
    ClipboardProbeCase.urlText => 'URL as text',
    ClipboardProbeCase.unicodeText => 'Unicode and multiline text',
  };
}

class ClipboardProbeResult {
  const ClipboardProbeResult({
    required this.probe,
    required this.status,
    required this.detail,
    this.elapsedMs = 0,
  });

  final ClipboardProbeCase probe;
  final String status;
  final String detail;
  final int elapsedMs;
  bool get passed => status == 'passed';
  String get forward => passed ? 'Passed' : 'Unverified';
  String get reverse => passed ? 'Passed' : 'Unverified';

  Map<String, Object> toJson() => {
    'case': probe.name,
    'status': status,
    'local_to_remote': forward,
    'remote_to_local': reverse,
    'detail': detail,
    'elapsed_ms': elapsedMs,
  };
}

class ClipboardDiagnosticEntry {
  const ClipboardDiagnosticEntry(this.time, this.event, this.detail);
  final DateTime time;
  final String event;
  final String detail;

  Map<String, String> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'event': event,
    'detail': detail,
  };
}

/// A paired diagnostic carried only through the ordinary OS clipboard path.
/// The code addresses an explicitly armed responder; it is not authorization
/// and does not select a network session. Personal clipboard text is never
/// retained or included in the diagnostic report.
class ClipboardDiagnostics extends ChangeNotifier {
  ClipboardDiagnostics({
    Future<String?> Function()? readText,
    Future<void> Function(String)? writeText,
    DateTime Function()? now,
    String Function(int)? makeId,
    this.pollInterval = const Duration(milliseconds: 750),
    this.caseTimeout = const Duration(seconds: 10),
    this.operationTimeout = const Duration(seconds: 3),
    this.listenerLifetime = const Duration(minutes: 10),
  }) : _readText = readText ?? _readSystemText,
       _writeText = writeText ?? _writeSystemText,
       _now = now ?? DateTime.now,
       _makeId = makeId ?? _randomId;

  static final instance = ClipboardDiagnostics();
  static const maxEntries = 128;
  static const _maxSeenRequests = 256;
  static const _maxProbeLength = 4096;
  static const _prefix = 'RustAdmin clipboard test v1\n';
  static final _codePattern = RegExp(r'^[A-F0-9]{8}$');
  static final _runPattern = RegExp(r'^[A-F0-9]{32}$');
  static final _originPattern = RegExp(
    r'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
  );

  final Future<String?> Function() _readText;
  final Future<void> Function(String) _writeText;
  final DateTime Function() _now;
  final String Function(int) _makeId;
  final Duration pollInterval;
  final Duration caseTimeout;
  final Duration operationTimeout;
  final Duration listenerLifetime;
  String _deviceIdentity = '';
  final _entries = <ClipboardDiagnosticEntry>[];
  final _results = <ClipboardProbeResult>[];
  final _seenRequests = <String>{};
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _caseTimer;
  bool _listening = false;
  bool _running = false;
  bool _foreground = true;
  bool _reading = false;
  int _reads = 0;
  int _writes = 0;
  bool _disposed = false;
  int _epoch = 0;
  int _runGeneration = 0;
  String _listenerCode = '';
  DateTime? _expiresAt;
  (int, int)? _lastTextSignature;
  (int, int)? _lastRejectedSignature;
  bool _readFailed = false;
  _PendingProbe? _pending;

  bool get listening => _listening;
  bool get running => _running;
  bool get foreground => _foreground;
  bool get deviceIdentityReady => _deviceIdentity.isNotEmpty;
  String get listenerCode => _listenerCode;
  DateTime? get expiresAt => _expiresAt;
  List<ClipboardDiagnosticEntry> get entries => List.unmodifiable(_entries);
  List<ClipboardProbeResult> get results => List.unmodifiable(_results);

  void setDeviceIdentity(String value) {
    if (_listening || _running || value.isEmpty || value.length > 512) {
      throw StateError(
        'Device identity unavailable or listener already active',
      );
    }
    _deviceIdentity = value;
  }

  // Salt the device identifier with the fresh run ID. No raw or stable device
  // identifier is placed on the clipboard or included in reports.
  String _originFor(String run) => const Uuid().v5(
    Uuid.NAMESPACE_URL,
    'rustadmin-clipboard:$run:$_deviceIdentity',
  );

  static Future<String?> _readSystemText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static Future<void> _writeSystemText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static String _randomId(int length) {
    final random = Random.secure();
    const hex = '0123456789ABCDEF';
    return List.generate(length, (_) => hex[random.nextInt(16)]).join();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _record(String event, String detail) {
    if (_disposed) return;
    if (_entries.length == maxEntries) _entries.removeAt(0);
    _entries.add(ClipboardDiagnosticEntry(_now(), event, detail));
    _changed();
  }

  void startListener() {
    if (_disposed || _listening) return;
    if (!deviceIdentityReady) throw StateError('Device identity is required');
    _listenerCode = _makeId(8);
    _epoch++;
    _reads = 0;
    _reading = false;
    _listening = true;
    _lastTextSignature = null;
    _seenRequests.clear();
    _expiresAt = _now().add(listenerLifetime);
    _expiryTimer = Timer(listenerLifetime, () {
      _record('expired', 'Listener expired.');
      stopListener();
    });
    _startPolling();
    _record(
      'started',
      'Listener enabled; only known, addressed tests can write replies.',
    );
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_listening || !_foreground || _disposed) return;
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(inspectNow()));
  }

  void stopListener() {
    cancelRun();
    _epoch++;
    _reads = 0;
    _reading = false;
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _expiresAt = null;
    final wasListening = _listening;
    _listening = false;
    _seenRequests.clear();
    if (wasListening) _record('stopped', 'Listener stopped.');
    _changed();
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _epoch++;
    _reads = 0;
    _reading = false;
    if (!value) cancelRun();
    _startPolling();
    if (_listening) {
      _record(
        value ? 'resumed' : 'paused',
        value
            ? 'Clipboard observation resumed.'
            : 'Clipboard observation paused in background.',
      );
    }
  }

  bool _active(int epoch) =>
      !_disposed && _listening && _foreground && epoch == _epoch;

  Future<void> inspectNow() async {
    if (!_listening ||
        !_foreground ||
        _disposed ||
        _reading ||
        _reads != 0 ||
        _writes != 0) {
      return;
    }
    final epoch = _epoch;
    _reading = true;
    try {
      final text = await _read().timeout(operationTimeout);
      if (!_active(epoch)) return;
      // The hash is only an ephemeral change detector, never exported.
      final signature = (text?.length ?? -1, text?.hashCode ?? 0);
      if (_readFailed || signature != _lastTextSignature) {
        _readFailed = false;
        _lastTextSignature = signature;
        _record(
          'observed',
          text == null
              ? 'No readable plain text; empty, non-text, or OS access unavailable.'
              : 'Readable plain text: ${text.length} UTF-16 code units.',
        );
      }
      final probe = _Probe.parse(text);
      if (probe == null || probe.target != _listenerCode) return;
      if (probe.origin == _originFor(probe.run)) {
        if (signature != _lastRejectedSignature) {
          _lastRejectedSignature = signature;
          _record(
            'same-device-rejected',
            'Test came from another window on this device; remote transfer cannot be verified.',
          );
        }
        return;
      }
      final pending = _pending;
      if (probe.reply) {
        if (pending != null &&
            probe.source == pending.target &&
            probe.run == pending.run &&
            probe.probe == pending.probe) {
          _finishCase(
            'passed',
            'Other device verified the forward payload; distinct return verified here.',
          );
        }
        return;
      }
      if (_running || probe.source == _listenerCode) return;
      final key = '${probe.source}:${probe.run}:${probe.probe.name}';
      if (_seenRequests.contains(key)) return;

      // Do not replace a newer copy made while this asynchronous read was in
      // flight. OS clipboard APIs offer no portable atomic compare-and-set.
      final current = await _read().timeout(operationTimeout);
      if (!_active(epoch) || _running || current != text) return;
      if (_seenRequests.length == _maxSeenRequests) {
        _seenRequests.remove(_seenRequests.first);
      }
      _seenRequests.add(key);
      _record(
        'forward-verified',
        '${probe.probe.label}: received exact test from ${probe.source}; run=${probe.run}.',
      );
      if (!_active(epoch) || _running) return;
      final reply = _Probe(
        source: _listenerCode,
        target: probe.source,
        run: probe.run,
        probe: probe.probe,
        reply: true,
        origin: _originFor(probe.run),
      );
      try {
        await _write(reply.encode()).timeout(operationTimeout);
        if (!_active(epoch)) return;
        _record(
          'return-written',
          '${probe.probe.label}: reply copied; arrival at the other device is unverified.',
        );
      } catch (_) {
        if (_active(epoch)) {
          _record(
            'write-error',
            'Could not copy test reply; clipboard unavailable.',
          );
        }
      }
    } catch (_) {
      if (_active(epoch) && !_readFailed) {
        _readFailed = true;
        _record(
          'read-error',
          'Clipboard read failed or timed out. Check foreground state and OS clipboard permission.',
        );
      }
    } finally {
      if (epoch == _epoch) _reading = false;
    }
  }

  Future<void> _write(String text) async {
    _writes++;
    try {
      await _writeText(text);
    } finally {
      _writes--;
    }
  }

  Future<String?> _read() async {
    final epoch = _epoch;
    _reads++;
    try {
      return await _readText();
    } finally {
      if (epoch == _epoch) _reads--;
    }
  }

  Future<void> runSuite(String targetCode) async {
    final target = targetCode.trim().toUpperCase();
    if (_disposed ||
        _running ||
        _writes != 0 ||
        !_foreground ||
        !_codePattern.hasMatch(target)) {
      throw StateError('Listener code or lifecycle unavailable');
    }
    if (_listening && target == _listenerCode) {
      throw StateError('Use the other device listener code');
    }
    startListener();
    if (target == _listenerCode) {
      throw StateError('Use the other device listener code');
    }
    final generation = ++_runGeneration;
    final epoch = _epoch;
    final run = _makeId(32);
    _running = true;
    _results.clear();
    _record(
      'run-started',
      'Target=$target; run=$run. Testing normal clipboard synchronization.',
    );
    try {
      for (final probe in ClipboardProbeCase.values) {
        if (!_active(epoch) || generation != _runGeneration) break;
        final pending = _PendingProbe(target, run, probe, _now());
        _pending = pending;
        _results.add(
          ClipboardProbeResult(
            probe: probe,
            status: 'running',
            detail: 'Waiting for verified return.',
          ),
        );
        _changed();
        if (!_active(epoch) || generation != _runGeneration) break;
        _caseTimer = Timer(caseTimeout, () {
          if (identical(_pending, pending)) {
            _finishCase(
              'timeout',
              'No verified return. Both directions are unverified; inspect the other device’s report.',
            );
          }
        });
        try {
          await _write(
            _Probe(
              source: _listenerCode,
              target: target,
              run: run,
              probe: probe,
              reply: false,
              origin: _originFor(run),
            ).encode(),
          ).timeout(operationTimeout);
        } catch (_) {
          if (identical(_pending, pending)) {
            _finishCase(
              'error',
              'Could not copy the test payload; clipboard unavailable.',
            );
          }
          // An OS write already issued cannot be cancelled. Do not start a
          // later fixture while it may still complete and replace its data.
          break;
        }
        await pending.done.future;
      }
    } finally {
      if (generation == _runGeneration) {
        _running = false;
        _pending = null;
        _caseTimer?.cancel();
        _record(
          'run-finished',
          'Test run finished. Only verified round trips count as passed.',
        );
      }
    }
  }

  void _finishCase(String status, String detail) {
    final pending = _pending;
    if (pending == null) return;
    _caseTimer?.cancel();
    _pending = null;
    _results[_results.length - 1] = ClipboardProbeResult(
      probe: pending.probe,
      status: status,
      detail: detail,
      elapsedMs: _now().difference(pending.started).inMilliseconds,
    );
    _record(status, '${pending.probe.label}: $detail');
    if (!pending.done.isCompleted) pending.done.complete();
  }

  void cancelRun() {
    if (!_running) return;
    _runGeneration++;
    _finishCase(
      'cancelled',
      'Test cancelled; unconfirmed directions remain unverified.',
    );
    _running = false;
    _changed();
  }

  void clear() {
    if (_running) return;
    _results.clear();
    _entries.clear();
    // Preserve deduplication: clearing the report must not replay a request.
    _changed();
  }

  String exportReport() => const JsonEncoder.withIndent('  ').convert({
    'report_kind': 'rustadmin-clipboard-diagnostics',
    'report_version': 1,
    'listener_code': _listenerCode,
    'listening': _listening,
    'foreground': _foreground,
    'running': _running,
    'expires_at': _expiresAt?.toUtc().toIso8601String(),
    'coverage':
        'Text fixtures only; native URL types, HTML/RTF, images, files and application paste are not tested.',
    'direction_evidence':
        'A verified distinct return proves both directions. A missing return leaves both unverified.',
    'line_endings':
        'CRLF and LF are treated as equivalent; other text must match exactly.',
    'results': _results.map((r) => r.toJson()).toList(),
    'events': _entries.map((e) => e.toJson()).toList(),
  });

  @override
  void dispose() {
    _disposed = true;
    stopListener();
    super.dispose();
  }
}

class _PendingProbe {
  _PendingProbe(this.target, this.run, this.probe, this.started);
  final String target;
  final String run;
  final ClipboardProbeCase probe;
  final DateTime started;
  final done = Completer<void>();
}

class _Probe {
  const _Probe({
    required this.source,
    required this.target,
    required this.run,
    required this.probe,
    required this.reply,
    required this.origin,
  });
  final String source;
  final String target;
  final String run;
  final ClipboardProbeCase probe;
  final bool reply;
  final String origin;

  String get payload => switch (probe) {
    ClipboardProbeCase.plainText =>
      reply
          ? 'RustAdmin return clipboard: verified on the other device.'
          : 'RustAdmin forward clipboard: plain text test.',
    ClipboardProbeCase.urlText =>
      reply
          ? 'https://example.invalid/clipboard/return?test=1&value=a%20b#reply'
          : 'https://example.invalid/clipboard/forward?test=1&value=a%20b#request',
    ClipboardProbeCase.unicodeText =>
      reply
          ? 'Return: 日本語 カタカナ\nРусский: ответ\t🙂 🚀\nAccent: é / e\u0301\n~ _ \\ " \' '
          : 'Forward: 日本語 ひらがな\nРусский: проверка\t🙂 🌍\nAccent: é / e\u0301\n~ _ \\ " \' ',
  };

  String encode() =>
      '${ClipboardDiagnostics._prefix}${jsonEncode({'source': source, 'target': target, 'run': run, 'case': probe.name, 'reply': reply, 'origin': origin})}\n\n$payload';

  static _Probe? parse(String? text) {
    if (text == null || text.length > ClipboardDiagnostics._maxProbeLength) {
      return null;
    }
    final normalized = text.replaceAll('\r\n', '\n');
    if (!normalized.startsWith(ClipboardDiagnostics._prefix)) return null;
    final end = normalized.indexOf('\n\n', ClipboardDiagnostics._prefix.length);
    if (end < 0) return null;
    try {
      final fields = jsonDecode(
        normalized.substring(ClipboardDiagnostics._prefix.length, end),
      );
      if (fields is! Map<String, dynamic> ||
          fields.length != 6 ||
          fields['source'] is! String ||
          fields['target'] is! String ||
          fields['run'] is! String ||
          fields['reply'] is! bool ||
          fields['origin'] is! String ||
          !ClipboardDiagnostics._originPattern.hasMatch(
            fields['origin'] as String,
          ) ||
          !ClipboardDiagnostics._codePattern.hasMatch(
            fields['source'] as String,
          ) ||
          !ClipboardDiagnostics._codePattern.hasMatch(
            fields['target'] as String,
          ) ||
          !ClipboardDiagnostics._runPattern.hasMatch(fields['run'] as String)) {
        return null;
      }
      final probe = ClipboardProbeCase.values
          .where((p) => p.name == fields['case'])
          .firstOrNull;
      if (probe == null) return null;
      final decoded = _Probe(
        source: fields['source'] as String,
        target: fields['target'] as String,
        run: fields['run'] as String,
        probe: probe,
        reply: fields['reply'] as bool,
        origin: fields['origin'] as String,
      );
      return decoded.encode() == normalized ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
