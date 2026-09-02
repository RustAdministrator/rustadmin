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
  late final MobileInteractionCoordinator _interaction;
  late final MobileCursorInertiaController _cursorInertia;
  late bool _hadKeyboardPermission;
  Offset _lastOneFingerPanPosition = Offset.zero;

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
  void initState() {
    super.initState();
    _interaction = MobileInteractionCoordinator(
      sendDown: _sendMobileButtonDown,
      sendUp: _sendMobileButtonUp,
    );
    _cursorInertia = MobileCursorInertiaController(
      onFrame: _applyCursorInertiaFrame,
      onStopped: ffi.canvasModel.cancelEdgeScroll,
      onError: (error, stackTrace) {
        debugPrint('Mobile cursor inertia failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    _hadKeyboardPermission = ffiModel.keyboard;
    ffiModel.addListener(_handlePermissionChange);
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
    ffiModel.removeListener(_handlePermissionChange);
    _cursorInertia.dispose();
    _releasePressedButtons();
    super.dispose();
  }

  void _releasePressedButtons() {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    unawaited(_interaction.releaseAll());
  }

  Future<void> _sendMobileButtonDown(MobileButtonIntent intent) => switch (intent) {
    MobileButtonIntent.ordinaryTap || MobileButtonIntent.leftLongPress =>
      inputModel.tapDown(MouseButtons.left),
    MobileButtonIntent.legacyHoldDrag || MobileButtonIntent.touchModePanDrag =>
      inputModel.sendMouse('down', MouseButtons.left),
    MobileButtonIntent.rightTwoFinger => inputModel.tapDown(MouseButtons.right),
  };

  Future<void> _sendMobileButtonUp(MobileButtonIntent intent) => switch (intent) {
    MobileButtonIntent.ordinaryTap || MobileButtonIntent.leftLongPress =>
      inputModel.tapUp(MouseButtons.left),
    MobileButtonIntent.legacyHoldDrag || MobileButtonIntent.touchModePanDrag =>
      inputModel.sendMouse('up', MouseButtons.left),
    MobileButtonIntent.rightTwoFinger => inputModel.tapUp(MouseButtons.right),
  };

  void _handlePermissionChange() {
    final hasKeyboardPermission = ffiModel.keyboard;
    if (_hadKeyboardPermission && !hasKeyboardPermission) {
      _releasePressedButtons();
    }
    _hadKeyboardPermission = hasKeyboardPermission;
  }

  void _stopCursorInertia({bool cancelEdgeScroll = true}) {
    _cursorInertia.stop(notify: cancelEdgeScroll);
  }

  bool _startCursorInertia(DragEndDetails details) {
    _stopCursorInertia(cancelEdgeScroll: false);
    final durationMs = widget.cursorInertiaDurationMs
        .clamp(
          kMinMobileCursorInertiaDurationMs,
          kMaxMobileCursorInertiaDurationMs,
        )
        .toInt();
    final started = _cursorInertia.start(
      duration: Duration(milliseconds: durationMs),
      velocity: details.velocity.pixelsPerSecond,
      localPosition: _lastOneFingerPanPosition,
    );
    if (!started) {
      ffi.canvasModel.cancelEdgeScroll();
      return false;
    }
    if (inputModel.useEdgeScroll) ffi.canvasModel.rearmEdgeScroll();
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

  Future<Offset> _applyCursorInertiaFrame(
    MobileCursorInertiaFrame frame,
  ) async {
    if (inputModel.relativeMouseMode.value) {
      await inputModel.sendMobileRelativeMouseMove(
        frame.delta.dx,
        frame.delta.dy,
      );
      return Offset.zero;
    }
    await ffi.cursorModel.updatePan(frame.delta, frame.localPosition, false);
    var adjustment = Offset.zero;
    if (_returnsAccelerationCursorToNeutral) {
      final currentPosition = ffi.cursorModel.mobileViewportPosition;
      adjustment = mobileRemoteAccelerationReturnDelta(
        pointerPosition: currentPosition,
        viewport: ffi.canvasModel.size,
        edgeThickness: ffi.canvasModel.edgeScrollEdgeThickness.toDouble(),
        directions: ffi.canvasModel.mobileViewportScrollDirections,
        frameDuration: frame.frameDuration,
        remainingDuration: frame.remainingDuration,
      );
      if (adjustment != Offset.zero) {
        await ffi.cursorModel.updatePan(
          adjustment,
          currentPosition + adjustment,
          false,
        );
      }
    }
    if (inputModel.useEdgeScroll) {
      final edgePosition = ffi.cursorModel.mobileViewportPosition;
      ffi.canvasModel.edgeScrollMouse(edgePosition.dx, edgePosition.dy);
    }
    return adjustment;
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
          await _interaction.tap(MobileButtonIntent.ordinaryTap);
        } else if (_touchModePanStarted) {
          await _interaction.release(MobileButtonIntent.touchModePanDrag);
        } else {
          await _interaction.releaseOrSendUp(MobileButtonIntent.ordinaryTap);
        }
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
      await _interaction.tap(MobileButtonIntent.ordinaryTap);
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
    await _interaction.tap(MobileButtonIntent.ordinaryTap);
    await _interaction.tap(MobileButtonIntent.ordinaryTap);
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
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    await _interaction.release(MobileButtonIntent.leftLongPress);
  }

  onOneFingerHoldStart(TapDownDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (_leftHoldStartedBlocked) {
      return;
    }
    final request = _interaction.begin(MobileButtonIntent.leftLongPress);
    if (handleTouch) {
      final isMoved = await ffi.cursorModel.move(
        _cacheLongPressPosition.dx,
        _cacheLongPressPosition.dy,
      );
      if (!isMoved) {
        _interaction.cancel(MobileButtonIntent.leftLongPress, request);
        return;
      }
    } else if (shouldBlockMouseModeEvent()) {
      _interaction.cancel(MobileButtonIntent.leftLongPress, request);
      return;
    }
    if (!_interaction.isRequested(MobileButtonIntent.leftLongPress, request)) {
      return;
    }
    if (!handleTouch && !inputModel.relativeMouseMode.value) {
      ffi.canvasModel.beginMobileSelectionEdgeScroll();
    }
    await _interaction.activate(MobileButtonIntent.leftLongPress, request);
  }

  onOneFingerHoldMove(DragUpdateDetails d) async {
    if (!_interaction.hasIntent(MobileButtonIntent.leftLongPress) ||
        isNotTouchBasedDevice()) {
      return;
    }
    await _interaction.settled(MobileButtonIntent.leftLongPress);
    if (!_interaction.isPressed(MobileButtonIntent.leftLongPress)) return;
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
    await _interaction.tap(MobileButtonIntent.rightTwoFinger);
  }

  onTwoFingerHoldStart(TapDownDetails d) async {
    final request = _interaction.begin(MobileButtonIntent.rightTwoFinger);
    if (!await _prepareTwoFingerButton(d)) {
      _interaction.cancel(MobileButtonIntent.rightTwoFinger, request);
      return;
    }
    if (!_interaction.isRequested(MobileButtonIntent.rightTwoFinger, request)) {
      return;
    }
    await _interaction.activate(MobileButtonIntent.rightTwoFinger, request);
  }

  onTwoFingerHoldEnd() async {
    await _interaction.release(MobileButtonIntent.rightTwoFinger);
  }

  onHoldDragStart(DragStartDetails d) async {
    _stopCursorInertia();
    lastDeviceKind = d.kind;
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (inputModel.mobileSpecialHoldDragActive) return;
      final request = _interaction.begin(MobileButtonIntent.legacyHoldDrag);
      if (!inputModel.relativeMouseMode.value) {
        ffi.canvasModel.beginMobileSelectionEdgeScroll();
      }
      await _interaction.activate(MobileButtonIntent.legacyHoldDrag, request);
    }
  }

  onHoldDragUpdate(DragUpdateDetails d) async {
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      if (inputModel.mobileSpecialHoldDragActive) return;
      if (!_interaction.hasIntent(MobileButtonIntent.legacyHoldDrag)) return;
      await _interaction.settled(MobileButtonIntent.legacyHoldDrag);
      if (!_interaction.isPressed(MobileButtonIntent.legacyHoldDrag)) return;
      await ffi.cursorModel.updatePan(d.delta, d.localPosition, handleTouch);
      ffi.canvasModel.updateMobileSelectionEdgeScroll(d.localPosition);
    }
  }

  onHoldDragEnd(DragEndDetails d) async {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    if (isNotTouchBasedDevice()) {
      return;
    }
    if (!handleTouch) {
      await _interaction.release(MobileButtonIntent.legacyHoldDrag);
    }
  }

  onHoldDragCancel() async {
    ffi.canvasModel.endMobileSelectionEdgeScroll();
    await _interaction.release(MobileButtonIntent.legacyHoldDrag);
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
        final request = _interaction.begin(MobileButtonIntent.touchModePanDrag);
        await _interaction.activate(
          MobileButtonIntent.touchModePanDrag,
          request,
        );
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
      await _interaction.release(MobileButtonIntent.touchModePanDrag);
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
    final releaseLeftDrag = handleTouch && _touchModePanStarted;
    _touchModePanStarted = false;
    ffi.canvasModel.cancelEdgeScroll();
    if (releaseLeftDrag) {
      await _interaction.release(MobileButtonIntent.touchModePanDrag);
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
