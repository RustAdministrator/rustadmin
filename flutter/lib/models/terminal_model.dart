import 'dart:async';
import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:xterm/xterm.dart';

import 'model.dart';
import 'platform_model.dart';
import 'session_event.dart';

class TerminalModel with ChangeNotifier {
  final String id; // peer id
  final FFI parent;
  final int terminalId;
  late final Terminal terminal;
  late final TerminalController terminalController;

  bool _terminalOpened = false;
  bool get terminalOpened => _terminalOpened;

  bool _disposed = false;

  final _inputBuffer = <String>[];
  // Buffer for output data received before terminal view has valid dimensions.
  // This prevents NaN errors when writing to terminal before layout is complete.
  final _pendingOutputChunks = <String>[];
  int _pendingOutputSize = 0;
  static const int _kMaxOutputBufferChars = 8 * 1024;
  // View ready state: true when terminal has valid dimensions, safe to write
  bool _terminalViewReady = false;

  bool get isPeerWindows => parent.ffiModel.pi.platform == kPeerPlatformWindows;

  void Function(int w, int h, int pw, int ph)? onResizeExternal;

  Future<void> _handleInput(String data) async {
    // If we press the `Enter` button on Android,
    // `data` can be '\r' or '\n' when using different keyboards.
    // Android -> Windows. '\r' works, but '\n' does not. '\n' is just a newline.
    // Android -> Linux. Both '\r' and '\n' work as expected (execute a command).
    // So when we receive '\n', we may need to convert it to '\r' to ensure compatibility.
    // Desktop -> Desktop works fine.
    // Check if we are on mobile or web(mobile), and convert '\n' to '\r'.
    final isMobileOrWebMobile = (isMobile || (isWeb && !isWebDesktop));
    if (isMobileOrWebMobile && isPeerWindows && data == '\n') {
      data = '\r';
    }
    if (_terminalOpened) {
      // Send user input to remote terminal
      try {
        await bind.sessionSendTerminalInput(
          sessionId: parent.sessionId,
          terminalId: terminalId,
          data: data,
        );
      } catch (e) {
        debugPrint('[TerminalModel] Error sending terminal input: $e');
      }
    } else {
      debugPrint('[TerminalModel] Terminal not opened yet, buffering input');
      _inputBuffer.add(data);
    }
  }

  TerminalModel(this.parent, [this.terminalId = 0]) : id = parent.id {
    terminal = Terminal(maxLines: 10000);
    terminalController = TerminalController();

    // Setup terminal callbacks
    terminal.onOutput = _handleInput;

    terminal.onResize = (w, h, pw, ph) async {
      // Validate all dimensions before using them
      if (w > 0 && h > 0 && pw > 0 && ph > 0) {
        debugPrint(
            '[TerminalModel] Terminal resized to ${w}x$h (pixel: ${pw}x$ph)');

        // This piece of code must be placed before the conditional check in order to initialize properly.
        onResizeExternal?.call(w, h, pw, ph);

        // Mark terminal view as ready and flush any buffered output on first valid resize.
        // Must be after onResizeExternal so the view layer has valid dimensions before flushing.
        if (!_terminalViewReady) {
          _markViewReady();
        }

        if (_terminalOpened) {
          // Notify remote terminal of resize
          try {
            await bind.sessionResizeTerminal(
              sessionId: parent.sessionId,
              terminalId: terminalId,
              rows: h,
              cols: w,
            );
          } catch (e) {
            debugPrint('[TerminalModel] Error resizing terminal: $e');
          }
        }
      } else {
        debugPrint(
            '[TerminalModel] Invalid terminal dimensions: ${w}x$h (pixel: ${pw}x$ph)');
      }
    };
  }

  void onReady() {
    parent.dialogManager.dismissAll();

    // Fire and forget - don't block onReady
    openTerminal().catchError((e) {
      debugPrint('[TerminalModel] Error opening terminal: $e');
    });
  }

