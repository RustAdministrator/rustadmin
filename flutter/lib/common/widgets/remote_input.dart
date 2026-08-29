import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/mobile/mobile_viewport.dart';

import './gestures.dart';
import './mobile_gesture_controller.dart';

class RawKeyFocusScope extends StatelessWidget {
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final InputModel inputModel;
  final Widget child;

  RawKeyFocusScope({
    this.focusNode,
    this.onFocusChange,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // https://github.com/flutter/flutter/issues/154053
    final useRawKeyEvents = isLinux && !isWeb;
    // FIXME: On Windows, `AltGr` will generate `Alt` and `Control` key events,
    // while `Alt` and `Control` are separated key events for en-US input method.
    return FocusScope(
      autofocus: true,
      child: Focus(
        autofocus: true,
        // Preserve focus guards managed by the remote page across rebuilds.
        canRequestFocus: focusNode?.canRequestFocus,
        focusNode: focusNode,
        onFocusChange: onFocusChange,
        onKey: useRawKeyEvents
            ? (FocusNode data, RawKeyEvent event) =>
                  inputModel.handleRawKeyEvent(event)
            : null,
        onKeyEvent: useRawKeyEvents
            ? null
            : (FocusNode node, KeyEvent event) =>
                  inputModel.handleKeyEvent(event),
        child: child,
      ),
    );
  }
}
Offset mobileCursorInertiaFrameDelta({
  required Offset velocityPixelsPerSecond,
  required Duration elapsedBeforeFrame,
  required Duration frameDuration,
  required Duration totalDuration,
}) {
  final totalMicroseconds = totalDuration.inMicroseconds;
  if (totalMicroseconds <= 0 || frameDuration <= Duration.zero) {
    return Offset.zero;
  }
  final midpointMicroseconds =
      elapsedBeforeFrame.inMicroseconds + frameDuration.inMicroseconds / 2;
  if (midpointMicroseconds >= totalMicroseconds) return Offset.zero;
  final decay = 1 - midpointMicroseconds / totalMicroseconds;
  final frameSeconds =
      frameDuration.inMicroseconds / Duration.microsecondsPerSecond;
  return velocityPixelsPerSecond * frameSeconds * decay;
}

Rect mobileRemoteInputLocalRect({
  required Rect globalRect,
  required Offset inputRegionGlobalOrigin,
}) {
  return globalRect.shift(-inputRegionGlobalOrigin);
}

class RawTouchGestureDetectorRegion extends StatefulWidget {
  final Widget child;
  final FFI ffi;
  final bool isCamera;
  final int cursorInertiaDurationMs;
  late final InputModel inputModel = ffi.inputModel;
  late final FfiModel ffiModel = ffi.ffiModel;

  RawTouchGestureDetectorRegion({
    super.key,
    required this.child,
    required this.ffi,
    this.isCamera = false,
    this.cursorInertiaDurationMs = kDefaultMobileCursorInertiaDurationMs,
  });

