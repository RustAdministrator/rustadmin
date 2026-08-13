import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';

enum GestureState {
  none,
  oneFingerPan,
  twoFingerScale,
  threeFingerVerticalDrag
}
class CustomTouchGestureRecognizer extends ScaleGestureRecognizer {
  CustomTouchGestureRecognizer({
    Object? debugOwner,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
          debugOwner: debugOwner,
          supportedDevices: supportedDevices,
        ) {
    _init();
  }

  // oneFingerPan
  GestureDragStartCallback? onOneFingerPanStart;
  GestureDragUpdateCallback? onOneFingerPanUpdate;
  GestureDragEndCallback? onOneFingerPanEnd;
  GestureDragCancelCallback? onOneFingerPanCancel;

  // twoFingerScale : scale + pan event
  GestureScaleStartCallback? onTwoFingerScaleStart;
  GestureScaleUpdateCallback? onTwoFingerScaleUpdate;
  GestureScaleEndCallback? onTwoFingerScaleEnd;

  // threeFingerVerticalDrag
  GestureDragStartCallback? onThreeFingerVerticalDragStart;
  GestureDragUpdateCallback? onThreeFingerVerticalDragUpdate;
  GestureDragEndCallback? onThreeFingerVerticalDragEnd;

  var _currentState = GestureState.none;
  Timer? _debounceTimer;

  void _init() {
    debugPrint("CustomTouchGestureRecognizer init");
    // onStart = (d) {};
    onUpdate = (d) {
      _debounceTimer?.cancel();
      if (d.pointerCount == 1 && _currentState != GestureState.oneFingerPan) {
        onOneFingerStartDebounce(d);
      } else if (d.pointerCount == 2 &&
          _currentState != GestureState.twoFingerScale) {
        onTwoFingerStartDebounce(d);
      } else if (d.pointerCount == 3 &&
          _currentState != GestureState.threeFingerVerticalDrag) {
        _currentState = GestureState.threeFingerVerticalDrag;
        if (onThreeFingerVerticalDragStart != null) {
          onThreeFingerVerticalDragStart!(
              DragStartDetails(globalPosition: d.localFocalPoint));
        }
        debugPrint("start threeFingerScale");
      }
      if (_currentState != GestureState.none) {
        switch (_currentState) {
          case GestureState.oneFingerPan:
            if (onOneFingerPanUpdate != null) {
              onOneFingerPanUpdate!(_getDragUpdateDetails(d));
            }
            break;
          case GestureState.twoFingerScale:
            if (onTwoFingerScaleUpdate != null) {
              onTwoFingerScaleUpdate!(d);
            }
            break;
          case GestureState.threeFingerVerticalDrag:
            if (onThreeFingerVerticalDragUpdate != null) {
              onThreeFingerVerticalDragUpdate!(_getDragUpdateDetails(d));
            }
            break;
          default:
            break;
        }
        return;
      }
    };
    onEnd = (d) {
      debugPrint("ScaleGestureRecognizer onEnd");
      _debounceTimer?.cancel();
      // end
      switch (_currentState) {
        case GestureState.oneFingerPan:
          debugPrint("OneFingerState.pan onEnd");
          if (onOneFingerPanEnd != null) {
            onOneFingerPanEnd!(_getDragEndDetails(d));
          }
          break;
        case GestureState.twoFingerScale:
          debugPrint("TwoFingerState.scale onEnd");
          if (onTwoFingerScaleEnd != null) {
            onTwoFingerScaleEnd!(d);
          }
          if (isSpecialHoldDragActive) {
            // If we are in special drag mode, we need to reset the state.
            // Otherwise, the next `onTwoFingerScaleUpdate()` will handle a wrong `focalPoint`.
            _currentState = GestureState.none;
            return;
          }
          break;
        case GestureState.threeFingerVerticalDrag:
          debugPrint("ThreeFingerState.vertical onEnd");
          if (onThreeFingerVerticalDragEnd != null) {
            onThreeFingerVerticalDragEnd!(_getDragEndDetails(d));
          }
          break;
        default:
          break;
      }
      _debounceTimer = Timer(Duration(milliseconds: 200), () {
        _currentState = GestureState.none;
      });
    };
  }

  // FIXME: This debounce logic is not working properly.
  // If we move our finger very fast, we won't be able to detect the "oneFingerPan" event sometimes.
  void onOneFingerStartDebounce(ScaleUpdateDetails d) {
    start(ScaleUpdateDetails d) {
      _currentState = GestureState.oneFingerPan;
      if (onOneFingerPanStart != null) {
        onOneFingerPanStart!(DragStartDetails(
            localPosition: d.localFocalPoint, globalPosition: d.focalPoint));
      }
    }

    if (_currentState != GestureState.none) {
      _debounceTimer = Timer(Duration(milliseconds: 200), () {
        start(d);
        debugPrint("debounce start oneFingerPan");
      });
    } else {
      start(d);
      debugPrint("start oneFingerPan");
    }
  }

  void onTwoFingerStartDebounce(ScaleUpdateDetails d) {
    start(ScaleUpdateDetails d) {
      _currentState = GestureState.twoFingerScale;
      if (onTwoFingerScaleStart != null) {
        onTwoFingerScaleStart!(ScaleStartDetails(
            localFocalPoint: d.localFocalPoint, focalPoint: d.focalPoint));
      }
    }

    if (_currentState == GestureState.threeFingerVerticalDrag) {
      _debounceTimer = Timer(Duration(milliseconds: 200), () {
        start(d);
        debugPrint("debounce start twoFingerScale");
      });
    } else {
      start(d);
      debugPrint("start twoFingerScale");
    }
  }

  DragUpdateDetails _getDragUpdateDetails(ScaleUpdateDetails d) =>
      DragUpdateDetails(
          globalPosition: d.focalPoint,
          localPosition: d.localFocalPoint,
          delta: d.focalPointDelta);

  DragEndDetails _getDragEndDetails(ScaleEndDetails d) =>
      DragEndDetails(velocity: d.velocity);

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    switch (_currentState) {
      case GestureState.oneFingerPan:
        if (onOneFingerPanCancel != null) {
          onOneFingerPanCancel!();
        }
        break;
      case GestureState.twoFingerScale:
        // Reset scale state if needed, currently self-contained
        break;
      case GestureState.threeFingerVerticalDrag:
        // Reset drag state if needed, currently self-contained
        break;
      default:
        break;
    }
    _currentState = GestureState.none;
  }
}

