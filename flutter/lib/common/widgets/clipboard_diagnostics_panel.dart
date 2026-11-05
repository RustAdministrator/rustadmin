import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart' hide Dialog;
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart' show bind;
import '../clipboard_diagnostics.dart';

// Temporary diagnostic surface. Disable this single gate to hide all entries.
const kClipboardDiagnosticsEnabled = true;

class _ClipboardDiagnosticsLifecycle with WidgetsBindingObserver {
  _ClipboardDiagnosticsLifecycle() {
    WidgetsBinding.instance.addObserver(this);
    didChangeAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
  }

  static _ClipboardDiagnosticsLifecycle? _instance;

  static void ensureInitialized() {
    _instance ??= _ClipboardDiagnosticsLifecycle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop listeners must continue while the user copies in another app.
    // Mobile clipboard access and Dart execution depend on foreground state.
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      ClipboardDiagnostics.instance.setForeground(
        state == AppLifecycleState.resumed,
      );
    }
  }
}

Future<void> showClipboardDiagnostics(BuildContext context) async {
  _ClipboardDiagnosticsLifecycle.ensureInitialized();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Column(
          children: [
            ListTile(
              title: const Text('Debug: Clipboard'),
              trailing: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ),
            const Expanded(child: ClipboardDiagnosticsPanel()),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSessionClipboardDiagnostics(
  BuildContext context,
  FFI ffi, {
  bool showTests = false,
}) async {
  // Let the toolbar finish closing before releasing native remote input.
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return;
  _ClipboardDiagnosticsLifecycle.ensureInitialized();
  ffi.inputModel.enterOrLeave(false);
  void onSessionChanged() {
    if (ffi.ffiModel.secure == null ||
        ffi.ffiModel.viewOnly ||
        ffi.ffiModel.permissions['clipboard'] == false) {
      ClipboardDiagnostics.instance.cancelRun();
    }
  }

  ffi.ffiModel.addListener(onSessionChanged);
  try {
    // A modal route prevents the underlying remote canvas from reclaiming
    // Flutter keyboard focus after the toolbar menu closes.
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 720,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
            ),
            child: Column(
              children: [
                ListTile(
                  title: const Text('Debug: Clipboard'),
                  trailing: IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
                Expanded(
                  child: ClipboardDiagnosticsPanel(
                    sessionLabel: ffi.id,
                    showTests: showTests,
                    runBlockedReason: () {
                      final model = ffi.ffiModel;
                      if (model.secure == null) {
                        return 'Connect before testing.';
                      }
                      if (model.viewOnly ||
                          model.permissions['clipboard'] == false) {
                        return 'Clipboard transfer is unavailable for this session.';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  } finally {
    ffi.ffiModel.removeListener(onSessionChanged);
    ClipboardDiagnostics.instance.cancelRun();
    if (context.mounted) ffi.inputModel.refreshMousePos();
  }
}

class ClipboardDiagnosticsPanel extends StatefulWidget {
  const ClipboardDiagnosticsPanel({
    super.key,
    this.controller,
    this.sessionLabel,
    this.showTests = false,
    this.runBlockedReason,
  });

  final ClipboardDiagnostics? controller;
  final String? sessionLabel;
  final bool showTests;
  final String? Function()? runBlockedReason;

  @override
  State<ClipboardDiagnosticsPanel> createState() =>
      _ClipboardDiagnosticsPanelState();
}

class _ClipboardDiagnosticsPanelState extends State<ClipboardDiagnosticsPanel> {
  late final _diagnostics = widget.controller ?? ClipboardDiagnostics.instance;
  final _targetCode = TextEditingController();
  String? _notice;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ClipboardDiagnosticsLifecycle.ensureInitialized();
    }
  }

  @override
  void dispose() {
    _targetCode.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final blocked = widget.runBlockedReason?.call();
    if (blocked != null) {
      setState(() => _notice = blocked);
      return;
    }
    setState(() => _notice = null);
    try {
      await _prepareDeviceIdentity();
      if (!mounted) return;
      final latestBlock = widget.runBlockedReason?.call();
      if (latestBlock != null) {
        setState(() => _notice = latestBlock);
        return;
      }
      await _diagnostics.runSuite(_targetCode.text.trim());
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Could not start. Check the other device’s listener code and clipboard access.',
        );
      }
    }
  }

  Future<void> _prepareDeviceIdentity() async {
    if (_diagnostics.deviceIdentityReady) return;
    final identity = await bind.mainGetUuid().timeout(
      const Duration(seconds: 3),
    );
    _diagnostics.setDeviceIdentity(identity);
  }

  Future<void> _toggleListener(bool enabled) async {
    if (!enabled) {
      _diagnostics.stopListener();
      return;
    }
    try {
      await _prepareDeviceIdentity();
      if (mounted) _diagnostics.startListener();
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Could not identify this device. Retry before starting the listener.',
        );
      }
    }
  }

  Future<void> _copyReport() async {
    try {
      final report = jsonDecode(_diagnostics.exportReport());
      final output = const JsonEncoder.withIndent(
        '  ',
      ).convert({'platform': defaultTargetPlatform.name, 'report': report});
      await Clipboard.setData(ClipboardData(text: output));
      if (mounted) setState(() => _notice = 'Report copied.');
    } catch (_) {
      if (mounted) setState(() => _notice = 'Could not copy the report.');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _diagnostics,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Clipboard listener',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Temporary test tool for Windows, macOS, Linux, iOS and Android. '
          'Keep RustAdmin open on both devices. On mobile, keep it in the foreground '
          'and allow clipboard access when requested.',
        ),
        SwitchListTile(
          key: const ValueKey('clipboard-listener-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable clipboard listener'),
          subtitle: const Text('Stops after 10 minutes or when the app exits.'),
          value: _diagnostics.listening,
          onChanged: _toggleListener,
        ),
        if (_diagnostics.listening) ...[
          SelectableText(
            'This device’s listener code: ${_diagnostics.listenerCode}',
            key: const ValueKey('clipboard-listener-code'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!_diagnostics.foreground)
            const Text('Paused while RustAdmin is in the background.'),
        ],
        const SizedBox(height: 8),
        const Text(
          'The listener records text availability, size and test results, never '
          'your clipboard contents. While enabled, it responds only to tests '
          'addressed to its code. Replies replace this device’s clipboard.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Stopping prevents new operations; an OS clipboard write already in progress may still finish.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _diagnostics.listening && !_diagnostics.running
                  ? () => _diagnostics.inspectNow()
                  : null,
              child: const Text('Inspect now'),
            ),
            OutlinedButton(
              onPressed: _diagnostics.running ? null : _diagnostics.clear,
              child: const Text('Clear results'),
            ),
            OutlinedButton(
              onPressed: _diagnostics.running ? null : _copyReport,
              child: const Text('Copy report'),
            ),
          ],
        ),
        if (widget.controller == null) ...[
          const SizedBox(height: 8),
          const _NativeClipboardDiagnosticsToggle(),
        ],
        const Divider(height: 28),
        if (widget.sessionLabel != null) ...[
          Text('Connection: ${widget.sessionLabel}'),
          const SizedBox(height: 8),
          Text(
            'Test both directions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '1. On the other device, open Settings → Debug and enable its listener.\n'
            '2. Enter its listener code below. Keep clipboard transfer enabled in both directions.\n'
            '3. Run the test without copying anything else until it finishes.\n'
            'Test one pair at a time; other connected sessions may also receive test data.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('clipboard-target-code'),
            controller: _targetCode,
            enabled: !_diagnostics.running,
            autofocus: widget.showTests,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 8,
            decoration: const InputDecoration(
              labelText: 'Other device’s listener code',
              border: OutlineInputBorder(),
            ),
          ),
          const Text(
            'Running tests replaces the clipboard on BOTH devices with test data. '
            'Previous clipboard contents are not restored.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('clipboard-run-both-directions'),
                onPressed: _diagnostics.running ? null : _run,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Run both directions'),
              ),
              if (_diagnostics.running)
                OutlinedButton(
                  onPressed: _diagnostics.cancelRun,
                  child: const Text('Cancel'),
                ),
            ],
          ),
        ] else
          const Text(
            'Start a test from the connection toolbar: Debug → Clipboard tests. '
            'Use this listener code to target this device.',
          ),
        if (_notice != null) ...[const SizedBox(height: 8), Text(_notice!)],
        const SizedBox(height: 16),
        const Text(
          'A pass requires the other device to read the exact test text, then '
          'this device to read a different return payload. Without a return, '
          'both directions remain unverified; compare the other device’s report. '
          'Clipboard policy is never changed by this tool.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Coverage: plain text, URL as text, Japanese/Russian/emoji and multiline text. '
          'Not tested: native URL formats, HTML/RTF, images, files, or paste behavior '
          'inside individual applications.',
        ),
        const Divider(height: 28),
        Text(
          'Results and listener log',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_diagnostics.results.isEmpty)
          const Text('No tests run in this window yet.'),
        for (final result in _diagnostics.results)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.probe.label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text('This device → Other device: ${result.forward}'),
                  Text('Other device → This device: ${result.reverse}'),
                  const SizedBox(height: 4),
                  Text(result.detail),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (_diagnostics.entries.isEmpty)
          const Text('The listener is off until you enable it.'),
        for (final entry in _diagnostics.entries.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${entry.time.toLocal().toIso8601String().substring(11, 19)}  ${entry.detail}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );
}

class _NativeClipboardDiagnosticsToggle extends StatefulWidget {
  const _NativeClipboardDiagnosticsToggle();

  @override
  State<_NativeClipboardDiagnosticsToggle> createState() =>
      _NativeClipboardDiagnosticsToggleState();
}

class _NativeClipboardDiagnosticsToggleState
    extends State<_NativeClipboardDiagnosticsToggle> {
  late bool _enabled = mainGetLocalBoolOptionSync(kOptionAllowClipboardDebug);

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('Record native clipboard diagnostics'),
    subtitle: const Text(
      'Adds available format and transfer-policy details to the app’s diagnostic logs '
      'where supported. Useful when a Safari link fails but plain text succeeds.',
    ),
    value: _enabled,
    onChanged: isOptionFixed(kOptionAllowClipboardDebug)
        ? null
        : (value) async {
            await mainSetLocalBoolOption(kOptionAllowClipboardDebug, value);
            if (mounted) {
              setState(
                () => _enabled = mainGetLocalBoolOptionSync(
                  kOptionAllowClipboardDebug,
                ),
              );
            }
          },
  );
}