  @override
  State<RawTouchGestureDetectorRegion> createState() =>
      _RawTouchGestureDetectorRegionState();
}

/// Touch input maps one-finger tap/hold to the left button and two-finger
/// tap/hold to the right button. In touch mode the remote cursor moves to the
/// gesture position; in mouse mode it stays at its current remote position.
class _RawTouchGestureDetectorRegionState
    extends State<RawTouchGestureDetectorRegion> {
  Offset _cacheLongPressPosition = Offset(0, 0);
  // Timestamp of the last long press event.
  int _cacheLongPressPositionTs = 0;
  double _mouseScrollIntegral = 0; // mouse scroll speed controller
  final MobileWheelAccumulator _twoFingerWheel = MobileWheelAccumulator();

  // Workaround tap down event when two fingers are used to scale(mobile)
  TapDownDetails? _lastTapDownDetails;

  PointerDeviceKind? lastDeviceKind;

  // For touch mode, onDoubleTap
  // `onDoubleTap()` does not provide the position of the tap event.
  Offset _lastPosOfDoubleTapDown = Offset.zero;
  bool _touchModePanStarted = false;
  bool _leftLongPressRequested = false;
  bool _leftLongPressActive = false;
  Future<void>? _leftLongPressDownFuture;
  bool _legacyHoldDragActive = false;
  Future<void>? _legacyHoldDragDownFuture;
  bool _rightTwoFingerHoldRequested = false;
  bool _rightTwoFingerHoldActive = false;
  Future<void>? _rightTwoFingerDownFuture;
  Timer? _cursorInertiaTimer;
  Stopwatch? _cursorInertiaStopwatch;
  Duration _previousInertiaElapsed = Duration.zero;
  Offset _cursorInertiaVelocity = Offset.zero;
  Offset _cursorInertiaLocalPosition = Offset.zero;
  Offset _lastOneFingerPanPosition = Offset.zero;
  bool _cursorInertiaTickPending = false;
  int _cursorInertiaGeneration = 0;

  // For mouse mode, we need to block the events when the cursor is in a blocked area.
  // So we need to cache the last tap down position.
  Offset? _lastTapDownPositionForMouseMode;
  // Cache global position for onTap (which lacks position info).
  Offset? _lastTapDownGlobalPosition;
  bool _tapStartedBlocked = false;
  bool _doubleTapStartedBlocked = false;
  bool _leftHoldStartedBlocked = false;

  FFI get ffi => widget.ffi;
  FfiModel get ffiModel => widget.ffiModel;
  InputModel get inputModel => widget.inputModel;
  bool get handleTouch => (isDesktop || isWebDesktop) || ffiModel.touchMode;
  SessionID get sessionId => ffi.sessionId;

  bool _shouldBlockGesture(TapDownDetails details) {
    return ffi.cursorModel.shouldBlock(
          details.localPosition.dx,
          details.localPosition.dy,
        ) ||
        ffi.cursorModel.shouldBlockGlobal(
          details.globalPosition.dx,
          details.globalPosition.dy,
        );
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      child: widget.child,
      gestures: makeGestures(),
    );
  }

  @override
  void dispose() {
    _stopCursorInertia();
    _releasePressedButtons();
    super.dispose();
  }

  void _releasePressedButtons() {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    _leftLongPressRequested = false;
    if (_leftLongPressActive) {
      _leftLongPressActive = false;
      final down = _leftLongPressDownFuture ?? Future<void>.value();
      unawaited(down.then((_) => inputModel.tapUp(MouseButtons.left)));
    }
    if (_legacyHoldDragActive) {
      _legacyHoldDragActive = false;
      final down = _legacyHoldDragDownFuture ?? Future<void>.value();
      _legacyHoldDragDownFuture = null;
      unawaited(down.then((_) => inputModel.sendMouse('up', MouseButtons.left)));
    }
    _rightTwoFingerHoldRequested = false;
    if (_rightTwoFingerHoldActive) {
      _rightTwoFingerHoldActive = false;
      final down = _rightTwoFingerDownFuture ?? Future<void>.value();
      unawaited(down.then((_) => inputModel.tapUp(MouseButtons.right)));
    }
  }

  void _stopCursorInertia({bool cancelEdgeScroll = true}) {
    _cursorInertiaGeneration += 1;
    _cursorInertiaTimer?.cancel();
    _cursorInertiaTimer = null;
    _cursorInertiaStopwatch?.stop();
    _cursorInertiaStopwatch = null;
    _previousInertiaElapsed = Duration.zero;
    if (cancelEdgeScroll) ffi.canvasModel.cancelEdgeScroll();
  }