class HoldTapMoveGestureRecognizer extends GestureRecognizer {
  HoldTapMoveGestureRecognizer({
    Object? debugOwner,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
          debugOwner: debugOwner,
          supportedDevices: supportedDevices,
        );

  GestureDragStartCallback? onHoldDragStart;
  GestureDragUpdateCallback? onHoldDragUpdate;
  GestureDragDownCallback? onHoldDragDown;
  GestureDragCancelCallback? onHoldDragCancel;
  GestureDragEndCallback? onHoldDragEnd;

  bool _isStart = false;

  Timer? _firstTapUpTimer;
  Timer? _secondTapDownTimer;
  _TapTracker? _firstTap;
  _TapTracker? _secondTap;

  PointerDownEvent? _lastPointerDownEvent;

  final Map<int, _TapTracker> _trackers = <int, _TapTracker>{};

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (_firstTap == null) {
      switch (event.buttons) {
        case kPrimaryButton:
          if (onHoldDragStart == null &&
              onHoldDragUpdate == null &&
              onHoldDragCancel == null &&
              onHoldDragEnd == null) {
            return false;
          }
          break;
        default:
          return false;
      }
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_firstTap != null) {
      if (!_firstTap!.isWithinGlobalTolerance(event, kDoubleTapSlop)) {
        // Ignore out-of-bounds second taps.
        return;
      } else if (!_firstTap!.hasElapsedMinTime() ||
          !_firstTap!.hasSameButton(event)) {
        // Restart when the second tap is too close to the first (touch screens
        // often detect touches intermittently), or when buttons mismatch.
        _reset();
        return _trackTap(event);
      } else if (onHoldDragDown != null) {
        invokeCallback<void>(
            'onHoldDragDown',
            () => onHoldDragDown!(DragDownDetails(
                globalPosition: event.position,
                localPosition: event.localPosition)));
      }
    }
    _trackTap(event);
  }

