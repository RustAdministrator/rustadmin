import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Receives the desired outer window size after the child has been measured.
typedef ContentSizedWindowResizeCallback = FutureOr<void> Function(Size size);

/// Returns the maximum outer window height available on the current display.
typedef ContentSizedWindowHeightCallback = FutureOr<double?> Function();

/// Coordinates the first measured layout with the native window startup.
///
/// The [ready] future completes after the first size request has finished. A
/// caller can await it before showing a window whose initial size is only a
/// placeholder.
class ContentSizedWindowController {
  ContentSizedWindowController({
    this.onSizeChanged,
    this.availableHeight,
    this.nativeChromeHeight,
  });

  final ContentSizedWindowResizeCallback? onSizeChanged;
  final ContentSizedWindowHeightCallback? availableHeight;
  final ContentSizedWindowHeightCallback? nativeChromeHeight;

  final Completer<void> _readyCompleter = Completer<void>();

  Future<void> get ready => _readyCompleter.future;

  bool get isReady => _readyCompleter.isCompleted;

  void _markReady() {
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }
}

/// Measures a padded body at its actual width and requests a fitting outer
/// window size. If the requested height is capped, the body remains in the
/// scroll view and can be reached without changing the native window again.
class ContentSizedWindow extends StatefulWidget {
  const ContentSizedWindow({
    Key? key,
    required this.child,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.onSizeChanged,
    this.availableHeight,
    this.nativeChromeHeight,
    this.additionalWindowHeight = 0,
    this.minimumWindowHeight = 0,
  }) : assert(additionalWindowHeight >= 0),
       assert(minimumWindowHeight >= 0),
       super(key: key);

  final Widget child;
  final ContentSizedWindowController? controller;
  final EdgeInsets padding;
  final ContentSizedWindowResizeCallback? onSizeChanged;
  final ContentSizedWindowHeightCallback? availableHeight;
  final ContentSizedWindowHeightCallback? nativeChromeHeight;

  /// Height rendered outside the measured body, such as a tab strip.
  final double additionalWindowHeight;

  final double minimumWindowHeight;

  @override
  State<ContentSizedWindow> createState() => _ContentSizedWindowState();
}

class _ContentSizedWindowState extends State<ContentSizedWindow> {
  final GlobalKey _bodyKey = GlobalKey();
  bool _measurementScheduled = false;
  bool _resizeInFlight = false;
  Size? _pendingSize;
  Size? _lastRequestedSize;
  double? _layoutWidth;

  ContentSizedWindowResizeCallback? get _onSizeChanged =>
      widget.onSizeChanged ?? widget.controller?.onSizeChanged;

  ContentSizedWindowHeightCallback? get _availableHeight =>
      widget.availableHeight ?? widget.controller?.availableHeight;

  ContentSizedWindowHeightCallback? get _nativeChromeHeight =>
      widget.nativeChromeHeight ?? widget.controller?.nativeChromeHeight;

  @override
  void initState() {
    super.initState();
    _scheduleMeasurement();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasurement();
  }

  @override
  void didUpdateWidget(covariant ContentSizedWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasurement();
  }

  @override
  void dispose() {
    widget.controller?._markReady();
    super.dispose();
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      unawaited(_measureAndQueueResizeSafely());
    });
  }

  Future<void> _measureAndQueueResizeSafely() async {
    try {
      await _measureAndQueueResize();
    } catch (error, stackTrace) {
      debugPrint('Content-sized window measurement failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      widget.controller?._markReady();
    }
  }

  Future<double?> _readHeightMetric(
    ContentSizedWindowHeightCallback? callback,
    String name,
  ) async {
    if (callback == null) return null;
    try {
      return await callback();
    } catch (error, stackTrace) {
      debugPrint('Content-sized window $name measurement failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<void> _measureAndQueueResize() async {
    final renderObject = _bodyKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      _scheduleMeasurement();
      return;
    }

    final bodySize = renderObject.size;
    final width = (_layoutWidth ?? bodySize.width).isFinite
        ? (_layoutWidth ?? bodySize.width)
        : bodySize.width;
    if (!width.isFinite || width <= 0 || !bodySize.height.isFinite) {
      _scheduleMeasurement();
      return;
    }

    final chromeHeight =
        _finiteNonNegative(
          await _readHeightMetric(_nativeChromeHeight, 'chrome'),
        ) ??
        0;
    final availableHeight = _finitePositive(
      await _readHeightMetric(_availableHeight, 'available-height'),
    );
    final additionalHeight =
        _finiteNonNegative(widget.additionalWindowHeight) ?? 0;
    final naturalHeight = bodySize.height + chromeHeight + additionalHeight;
    var requestedHeight = math.max(widget.minimumWindowHeight, naturalHeight);
    if (availableHeight != null) {
      requestedHeight = math.min(requestedHeight, availableHeight);
    }

    _queueResize(Size(width, requestedHeight));
  }

  static double? _finiteNonNegative(double? value) {
    if (value == null || !value.isFinite || value < 0) return null;
    return value;
  }

  static double? _finitePositive(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }

  static bool _sameSize(Size? left, Size right) {
    if (left == null) return false;
    const epsilon = 0.5;
    return (left.width - right.width).abs() < epsilon &&
        (left.height - right.height).abs() < epsilon;
  }

  void _queueResize(Size size) {
    final callback = _onSizeChanged;
    if (callback == null) {
      widget.controller?._markReady();
      return;
    }

    if (_resizeInFlight) {
      // The newest measurement supersedes any queued request. In particular,
      // if layout returns to the in-flight size, discard the stale request
      // instead of applying it after the current callback completes.
      _pendingSize = _sameSize(_lastRequestedSize, size) ? null : size;
      return;
    }

    if (_sameSize(_lastRequestedSize, size)) {
      widget.controller?._markReady();
      return;
    }

    if (_sameSize(_pendingSize, size)) return;

    _pendingSize = size;
    unawaited(_drainResizeRequests(callback));
  }

  Future<void> _drainResizeRequests(
    ContentSizedWindowResizeCallback callback,
  ) async {
    _resizeInFlight = true;
    try {
      while (mounted && _pendingSize != null) {
        final size = _pendingSize!;
        _pendingSize = null;
        if (_sameSize(_lastRequestedSize, size)) continue;
        _lastRequestedSize = size;
        try {
          await callback(size);
        } catch (error, stackTrace) {
          debugPrint('Content-sized window resize failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
        widget.controller?._markReady();
      }
    } finally {
      _resizeInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _layoutWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null;
        _scheduleMeasurement();

        Widget body = Padding(
          key: _bodyKey,
          padding: widget.padding,
          child: widget.child,
        );
        if (constraints.hasBoundedWidth) {
          body = SizedBox(width: constraints.maxWidth, child: body);
        }

        return NotificationListener<SizeChangedLayoutNotification>(
          onNotification: (_) {
            _scheduleMeasurement();
            return false;
          },
          child: SingleChildScrollView(
            child: SizeChangedLayoutNotifier(child: body),
          ),
        );
      },
    );
  }
}