  bool _startCursorInertia(DragEndDetails details) {
    _stopCursorInertia(cancelEdgeScroll: false);
    final durationMs = widget.cursorInertiaDurationMs
        .clamp(
          kMinMobileCursorInertiaDurationMs,
          kMaxMobileCursorInertiaDurationMs,
        )
        .toInt();
    var velocity = details.velocity.pixelsPerSecond;
    if (durationMs <= 0 || velocity.distance < 50) {
      ffi.canvasModel.cancelEdgeScroll();
      return false;
    }
    const maximumVelocity = 3000.0;
    if (velocity.distance > maximumVelocity) {
      velocity = velocity / velocity.distance * maximumVelocity;
    }
    _cursorInertiaVelocity = velocity;
    _cursorInertiaLocalPosition = _lastOneFingerPanPosition;
    _previousInertiaElapsed = Duration.zero;
    _cursorInertiaStopwatch = Stopwatch()..start();
    final generation = _cursorInertiaGeneration;
    if (inputModel.useEdgeScroll) ffi.canvasModel.rearmEdgeScroll();
    _cursorInertiaTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _runCursorInertiaTick(generation, durationMs),
    );
    return true;
  }

  bool get _returnsAccelerationCursorToNeutral =>
      !handleTouch &&
      !inputModel.relativeMouseMode.value &&
      inputModel.useEdgeScroll &&
      ffi.canvasModel.scrollStyle == ScrollStyle.scrolledgeaccel;

  Future<void> _returnAccelerationCursorToNeutral() async {
    if (!_returnsAccelerationCursorToNeutral) return;
    final currentPosition = ffi.cursorModel.mobileViewportPosition;
    final targetPosition = mobileRemoteClampCursorToNeutralRegion(
      pointerPosition: currentPosition,
      viewport: ffi.canvasModel.size,
      edgeThickness: ffi.canvasModel.edgeScrollEdgeThickness.toDouble(),
      directions: ffi.canvasModel.mobileViewportScrollDirections,
    );
    final delta = targetPosition - currentPosition;
    if (delta == Offset.zero) return;
    await ffi.cursorModel.updatePan(delta, targetPosition, false);
  }

  Future<void> _runCursorInertiaTick(int generation, int durationMs) async {
    if (generation != _cursorInertiaGeneration || _cursorInertiaTickPending) {
      return;
    }
    final stopwatch = _cursorInertiaStopwatch;
    if (stopwatch == null) return;
    final totalDuration = Duration(milliseconds: durationMs);
    final elapsed = stopwatch.elapsed;
    final remaining = totalDuration - _previousInertiaElapsed;
    if (remaining <= Duration.zero) {
      _stopCursorInertia();
      return;
    }
    final frameDuration = elapsed >= totalDuration
        ? remaining
        : elapsed - _previousInertiaElapsed;
    final delta = mobileCursorInertiaFrameDelta(
      velocityPixelsPerSecond: _cursorInertiaVelocity,
      elapsedBeforeFrame: _previousInertiaElapsed,
      frameDuration: frameDuration,
      totalDuration: totalDuration,
    );
    _previousInertiaElapsed = elapsed;
    if (delta == Offset.zero) {
      _stopCursorInertia();
      return;
    }
    _cursorInertiaTickPending = true;
    try {
      _cursorInertiaLocalPosition += delta;
      if (inputModel.relativeMouseMode.value) {
        await inputModel.sendMobileRelativeMouseMove(delta.dx, delta.dy);
      } else {
        await ffi.cursorModel.updatePan(
          delta,
          _cursorInertiaLocalPosition,
          false,
        );
        if (_returnsAccelerationCursorToNeutral) {
          final currentPosition = ffi.cursorModel.mobileViewportPosition;
          final returnDelta = mobileRemoteAccelerationReturnDelta(
            pointerPosition: currentPosition,
            viewport: ffi.canvasModel.size,
            edgeThickness: ffi.canvasModel.edgeScrollEdgeThickness.toDouble(),
            directions: ffi.canvasModel.mobileViewportScrollDirections,
            frameDuration: frameDuration,
            remainingDuration: remaining,
          );
          if (returnDelta != Offset.zero) {
            _cursorInertiaLocalPosition += returnDelta;
            await ffi.cursorModel.updatePan(
              returnDelta,
              currentPosition + returnDelta,
              false,
            );
          }
        }
        if (inputModel.useEdgeScroll) {
          final edgePosition = ffi.cursorModel.mobileViewportPosition;
          ffi.canvasModel.edgeScrollMouse(edgePosition.dx, edgePosition.dy);
        }
      }
    } finally {
      _cursorInertiaTickPending = false;
    }
    if (generation == _cursorInertiaGeneration && elapsed >= totalDuration) {
      _stopCursorInertia();
    }
  }

  bool isNotTouchBasedDevice() {
    return !kTouchBasedDeviceKinds.contains(lastDeviceKind);
  }

  // Mobile, mouse mode.
  // Check if should block the mouse tap event (`_lastTapDownPositionForMouseMode`).
  bool shouldBlockMouseModeEvent() {
    return _tapStartedBlocked ||
        (_lastTapDownPositionForMouseMode != null &&
            ffi.cursorModel.shouldBlock(
              _lastTapDownPositionForMouseMode!.dx,
              _lastTapDownPositionForMouseMode!.dy,
            ));
  }

  onTapDown(TapDownDetails d) async {
    _stopCursorInertia();
    lastDeviceKind = d.kind;
    _lastTapDownGlobalPosition = d.globalPosition;
    _tapStartedBlocked = _shouldBlockGesture(d);
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      // Desktop or mobile "Touch mode"
      _lastTapDownDetails = d;
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onTapUp(TapUpDetails d) async {
    final TapDownDetails? lastTapDownDetails = _lastTapDownDetails;
    _lastTapDownDetails = null;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_tapStartedBlocked) return;
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    if (inputModel.shouldIgnoreTouchTap(d.globalPosition)) {
      return;
    }
    if (handleTouch) {
      final isMoved =
          await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
      if (isMoved) {
        // If pan already handled 'down', don't send it again.
        if (lastTapDownDetails != null && !_touchModePanStarted) {
          await inputModel.tapDown(MouseButtons.left);
        }
        await inputModel.tapUp(MouseButtons.left);
      }
    }
  }

  onTap() async {
    final startedBlocked = _tapStartedBlocked;
    _tapStartedBlocked = false;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (startedBlocked) return;
    // Filter duplicate touch tap events on iOS (Magic Mouse issue).
    final lastPos = _lastTapDownGlobalPosition;
    if (lastPos != null && inputModel.shouldIgnoreTouchTap(lastPos)) {
      return;
    }
    if (!handleTouch) {
      // Cannot use `_lastTapDownDetails` because Flutter calls `onTapUp` before `onTap`, clearing the cached details.
      // Using `_lastTapDownPositionForMouseMode` instead.
      if (shouldBlockMouseModeEvent()) {
        return;
      }
      // Mobile, "Mouse mode"
      await inputModel.tap(MouseButtons.left);
    }
  }

  void onTapCancel() {
    _tapStartedBlocked = false;
  }

  onDoubleTapDown(TapDownDetails d) async {
    _stopCursorInertia();
    lastDeviceKind = d.kind;
    _doubleTapStartedBlocked = _shouldBlockGesture(d);
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
    }
  }

  onDoubleTap() async {
    final startedBlocked = _doubleTapStartedBlocked;
    _doubleTapStartedBlocked = false;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (startedBlocked) return;
    if (ffiModel.touchMode && ffi.cursorModel.lastIsBlocked) {
      return;
    }
    if (handleTouch &&
        !ffi.cursorModel.isInRemoteRect(_lastPosOfDoubleTapDown)) {
      return;
    }
    // Check if the position is in a blocked area when using the mouse mode.
    if (!handleTouch) {
      if (shouldBlockMouseModeEvent()) {
        return;
      }
    }
    await inputModel.tap(MouseButtons.left);
    await inputModel.tap(MouseButtons.left);
  }

  onOneFingerHoldDown(TapDownDetails d) async {
    _stopCursorInertia();
    lastDeviceKind = d.kind;
    _leftHoldStartedBlocked = _shouldBlockGesture(d);
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_leftHoldStartedBlocked) return;
    if (handleTouch) {
      _lastPosOfDoubleTapDown = d.localPosition;
      _cacheLongPressPosition = d.localPosition;
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      _cacheLongPressPositionTs = DateTime.now().millisecondsSinceEpoch;
    } else {
      _lastTapDownPositionForMouseMode = d.localPosition;
      _cacheLongPressPosition = d.localPosition;
    }
  }

  onOneFingerHoldEnd() async {
    _leftHoldStartedBlocked = false;
    _leftLongPressRequested = false;
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    if (!_leftLongPressActive || isNotTouchBasedDevice()) return;
    _leftLongPressActive = false;
    await _leftLongPressDownFuture;
    _leftLongPressDownFuture = null;
    await inputModel.tapUp(MouseButtons.left);
  }

  onOneFingerHoldStart(TapDownDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_leftHoldStartedBlocked) {
      _leftLongPressRequested = false;
      return;
    }
    _leftLongPressRequested = true;
    if (handleTouch) {
      final isMoved = await ffi.cursorModel.move(
        _cacheLongPressPosition.dx,
        _cacheLongPressPosition.dy,
      );
      if (!isMoved) {
        _leftLongPressRequested = false;
        return;
      }
    } else if (shouldBlockMouseModeEvent()) {
      _leftLongPressRequested = false;
      return;
    }
    if (!_leftLongPressRequested) return;
    _leftLongPressActive = true;
    _leftLongPressDownFuture = inputModel.tapDown(MouseButtons.left);
    if (!handleTouch && !inputModel.relativeMouseMode.value) {
      ffi.canvasModel.beginMobileSelectionEdgeScroll();
    }
    await _leftLongPressDownFuture;
  }

  onOneFingerHoldMove(DragUpdateDetails d) async {
    if (!_leftLongPressActive || isNotTouchBasedDevice()) return;
    await _leftLongPressDownFuture;
    final delta = d.localPosition - _cacheLongPressPosition;
    _cacheLongPressPosition = d.localPosition;
    if (handleTouch) {
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    } else if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(delta.dx, delta.dy);
    } else {
      await ffi.cursorModel.updatePan(delta, d.localPosition, false);
      ffi.canvasModel.updateMobileSelectionEdgeScroll(d.localPosition);
    }
  }

  Future<bool> _prepareTwoFingerButton(TapDownDetails d) async {
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) return false;
    if (handleTouch) {
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) return false;
      return ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    }
    _lastTapDownPositionForMouseMode = d.localPosition;
    return !shouldBlockMouseModeEvent();
  }

  onTwoFingerDown(TapDownDetails d) {
    onTwoFingerSequenceStart();
  }

  onTwoFingerSequenceStart() {
    _stopCursorInertia();
    _lastTapDownDetails = null;
    _twoFingerWheel.reset();
  }

  onTwoFingerTap(TapDownDetails d) async {
    if (!await _prepareTwoFingerButton(d)) return;
    await inputModel.tap(MouseButtons.right);
  }

  onTwoFingerHoldStart(TapDownDetails d) async {
    _rightTwoFingerHoldRequested = true;
    if (!await _prepareTwoFingerButton(d)) {
      _rightTwoFingerHoldRequested = false;
      return;
    }
    if (!_rightTwoFingerHoldRequested) return;
    _rightTwoFingerHoldActive = true;
    _rightTwoFingerDownFuture = inputModel.tapDown(MouseButtons.right);
    await _rightTwoFingerDownFuture;
  }

  onTwoFingerHoldEnd() async {
    _rightTwoFingerHoldRequested = false;
    if (!_rightTwoFingerHoldActive) return;
    _rightTwoFingerHoldActive = false;
    await _rightTwoFingerDownFuture;
    _rightTwoFingerDownFuture = null;
    await inputModel.tapUp(MouseButtons.right);
  }

  onHoldDragStart(DragStartDetails d) async {
    _stopCursorInertia();
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (inputModel.mobileSpecialHoldDragActive) return;
      _legacyHoldDragActive = true;
      if (!inputModel.relativeMouseMode.value) {
        ffi.canvasModel.beginMobileSelectionEdgeScroll();
      }
      _legacyHoldDragDownFuture =
          inputModel.sendMouse('down', MouseButtons.left);
      await _legacyHoldDragDownFuture;
    }
  }

  onHoldDragUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (inputModel.mobileSpecialHoldDragActive) return;
      await _legacyHoldDragDownFuture;
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
      ffi.canvasModel.updateMobileSelectionEdgeScroll(d.localPosition);
    }
  }

  onHoldDragEnd(DragEndDetails d) async {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch && _legacyHoldDragActive) {
      _legacyHoldDragActive = false;
      await _legacyHoldDragDownFuture;
      _legacyHoldDragDownFuture = null;
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  onHoldDragCancel() async {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    if (!_legacyHoldDragActive) return;
    _legacyHoldDragActive = false;
    await _legacyHoldDragDownFuture;
    _legacyHoldDragDownFuture = null;
    await inputModel.sendMouse('up', MouseButtons.left);
  }

  onOneFingerPanStart(DragStartDetails d) async {
    _stopCursorInertia();
    _lastOneFingerPanPosition = d.localPosition;
    final TapDownDetails? lastTapDownDetails = _lastTapDownDetails;
    _lastTapDownDetails = null;
    lastDeviceKind = d.kind ?? lastDeviceKind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
      return;
    }
    if (handleTouch) {
      if (lastTapDownDetails != null) {
        await ffi.cursorModel.move(lastTapDownDetails.localPosition.dx,
            lastTapDownDetails.localPosition.dy);
      }
      if (!ffi.cursorModel.isInRemoteRect(d.localPosition)) {
        return;
      }

      _touchModePanStarted = true;
      if (isDesktop || isWebDesktop) {
        ffi.cursorModel.trySetRemoteWindowCoords();
      }

      // Workaround for the issue that the first pan event is sent a long time after the start event.
      // If the time interval between the start event and the first pan event is less than 500ms,
      // we consider to use the long press position as the start position.
      //
      // TODO: We should find a better way to send the first pan event as soon as possible.
      if (DateTime.now().millisecondsSinceEpoch - _cacheLongPressPositionTs <
          500) {
        await ffi.cursorModel
            .move(_cacheLongPressPosition.dx, _cacheLongPressPosition.dy);
      }
      // In relative mouse mode, skip mouse down - only send movement via sendMobileRelativeMouseMove
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('down', MouseButtons.left);
      }
      await ffi.cursorModel.move(d.localPosition.dx, d.localPosition.dy);
    }
    // Mouse mode deliberately does not map the new touch position to the
    // remote screen. Its updates continue from the current remote cursor.
    if (inputModel.useEdgeScroll) {
      ffi.canvasModel.rearmEdgeScroll();
      if (handleTouch) {
        ffi.canvasModel.edgeScrollMouse(d.localPosition.dx, d.localPosition.dy);
      }
    }
  }

  onOneFingerPanUpdate(DragUpdateDetails d) async {
    _lastOneFingerPanPosition = d.localPosition;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (ffi.cursorModel.shouldBlock(d.localPosition.dx, d.localPosition.dy)) {
      return;
    }
    if (handleTouch && !_touchModePanStarted) {
      return;
    }
    // In relative mouse mode, send delta directly without position tracking.
    if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(d.delta.dx, d.delta.dy);
    } else {
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
      if (inputModel.useEdgeScroll) {
        final edgePosition = handleTouch
            ? d.localPosition
            : ffi.cursorModel.mobileViewportPosition;
        ffi.canvasModel.edgeScrollMouse(edgePosition.dx, edgePosition.dy);
      }
    }
  }

  onOneFingerPanEnd(DragEndDetails d) async {
    _touchModePanStarted = false;
    ffi.canvasModel.cancelEdgeScroll();
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (isDesktop || isWebDesktop) {
      ffi.cursorModel.clearRemoteWindowCoords();
    }
    if (handleTouch) {
      // In relative mouse mode, skip mouse up - matches the skipped mouse down in onOneFingerPanStart
      if (!inputModel.relativeMouseMode.value) {
        await inputModel.sendMouse('up', MouseButtons.left);
      }
    } else {
      if (!_startCursorInertia(d)) {
        await _returnAccelerationCursorToNeutral();
      }
    }
  }

  // Reset `_touchModePanStarted` if the one-finger pan gesture is cancelled
  // or rejected by the gesture arena. Without this, the flag can remain
  // stuck in the "started" state and cause issues such as the Magic Mouse
  // double-click problem on iPad with magic mouse.
  onOneFingerPanCancel() async {
    final releaseLeftDrag = handleTouch &&
        _touchModePanStarted &&
        !inputModel.relativeMouseMode.value;
    _touchModePanStarted = false;
    ffi.canvasModel.cancelEdgeScroll();
    if (releaseLeftDrag) {
      await inputModel.sendMouse('up', MouseButtons.left);
    }
  }

  onTwoFingerViewportZoomUpdate(MobileTwoFingerMotionUpdate d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if ((isDesktop || isWebDesktop)) {
      final scale = ((d.scaleDelta - 1) * 1000).toInt();

      if (scale != 0) {
        if (widget.isCamera) return;
        await bind.sessionSendPointer(
            sessionId: sessionId,
            msg: json.encode(
                PointerEventToRust(kPointerEventKindTouch, 'scale', scale)
                    .toJson()));
      }
    } else {
      ffi.canvasModel.updateScale(d.scaleDelta, d.focalPoint);
      ffi.canvasModel.panX(d.focalPointDelta.dx);
      ffi.canvasModel.panY(d.focalPointDelta.dy);
    }
  }

  onTwoFingerViewportZoomEnd() async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if ((isDesktop || isWebDesktop)) {
      if (widget.isCamera) return;
      await bind.sessionSendPointer(
          sessionId: sessionId,
          msg: json.encode(
              PointerEventToRust(kPointerEventKindTouch, 'scale', 0).toJson()));
    }
  }

  onTwoFingerRemoteWheelUpdate(MobileTwoFingerMotionUpdate d) {
    if (isNotTouchBasedDevice()) return;
    final steps = _twoFingerWheel.add(d.focalPointDelta.dy);
    if (steps != 0) {
      inputModel.scroll(steps);
    }
  }

  onTwoFingerRemoteWheelEnd() {
    _twoFingerWheel.reset();
  }

  onTwoFingerViewportPanUpdate(MobileTwoFingerMotionUpdate d) {
    if (isNotTouchBasedDevice() || isDesktop || isWebDesktop) return;
    ffi.canvasModel.panX(d.focalPointDelta.dx);
    ffi.canvasModel.panY(d.focalPointDelta.dy);
  }

  onTwoFingerSpecialHoldDragUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) return;
    await ffi.cursorModel.updatePan(
      d.delta * 2.0,
      d.localPosition,
      handleTouch,
    );
  }

  get onThreeFingerVerticalDragUpdate => ffi.ffiModel.isPeerAndroid
      ? null
      : (d) {
          _mouseScrollIntegral += d.delta.dy / 4;
          if (_mouseScrollIntegral > 1) {
            inputModel.scroll(1);
            _mouseScrollIntegral = 0;
          } else if (_mouseScrollIntegral < -1) {
            inputModel.scroll(-1);
            _mouseScrollIntegral = 0;
          }
        };

  makeGestures() {
    return <Type, GestureRecognizerFactory>{
      // Official
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (instance) {
              instance
                ..onTapDown = onTapDown
                ..onTapUp = onTapUp
                ..onTap = onTap
                ..onTapCancel = onTapCancel;
            },
          ),
      DoubleTapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
            () => DoubleTapGestureRecognizer(),
            (instance) {
              instance
                ..onDoubleTapDown = onDoubleTapDown
                ..onDoubleTap = onDoubleTap;
            },
          ),
      // Customized
      HoldTapMoveGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<HoldTapMoveGestureRecognizer>(
            () => HoldTapMoveGestureRecognizer(),
            (instance) => instance
              ..onHoldDragStart = onHoldDragStart
              ..onHoldDragUpdate = onHoldDragUpdate
              ..onHoldDragCancel = onHoldDragCancel
              ..onHoldDragEnd = onHoldDragEnd,
          ),
      MobileTapHoldGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<MobileTapHoldGestureRecognizer>(
            () => MobileTapHoldGestureRecognizer(),
            (instance) {
              instance
                ..onOneFingerDown = onOneFingerHoldDown
                ..onOneFingerHoldStart = onOneFingerHoldStart
                ..onOneFingerHoldMove = onOneFingerHoldMove
                ..onOneFingerHoldEnd = onOneFingerHoldEnd
                ..onTwoFingerDown = onTwoFingerDown
                ..onTwoFingerTap = onTwoFingerTap
                ..onTwoFingerHoldStart = onTwoFingerHoldStart
                ..onTwoFingerHoldEnd = onTwoFingerHoldEnd
                ..onTwoFingerCancel = onTwoFingerHoldEnd;
            },
          ),
      CustomTouchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<CustomTouchGestureRecognizer>(
            () => CustomTouchGestureRecognizer(
              enableTwoFingerRemoteWheel: isMobile,
              isSpecialHoldDragActive: () =>
                  inputModel.mobileSpecialHoldDragActive,
            ),
            (instance) {
              instance.onOneFingerPanStart = onOneFingerPanStart;
              instance
                ..onOneFingerPanUpdate = onOneFingerPanUpdate
                ..onOneFingerPanEnd = onOneFingerPanEnd
                ..onOneFingerPanCancel = onOneFingerPanCancel
                ..onTwoFingerSequenceStart = onTwoFingerSequenceStart
                ..onTwoFingerViewportZoomUpdate =
                    onTwoFingerViewportZoomUpdate
                ..onTwoFingerViewportZoomEnd = onTwoFingerViewportZoomEnd
                ..onTwoFingerRemoteWheelUpdate =
                    onTwoFingerRemoteWheelUpdate
                ..onTwoFingerRemoteWheelEnd = onTwoFingerRemoteWheelEnd
                ..onTwoFingerViewportPanUpdate =
                    onTwoFingerViewportPanUpdate
                ..onTwoFingerSpecialHoldDragUpdate =
                    onTwoFingerSpecialHoldDragUpdate
                ..onThreeFingerVerticalDragUpdate =
                    onThreeFingerVerticalDragUpdate;
            },
          ),
    };
  }
}