  Future<void> openTerminal() async {
    if (_terminalOpened) return;
    // Request the remote side to open a terminal with default shell
    // The remote side will decide which shell to use based on its OS

    // Get terminal dimensions, ensuring they are valid
    int rows = 24;
    int cols = 80;

    if (terminal.viewHeight > 0) {
      rows = terminal.viewHeight;
    }
    if (terminal.viewWidth > 0) {
      cols = terminal.viewWidth;
    }

    debugPrint(
        '[TerminalModel] Opening terminal $terminalId, sessionId: ${parent.sessionId}, size: ${cols}x$rows');
    try {
      await bind
          .sessionOpenTerminal(
        sessionId: parent.sessionId,
        terminalId: terminalId,
        rows: rows,
        cols: cols,
      )
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
              'sessionOpenTerminal timed out after 5 seconds');
        },
      );
      debugPrint('[TerminalModel] sessionOpenTerminal called successfully');
    } catch (e) {
      debugPrint('[TerminalModel] Error calling sessionOpenTerminal: $e');
      // Optionally show error to user
      if (e is TimeoutException) {
        _writeToTerminal('Failed to open terminal: Connection timeout\r\n');
      }
    }
  }

  Future<void> sendVirtualKey(String data) async {
    return _handleInput(data);
  }

  Future<void> closeTerminal() async {
    if (_terminalOpened) {
      try {
        await bind
            .sessionCloseTerminal(
          sessionId: parent.sessionId,
          terminalId: terminalId,
        )
            .timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            throw TimeoutException(
                'sessionCloseTerminal timed out after 3 seconds');
          },
        );
        debugPrint('[TerminalModel] sessionCloseTerminal called successfully');
      } catch (e) {
        debugPrint('[TerminalModel] Error calling sessionCloseTerminal: $e');
        // Continue with cleanup even if close fails
      }
      _terminalOpened = false;
      notifyListeners();
    }
  }

  void handleTerminalResponseEvent(TerminalResponseSessionEvent event) {
    // Only handle events for this terminal
    if (event.terminalId != terminalId) {
      debugPrint(
          '[TerminalModel] Ignoring event for terminal ${event.terminalId} (not mine)');
      return;
    }

    switch (event.kind) {
      case TerminalResponseKind.opened:
        _handleTerminalOpened(event);
      case TerminalResponseKind.data:
        _handleTerminalData(event);
      case TerminalResponseKind.closed:
        _handleTerminalClosed(event);
      case TerminalResponseKind.error:
        _handleTerminalError(event);
    }
  }

  void _handleTerminalOpened(TerminalResponseSessionEvent event) {
    final success = event.success;
    final message = event.message;
    final serviceId = event.serviceId;

    debugPrint(
        '[TerminalModel] Terminal opened response: success=$success, message=$message, service_id=$serviceId');

    if (success) {
      _terminalOpened = true;

      // On reconnect ("Reconnected to existing terminal"), server may replay recent output.
      // If this TerminalView instance is reused (not rebuilt), duplicate lines can appear.
      // We intentionally accept this tradeoff for now to keep logic simple.

      // Fallback: if terminal view is not yet ready but already has valid
      // dimensions (e.g. layout completed before open response arrived),
      // mark view ready now to avoid output stuck in buffer indefinitely.
      if (!_terminalViewReady &&
          terminal.viewWidth > 0 &&
          terminal.viewHeight > 0) {
        _markViewReady();
      }

      // Process any buffered input
      _processBufferedInputAsync().then((_) {
        notifyListeners();
      }).catchError((e) {
        debugPrint('[TerminalModel] Error processing buffered input: $e');
        notifyListeners();
      });

      final persistentSessions = event.persistentSessionIds;
      if (kWindowId != null && persistentSessions.isNotEmpty) {
        DesktopMultiWindow.invokeMethod(
            kWindowId!,
            kWindowEventRestoreTerminalSessions,
            jsonEncode({
              'persistent_sessions': persistentSessions,
            }));
      }
    } else {
      _writeToTerminal('Failed to open terminal: $message\r\n');
    }
  }

  Future<void> _processBufferedInputAsync() async {
    final buffer = List<String>.from(_inputBuffer);
    _inputBuffer.clear();

    for (final data in buffer) {
      try {
        await bind.sessionSendTerminalInput(
          sessionId: parent.sessionId,
          terminalId: terminalId,
          data: data,
        );
      } catch (e) {
        debugPrint('[TerminalModel] Error sending buffered input: $e');
      }
    }
  }

  void _handleTerminalData(TerminalResponseSessionEvent event) {
    _writeToTerminal(utf8.decode(event.data, allowMalformed: true));
  }

  /// Write text to terminal, buffering if the view is not yet ready.
  /// All terminal output should go through this method to avoid NaN errors
  /// from writing before the terminal view has valid layout dimensions.
  void _writeToTerminal(String text) {
    if (!_terminalViewReady) {
      // If a single chunk exceeds the cap, keep only its tail.
      // Note: truncation may split a multi-byte ANSI escape sequence,
      // which can cause a brief visual glitch on flush. This is acceptable
      // because it only affects the pre-layout buffering window and the
      // terminal will self-correct on subsequent output.
      if (text.length >= _kMaxOutputBufferChars) {
        final truncated = text.substring(text.length - _kMaxOutputBufferChars);
        _pendingOutputChunks
          ..clear()
          ..add(truncated);
        _pendingOutputSize = truncated.length;
      } else {
        _pendingOutputChunks.add(text);
        _pendingOutputSize += text.length;
        // Drop oldest chunks if exceeds limit (whole chunks to preserve ANSI sequences)
        while (_pendingOutputSize > _kMaxOutputBufferChars &&
            _pendingOutputChunks.length > 1) {
          final removed = _pendingOutputChunks.removeAt(0);
          _pendingOutputSize -= removed.length;
        }
      }
      return;
    }
    terminal.write(text);
  }

  void _flushOutputBuffer() {
    if (_pendingOutputChunks.isEmpty) return;
    debugPrint(
        '[TerminalModel] Flushing $_pendingOutputSize buffered chars (${_pendingOutputChunks.length} chunks)');
    for (final chunk in _pendingOutputChunks) {
      terminal.write(chunk);
    }
    _pendingOutputChunks.clear();
    _pendingOutputSize = 0;
  }

  /// Mark terminal view as ready and flush buffered output.
  void _markViewReady() {
    if (_terminalViewReady) return;
    _terminalViewReady = true;
    _flushOutputBuffer();
  }

  void _handleTerminalClosed(TerminalResponseSessionEvent event) {
    _writeToTerminal(
        '\r\nTerminal closed with exit code: ${event.exitCode}\r\n');
    _terminalOpened = false;
    notifyListeners();
  }

  void _handleTerminalError(TerminalResponseSessionEvent event) {
    _writeToTerminal('\r\nTerminal error: ${event.message}\r\n');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Clear buffers to free memory
    _inputBuffer.clear();
    _pendingOutputChunks.clear();
    _pendingOutputSize = 0;
    // Terminal cleanup is handled server-side when service closes
    super.dispose();
  }
}