  void _trackTap(PointerDownEvent event) {
    _stopFirstTapUpTimer();
    _stopSecondTapDownTimer();
    final _TapTracker tracker = _TapTracker(
      event: event,
      entry: GestureBinding.instance.gestureArena.add(event.pointer, this),
      doubleTapMinTime: kDoubleTapMinTime,
      gestureSettings: gestureSettings,
    );
    _trackers[event.pointer] = tracker;
    _lastPointerDownEvent = event;
    tracker.startTrackingPointer(_handleEvent, event.transform);
  }

  void _handleEvent(PointerEvent event) {
    final _TapTracker tracker = _trackers[event.pointer]!;
    if (event is PointerUpEvent) {
      if (_firstTap == null && _secondTap == null) {
        _registerFirstTap(tracker);
      } else if (_secondTap != null) {
        if (event.pointer == _secondTap!.pointer) {
          if (onHoldDragEnd != null) {
            onHoldDragEnd!(DragEndDetails());
            _secondTap = null;
            _isStart = false;
          }
        }
      } else {
        _reject(tracker);
      }
    } else if (event is PointerDownEvent) {
      if (_firstTap != null && _secondTap == null) {
        _registerSecondTap(tracker);
      }
    } else if (event is PointerMoveEvent) {
      if (!tracker.isWithinGlobalTolerance(event, kDoubleTapTouchSlop)) {
        if (_firstTap != null && _firstTap!.pointer == event.pointer) {
          // first tap move
          _reject(tracker);
        } else if (_secondTap != null && _secondTap!.pointer == event.pointer) {
          // debugPrint("_secondTap move");
          // second tap move
          if (!_isStart) {
            _resolve();
          }
          if (onHoldDragUpdate != null) {
            onHoldDragUpdate!(DragUpdateDetails(
                globalPosition: event.position,
                localPosition: event.localPosition,
                delta: event.delta));
          }
        }
      }
    } else if (event is PointerCancelEvent) {
      _reject(tracker);
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    _TapTracker? tracker = _trackers[pointer];
    // If tracker isn't in the list, check if this is the first tap tracker
    if (tracker == null && _firstTap != null && _firstTap!.pointer == pointer) {
      tracker = _firstTap;
    }
    // If tracker is still null, we rejected ourselves already
    if (tracker != null) {
      _reject(tracker);
    }
  }

  void _resolve() {
    _stopSecondTapDownTimer();
    _firstTap?.entry.resolve(GestureDisposition.accepted);
    _secondTap?.entry.resolve(GestureDisposition.accepted);
    _isStart = true;
    // TODO start details
    if (onHoldDragStart != null) {
      onHoldDragStart!(DragStartDetails(
        kind: _lastPointerDownEvent?.kind,
      ));
    }
  }

  void _reject(_TapTracker tracker) {
    try {
      _checkCancel();
      _isStart = false;
      _trackers.remove(tracker.pointer);
      tracker.entry.resolve(GestureDisposition.rejected);
      _freezeTracker(tracker);
      _reset();
    } catch (e) {
      debugPrint("Failed to _reject:$e");
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _reset() {
    _isStart = false;
    // debugPrint("reset");
    _stopFirstTapUpTimer();
    _stopSecondTapDownTimer();
    if (_firstTap != null) {
      if (_trackers.isNotEmpty) {
        _checkCancel();
      }
      // Note, order is important below in order for the resolve -> reject logic
      // to work properly.
      final _TapTracker tracker = _firstTap!;
      _firstTap = null;
      _reject(tracker);
      GestureBinding.instance.gestureArena.release(tracker.pointer);

      if (_secondTap != null) {
        final _TapTracker tracker = _secondTap!;
        _secondTap = null;
        _reject(tracker);
        GestureBinding.instance.gestureArena.release(tracker.pointer);
      }
    }
    _firstTap = null;
    _secondTap = null;
    _clearTrackers();
  }

  void _registerFirstTap(_TapTracker tracker) {
    _startFirstTapUpTimer();
    GestureBinding.instance.gestureArena.hold(tracker.pointer);
    // Note, order is important below in order for the clear -> reject logic to
    // work properly.
    _freezeTracker(tracker);
    _trackers.remove(tracker.pointer);
    _firstTap = tracker;
  }

  void _registerSecondTap(_TapTracker tracker) {
    if (_firstTap != null) {
      _stopFirstTapUpTimer();
      _freezeTracker(_firstTap!);
      _firstTap = null;
    }

    _startSecondTapDownTimer();
    GestureBinding.instance.gestureArena.hold(tracker.pointer);

    _secondTap = tracker;

    // TODO
  }

  void _clearTrackers() {
    _trackers.values.toList().forEach(_reject);
    assert(_trackers.isEmpty);
  }

  void _freezeTracker(_TapTracker tracker) {
    tracker.stopTrackingPointer(_handleEvent);
  }

  void _startFirstTapUpTimer() {
    _firstTapUpTimer ??= Timer(kDoubleTapTimeout, _reset);
  }

  void _startSecondTapDownTimer() {
    _secondTapDownTimer ??= Timer(kDoubleTapTimeout, _resolve);
  }

  void _stopFirstTapUpTimer() {
    if (_firstTapUpTimer != null) {
      _firstTapUpTimer!.cancel();
      _firstTapUpTimer = null;
    }
  }

  void _stopSecondTapDownTimer() {
    if (_secondTapDownTimer != null) {
      _secondTapDownTimer!.cancel();
      _secondTapDownTimer = null;
    }
  }

  void _checkCancel() {
    if (onHoldDragCancel != null) {
      invokeCallback<void>('onHoldDragCancel', onHoldDragCancel!);
    }
  }

  @override
  String get debugDescription => 'double tap';
}

class MobileTapHoldGestureRecognizer extends OneSequenceGestureRecognizer {
  MobileTapHoldGestureRecognizer({
    Object? debugOwner,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(debugOwner: debugOwner, supportedDevices: supportedDevices);

  GestureTapDownCallback? onOneFingerDown;
  GestureTapDownCallback? onOneFingerHoldStart;
  GestureDragUpdateCallback? onOneFingerHoldMove;
  GestureTapCancelCallback? onOneFingerHoldEnd;
  GestureTapDownCallback? onTwoFingerTap;
  GestureTapDownCallback? onTwoFingerDown;
  GestureTapDownCallback? onTwoFingerHoldStart;
  GestureTapCancelCallback? onTwoFingerHoldEnd;
  GestureTapCancelCallback? onTwoFingerCancel;

  final Map<int, PointerDownEvent> _pointers = <int, PointerDownEvent>{};
  Timer? _holdTimer;
  TapDownDetails? _centroidDetails;
  bool _sawTwoPointers = false;
  bool _oneFingerHoldActive = false;
  bool _holdActive = false;
  bool _finishing = false;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton ||
        (onOneFingerHoldStart == null &&
            onTwoFingerTap == null &&
            onTwoFingerHoldStart == null)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (_oneFingerHoldActive) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    if (_pointers.length >= 2) {
      _pointers[event.pointer] = event;
      _finish(GestureDisposition.rejected, notifyCancel: true);
      return;
    }
    _pointers[event.pointer] = event;
    if (_pointers.length == 1) {
      final details = _detailsForEvent(event);
      invokeCallback<void>(
        'onOneFingerDown',
        () => onOneFingerDown?.call(details),
      );
      _holdTimer = Timer(kLongPressTimeout, _recognizeOneFingerHold);
      return;
    }

    _sawTwoPointers = true;
    _holdTimer?.cancel();
    _centroidDetails = _buildCentroidDetails();
    final details = _centroidDetails;
    if (details != null) {
      invokeCallback<void>(
        'onTwoFingerDown',
        () => onTwoFingerDown?.call(details),
      );
    }
    _holdTimer = Timer(kLongPressTimeout, _recognizeHold);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _pointers[event.pointer];
    if (down == null || _finishing) return;
    if (event is PointerUpEvent) {
      if (_oneFingerHoldActive) {
        invokeCallback<void>(
          'onOneFingerHoldEnd',
          () => onOneFingerHoldEnd?.call(),
        );
        _oneFingerHoldActive = false;
        _finish(GestureDisposition.accepted);
      } else if (_holdActive) {
        invokeCallback<void>(
          'onTwoFingerHoldEnd',
          () => onTwoFingerHoldEnd?.call(),
        );
        _holdActive = false;
        _finish(GestureDisposition.accepted);
      } else if (_sawTwoPointers) {
        _holdTimer?.cancel();
        resolve(GestureDisposition.accepted);
        final details = _centroidDetails;
        if (details != null) {
          invokeCallback<void>(
            'onTwoFingerTap',
            () => onTwoFingerTap?.call(details),
          );
        }
        _finish(GestureDisposition.accepted);
      } else {
        _finish(GestureDisposition.rejected);
      }
    } else if (event is PointerMoveEvent) {
      if (_oneFingerHoldActive) {
        invokeCallback<void>(
          'onOneFingerHoldMove',
          () => onOneFingerHoldMove?.call(
            DragUpdateDetails(
              globalPosition: event.position,
              localPosition: event.localPosition,
              delta: event.localDelta,
            ),
          ),
        );
      } else if (!_holdActive &&
          (event.position - down.position).distance > kTouchSlop) {
        _finish(GestureDisposition.rejected, notifyCancel: _sawTwoPointers);
      }
    } else if (event is PointerCancelEvent) {
      if (_oneFingerHoldActive) {
        invokeCallback<void>(
          'onOneFingerHoldEnd',
          () => onOneFingerHoldEnd?.call(),
        );
        _oneFingerHoldActive = false;
      } else if (_holdActive) {
        invokeCallback<void>(
          'onTwoFingerHoldEnd',
          () => onTwoFingerHoldEnd?.call(),
        );
        _holdActive = false;
      }
      _finish(GestureDisposition.rejected, notifyCancel: _sawTwoPointers);
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    if (!_finishing && _pointers.containsKey(pointer)) {
      _finish(GestureDisposition.rejected, notifyCancel: _sawTwoPointers);
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _recognizeHold() {
    if (_finishing || _pointers.length != 2 || _holdActive) return;
    _holdActive = true;
    resolve(GestureDisposition.accepted);
    final details = _centroidDetails;
    if (details != null) {
      invokeCallback<void>(
        'onTwoFingerHoldStart',
        () => onTwoFingerHoldStart?.call(details),
      );
    }
  }

  void _recognizeOneFingerHold() {
    if (_finishing || _pointers.length != 1 || _oneFingerHoldActive) return;
    _oneFingerHoldActive = true;
    resolve(GestureDisposition.accepted);
    final event = _pointers.values.single;
    final details = _detailsForEvent(event);
    invokeCallback<void>(
      'onOneFingerHoldStart',
      () => onOneFingerHoldStart?.call(details),
    );
  }

  TapDownDetails _detailsForEvent(PointerDownEvent event) => TapDownDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );

  TapDownDetails _buildCentroidDetails() {
    final events = _pointers.values.toList(growable: false);
    final first = events[0];
    final second = events[1];
    return TapDownDetails(
      globalPosition: (first.position + second.position) / 2,
      localPosition: (first.localPosition + second.localPosition) / 2,
      kind: first.kind,
    );
  }

  void _finish(GestureDisposition disposition, {bool notifyCancel = false}) {
    if (_finishing) return;
    _finishing = true;
    _cancelTimers();
    if (notifyCancel) {
      invokeCallback<void>(
        'onTwoFingerCancel',
        () => onTwoFingerCancel?.call(),
      );
    }
    resolve(disposition);
    for (final pointer in _pointers.keys.toList(growable: false)) {
      stopTrackingPointer(pointer);
    }
    _pointers.clear();
    _centroidDetails = null;
    _sawTwoPointers = false;
    _oneFingerHoldActive = false;
    _holdActive = false;
    _finishing = false;
  }

  void _cancelTimers() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'mobile tap or hold';
}

/// TapTracker helps track individual tap sequences as part of a
/// larger gesture.
class _TapTracker {
  _TapTracker({
    required PointerDownEvent event,
    required this.entry,
    required Duration doubleTapMinTime,
    required this.gestureSettings,
  })  : pointer = event.pointer,
        _initialGlobalPosition = event.position,
        initialButtons = event.buttons,
        _doubleTapMinTimeCountdown =
            _CountdownZoned(duration: doubleTapMinTime);

  final DeviceGestureSettings? gestureSettings;
  final int pointer;
  final GestureArenaEntry entry;
  final Offset _initialGlobalPosition;
  final int initialButtons;
  final _CountdownZoned _doubleTapMinTimeCountdown;

  bool _isTrackingPointer = false;

  void startTrackingPointer(PointerRoute route, Matrix4? transform) {
    if (!_isTrackingPointer) {
      _isTrackingPointer = true;
      GestureBinding.instance.pointerRouter.addRoute(pointer, route, transform);
    }
  }

  void stopTrackingPointer(PointerRoute route) {
    if (_isTrackingPointer) {
      _isTrackingPointer = false;
      GestureBinding.instance.pointerRouter.removeRoute(pointer, route);
    }
  }

  bool isWithinGlobalTolerance(PointerEvent event, double tolerance) {
    final Offset offset = event.position - _initialGlobalPosition;
    return offset.distance <= tolerance;
  }

  bool hasElapsedMinTime() {
    return _doubleTapMinTimeCountdown.timeout;
  }

  bool hasSameButton(PointerDownEvent event) {
    return event.buttons == initialButtons;
  }
}

/// CountdownZoned tracks whether the specified duration has elapsed since
/// creation, honoring [Zone].
class _CountdownZoned {
  _CountdownZoned({required Duration duration}) {
    Timer(duration, _onTimeout);
  }

  bool _timeout = false;

  bool get timeout => _timeout;

  void _onTimeout() {
    _timeout = true;
  }
}

RawGestureDetector getMixinGestureDetector({
  Widget? child,
  GestureTapUpCallback? onTapUp,
  GestureTapDownCallback? onDoubleTapDown,
  GestureDoubleTapCallback? onDoubleTap,
  GestureLongPressDownCallback? onLongPressDown,
  GestureLongPressCallback? onLongPress,
  GestureDragStartCallback? onHoldDragStart,
  GestureDragUpdateCallback? onHoldDragUpdate,
  GestureDragCancelCallback? onHoldDragCancel,
  GestureDragEndCallback? onHoldDragEnd,
  GestureTapDownCallback? onDoubleFinerTap,
  GestureDragStartCallback? onOneFingerPanStart,
  GestureDragUpdateCallback? onOneFingerPanUpdate,
  GestureDragEndCallback? onOneFingerPanEnd,
  GestureDragCancelCallback? onOneFingerPanCancel,
  GestureScaleUpdateCallback? onTwoFingerScaleUpdate,
  GestureScaleEndCallback? onTwoFingerScaleEnd,
  GestureDragUpdateCallback? onThreeFingerVerticalDragUpdate,
}) {
  return RawGestureDetector(
    child: child,
    gestures: <Type, GestureRecognizerFactory>{
      // Official
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
        () => TapGestureRecognizer(),
        (instance) {
          instance.onTapUp = onTapUp;
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
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(),
        (instance) {
          instance
            ..onLongPressDown = onLongPressDown
            ..onLongPress = onLongPress;
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
          instance.onTwoFingerTap = onDoubleFinerTap;
        },
      ),
      CustomTouchGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<CustomTouchGestureRecognizer>(
        () => CustomTouchGestureRecognizer(),
        (instance) {
          instance
            ..onOneFingerPanStart = onOneFingerPanStart
            ..onOneFingerPanUpdate = onOneFingerPanUpdate
            ..onOneFingerPanEnd = onOneFingerPanEnd
            ..onOneFingerPanCancel = onOneFingerPanCancel
            ..onTwoFingerScaleUpdate = onTwoFingerScaleUpdate
            ..onTwoFingerScaleEnd = onTwoFingerScaleEnd
            ..onThreeFingerVerticalDragUpdate = onThreeFingerVerticalDragUpdate;
        }),
      });
}