class RawPointerMouseRegion extends StatelessWidget {
  final InputModel inputModel;
  final Widget child;
  final MouseCursor? cursor;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerHoverEventListener? onHover;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  RawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.onHover,
    this.cursor,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (evt) {
        onHover?.call(evt);
        inputModel.onPointHoverImage(evt);
      },
      onPointerDown: (evt) {
        onPointerDown?.call(evt);
        inputModel.onPointDownImage(evt);
      },
      onPointerUp: (evt) {
        onPointerUp?.call(evt);
        inputModel.onPointUpImage(evt);
      },
      onPointerCancel: inputModel.onPointCancelImage,
      onPointerMove: inputModel.onPointMoveImage,
      onPointerSignal: inputModel.onPointerSignalImage,
      onPointerPanZoomStart: inputModel.onPointerPanZoomStart,
      onPointerPanZoomUpdate: inputModel.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: inputModel.onPointerPanZoomEnd,
      child: MouseRegion(
        cursor: inputModel.isViewOnly
            ? MouseCursor.defer
            : (cursor ?? MouseCursor.defer),
        onEnter: onEnter,
        onExit: onExit,
        child: child,
      ),
    );
  }
}

class CameraRawPointerMouseRegion extends StatelessWidget {
  final InputModel inputModel;
  final Widget child;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final PointerHoverEventListener? onHover;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;

  CameraRawPointerMouseRegion({
    this.onEnter,
    this.onExit,
    this.onHover,
    this.onPointerDown,
    this.onPointerUp,
    required this.inputModel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerHover: (evt) {
        onHover?.call(evt);
        final offset = evt.position;
        double x = offset.dx;
        double y = max(0.0, offset.dy);
        inputModel.handlePointerDevicePos(
            kPointerEventKindMouse, x, y, true, kMouseEventTypeDefault);
      },
      onPointerDown: (evt) {
        onPointerDown?.call(evt);
      },
      onPointerUp: (evt) {
        onPointerUp?.call(evt);
      },
      child: MouseRegion(
        cursor: MouseCursor.defer,
        onEnter: onEnter,
        onExit: onExit,
        child: child,
      ),
    );
  }
}
