import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as flutter_widgets
    show MenuController, RawMenuAnchorGroup;
import 'package:flutter_hbb/common/widgets/audio_input.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/common/remote_toolbar_settings.dart';
import 'package:flutter_hbb/common/remote_display_settings.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/session_tab.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/plugin/widgets/desc_ui.dart';
import 'package:flutter_hbb/plugin/common.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../common.dart';
import '../../models/model.dart';
import '../../models/keyboard_intent.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import './popup_menu.dart';
import './kb_layout_type_chooser.dart';
import './toolbar_menu_coordinator.dart';
import 'package:flutter_hbb/utils/scale.dart';
import 'package:flutter_hbb/common/widgets/custom_scale_base.dart';
import 'package:flutter_hbb/common/widgets/edge_thickness_control.dart';

class ToolbarImagePointerState {
  final bool insideImage;
  final Offset? localPosition;

  const ToolbarImagePointerState({
    required this.insideImage,
    this.localPosition,
  });
}

typedef ToolbarImagePointerHandler = void Function(ToolbarImagePointerState);
typedef ToolbarWindowPointerHandler = void Function(Offset? position);

const String _kRemoteMenubarOrientationHorizontal = 'horizontal';
const String _kRemoteMenubarOrientationVertical = 'vertical';
const double _kRemoteMenubarTopEdgeY = 0.0;

enum _ToolbarMenuId {
  monitor,
  control,
  display,
  keyboard,
  chat,
  voiceCall,
}

class _ToolbarMenuLifecycleScope extends InheritedWidget {
  final ToolbarMenuCoordinator<_ToolbarMenuId> coordinator;
  final VoidCallback onMenuPointerEnter;
  final VoidCallback onMenuPointerExit;
  final bool verticalToolbar;
  final bool openMenusLeft;

  const _ToolbarMenuLifecycleScope({
    required this.coordinator,
    required this.onMenuPointerEnter,
    required this.onMenuPointerExit,
    required this.verticalToolbar,
    required this.openMenusLeft,
    required super.child,
  });

  static _ToolbarMenuLifecycleScope? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_ToolbarMenuLifecycleScope>();
  }

  @override
  bool updateShouldNotify(_ToolbarMenuLifecycleScope oldWidget) {
    return coordinator != oldWidget.coordinator ||
        onMenuPointerEnter != oldWidget.onMenuPointerEnter ||
        onMenuPointerExit != oldWidget.onMenuPointerExit ||
        verticalToolbar != oldWidget.verticalToolbar ||
        openMenusLeft != oldWidget.openMenusLeft;
  }
}

class _ToolbarOpacityState {
  const _ToolbarOpacityState({
    required this.opacity,
    required this.duration,
  });

  static const opaque = _ToolbarOpacityState(
    opacity: 1.0,
    duration: Duration(milliseconds: 180),
  );

  final double opacity;
  final Duration duration;
}

class _ToolbarOpacityLayer extends StatelessWidget {
  const _ToolbarOpacityLayer({
    required this.state,
    required this.visible,
    required this.child,
  });

  final ValueListenable<_ToolbarOpacityState> state;
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ToolbarOpacityState>(
      valueListenable: state,
      child: child,
      builder: (context, value, stableChild) => AnimatedOpacity(
        duration:
            visible ? value.duration : const Duration(milliseconds: 180),
        opacity: visible ? value.opacity : 0,
        child: stableChild,
      ),
    );
  }
}

class ToolbarState {
  late RxBool _pin;
  late RemoteToolbarSettingsSnapshot _userDefaults;

  RxBool collapse = false.obs;
  RxBool hide = false.obs;
  RxBool vertical = false.obs;

  // Track initialization state to prevent flickering
  final RxBool initialized = false.obs;
  bool _isInitializing = false;

  ToolbarState() {
    _userDefaults = remoteToolbarSettings.read();
    _pin = RxBool(false);
    final s = bind.getLocalFlutterOption(k: kOptionRemoteMenubarState);
    if (s.isEmpty) {
      return;
    }

    try {
      final m = jsonDecode(s);
      if (m != null) {
        _pin = RxBool(m['pin'] ?? false);
      }
    } catch (e) {
      debugPrint('Failed to decode toolbar state ${e.toString()}');
    }
  }

  bool get pin => _pin.value;
  int get revealZonePx => _userDefaults.revealZonePx;
  int get hideDelayMs => _userDefaults.hideDelayMs;
  int get pinnedDimOpacityPercent => _userDefaults.pinnedOpacityPercent;
  double get pinnedDimOpacity => _userDefaults.pinnedOpacity;
  int get pinnedDimDelayMs => _userDefaults.pinnedDimDelayMs;
  int get pinnedDimDurationMs => _userDefaults.pinnedDimDurationMs;
  RemoteToolbarSettingsSnapshot get userDefaults => _userDefaults;

  void applyUserDefaults(RemoteToolbarSettingsSnapshot snapshot) {
    _userDefaults = snapshot;
  }

  /// Initialize all toolbar states from session options.
  /// This should be called once when the toolbar is first created.
  Future<void> init(SessionID sessionId) async {
    if (initialized.value || _isInitializing) return;
    _isInitializing = true;

    try {
      final settings = SessionPeerSettingsRepository.forSession(sessionId);
      final liveSettings = LiveSessionSettingsRepository.forSession(sessionId);
      // Load both states in parallel for better performance
      final results = await Future.wait<Object?>([
        liveSettings.read(LiveSessionSettingsRegistry.collapseToolbar),
        liveSettings.read(LiveSessionSettingsRegistry.hideToolbar),
        settings.read(SessionPeerSettingsRegistry.toolbarOrientation),
      ]);

      collapse.value = results[0] as bool;
      hide.value = results[1] as bool;
      vertical.value = results[2] == _kRemoteMenubarOrientationVertical;
    } finally {
      _isInitializing = false;
      initialized.value = true;
    }
  }

  switchCollapse(SessionID sessionId) async {
    final fallback = !collapse.value;
    collapse.value = await LiveSessionSettingsRepository.forSession(
      sessionId,
    ).toggleAndRead(
      LiveSessionSettingsRegistry.collapseToolbar,
      fallback: fallback,
    );
  }

  // Switch hide state for entire toolbar visibility
  switchHide(SessionID sessionId) async {
    final fallback = !hide.value;
    hide.value = await LiveSessionSettingsRepository.forSession(
      sessionId,
    ).toggleAndRead(
      LiveSessionSettingsRegistry.hideToolbar,
      fallback: fallback,
    );
  }

  switchOrientation(SessionID sessionId) async {
    final next = !vertical.value;
    vertical.value = next;
    await SessionPeerSettingsRepository.forSession(sessionId).write(
      SessionPeerSettingsRegistry.toolbarOrientation,
      next
          ? _kRemoteMenubarOrientationVertical
          : _kRemoteMenubarOrientationHorizontal,
    );
  }

  switchPin() async {
    _pin.value = !_pin.value;
    // Save everytime changed, as this func will not be called frequently
    await _savePin();
  }

  setPin(bool v) async {
    if (_pin.value != v) {
      _pin.value = v;
      // Save everytime changed, as this func will not be called frequently
      await _savePin();
    }
  }

  _savePin() async {
    bind.setLocalFlutterOption(
        k: kOptionRemoteMenubarState, v: jsonEncode({'pin': _pin.value}));
  }
}

class _ToolbarTheme {
  static const Color blueColor = MyTheme.button;
  static const Color hoverBlueColor = MyTheme.accent;
  static Color inactiveColor = Colors.grey[800]!;
  static Color hoverInactiveColor = Colors.grey[850]!;

  static const Color redColor = Colors.redAccent;
  static const Color hoverRedColor = Colors.red;
  // kMinInteractiveDimension
  static const double height = 20.0;
  static const double dividerHeight = 12.0;

  static const double buttonSize = 32;
  static const double buttonHMargin = 2;
  static const double buttonVMargin = 6;
  static const double iconRadius = 8;
  static const double elevation = 3;

  static double dividerSpaceToAction = isWindows ? 8 : 14;

  static double menuBorderRadius = isWindows ? 5.0 : 7.0;
  static EdgeInsets menuPadding = isWindows
      ? EdgeInsets.fromLTRB(4, 12, 4, 12)
      : EdgeInsets.fromLTRB(6, 14, 6, 14);
  static const double menuButtonBorderRadius = 3.0;
  static const double verticalMenuWidth = 320.0;

  static Color borderColor(BuildContext context) =>
      MyTheme.color(context).border3 ?? MyTheme.border;

  static Color? dividerColor(BuildContext context) =>
      MyTheme.color(context).divider;

  static MenuStyle defaultMenuStyle(BuildContext context) => MenuStyle(
        side: MaterialStateProperty.all(BorderSide(
          width: 1,
          color: borderColor(context),
        )),
        shape: MaterialStatePropertyAll(RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(_ToolbarTheme.menuBorderRadius))),
        padding: MaterialStateProperty.all(_ToolbarTheme.menuPadding),
      );
  static final defaultMenuButtonStyle = ButtonStyle(
    backgroundColor: MaterialStatePropertyAll(Colors.transparent),
    padding: MaterialStatePropertyAll(EdgeInsets.zero),
    overlayColor: MaterialStatePropertyAll(Colors.transparent),
  );

  static Widget borderWrapper(
      BuildContext context, Widget child, BorderRadius borderRadius) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: borderColor(context),
          width: 1,
        ),
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}

MenuStyle _toolbarMenuStyle(BuildContext context, MenuStyle? overrideStyle) {
  final style = overrideStyle ?? _ToolbarTheme.defaultMenuStyle(context);
  final scope = _ToolbarMenuLifecycleScope.maybeOf(context);
  if (scope?.verticalToolbar != true) {
    return style;
  }
  return style.copyWith(
    alignment: scope!.openMenusLeft ? Alignment.topLeft : Alignment.topRight,
    fixedSize: const WidgetStatePropertyAll(
      Size.fromWidth(_ToolbarTheme.verticalMenuWidth),
    ),
  );
}

MenuStyle _topLevelToolbarMenuStyle(
    BuildContext context, MenuStyle? overrideStyle) {
  final style = _toolbarMenuStyle(context, overrideStyle);
  if (_ToolbarMenuLifecycleScope.maybeOf(context)?.verticalToolbar == true) {
    return style;
  }
  return style.copyWith(alignment: AlignmentDirectional.bottomStart);
}

Offset? _toolbarMenuAlignmentOffset(BuildContext context) {
  final scope = _ToolbarMenuLifecycleScope.maybeOf(context);
  if (scope?.verticalToolbar != true) {
    return null;
  }
  return scope!.openMenusLeft
      ? const Offset(-_ToolbarTheme.verticalMenuWidth, 0)
      : Offset.zero;
}

EdgeInsets _toolbarMenuPadding(BuildContext context, MenuStyle? style) {
  final padding =
      style?.padding?.resolve(<WidgetState>{}) ?? _ToolbarTheme.menuPadding;
  return padding.resolve(Directionality.of(context));
}

Offset? _topLevelToolbarMenuAlignmentOffset(
    BuildContext context, MenuStyle? menuStyle) {
  final scope = _ToolbarMenuLifecycleScope.maybeOf(context);
  if (scope?.verticalToolbar != true) {
    return null;
  }
  if (!scope!.openMenusLeft) {
    return Offset.zero;
  }
  final padding = _toolbarMenuPadding(context, menuStyle);
  return Offset(
    -_ToolbarTheme.verticalMenuWidth + padding.left,
    0,
  );
}

Widget _rotateToolbarIconForVertical({
  required bool vertical,
  required Widget child,
}) {
  if (!vertical) {
    return child;
  }
  return Transform.rotate(
    angle: math.pi / 2,
    child: child,
  );
}

bool _isToolbarVertical(BuildContext context) {
  return _ToolbarMenuLifecycleScope.maybeOf(context)?.verticalToolbar == true;
}

List<Widget> _toolbarMenuChildren(
  BuildContext context,
  MenuStyle? menuStyle,
  List<Widget> children,
  FFI? ffi,
) {
  final trackedChildren =
      children.map((e) => _buildPointerTrackWidget(context, e, ffi)).toList();
  if (!_isToolbarVertical(context)) {
    return trackedChildren;
  }

  final padding = _toolbarMenuPadding(context, menuStyle);
  final contentWidth =
      math.max(0.0, _ToolbarTheme.verticalMenuWidth - padding.horizontal);
  return [
    SizedBox(width: contentWidth, height: 0),
    ...trackedChildren,
  ];
}

EdgeInsets _toolbarItemMargin(
  BuildContext context, {
  double? hMargin,
  double? vMargin,
  bool useToolbarSpacing = true,
}) {
  final horizontal = hMargin ?? _ToolbarTheme.buttonHMargin;
  final vertical = vMargin ?? _ToolbarTheme.buttonVMargin;
  if (useToolbarSpacing && _isToolbarVertical(context)) {
    return EdgeInsets.symmetric(
      horizontal: vertical,
      vertical: horizontal,
    );
  }
  return EdgeInsets.symmetric(
    horizontal: horizontal,
    vertical: vertical,
  );
}

typedef DismissFunc = void Function();

class RemoteMenuEntry {
  static MenuEntryButton<String> showSignIn(
    SessionID sessionId,
    EdgeInsets? padding, {
    DismissFunc? dismissFunc,
    DismissCallback? dismissCallback,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Show sign-in'),
        style: style,
      ),
      proc: () {
        bind.sessionShowSignIn(sessionId: sessionId);
        if (dismissFunc != null) {
          dismissFunc();
        }
      },
      padding: padding,
      dismissOnClicked: true,
      dismissCallback: dismissCallback,
    );
  }

  static MenuEntryButton<String> insertLock(
    SessionID sessionId,
    EdgeInsets? padding, {
    DismissFunc? dismissFunc,
    DismissCallback? dismissCallback,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate('Insert Lock'),
        style: style,
      ),
      proc: () {
        bind.sessionLockScreen(sessionId: sessionId);
        if (dismissFunc != null) {
          dismissFunc();
        }
      },
      padding: padding,
      dismissOnClicked: true,
      dismissCallback: dismissCallback,
    );
  }

  static insertCtrlAltDel(
    SessionID sessionId,
    EdgeInsets? padding, {
    DismissFunc? dismissFunc,
    DismissCallback? dismissCallback,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) => Text(
        translate("Insert Ctrl + Alt + Del"),
        style: style,
      ),
      proc: () {
        bind.sessionCtrlAltDel(sessionId: sessionId);
        if (dismissFunc != null) {
          dismissFunc();
        }
      },
      padding: padding,
      dismissOnClicked: true,
      dismissCallback: dismissCallback,
    );
  }
}

class RemoteToolbar extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  final Function(int, Function(bool)) onEnterOrLeaveImageSetter;
  final Function(int) onEnterOrLeaveImageCleaner;
  final Function(int, ToolbarImagePointerHandler) onImagePointerStateSetter;
  final Function(int) onImagePointerStateCleaner;
  final Function(int, ToolbarWindowPointerHandler) onWindowPointerStateSetter;
  final Function(int) onWindowPointerStateCleaner;
  final ValueChanged<bool> onMenuFocusChanged;
  final VoidCallback onCloseConnection;
  final Function(VoidCallback) setRemoteState;
  final SessionWindowHost? windowHost;

  RemoteToolbar({
    Key? key,
    required this.id,
    required this.ffi,
    required this.state,
    required this.onEnterOrLeaveImageSetter,
    required this.onEnterOrLeaveImageCleaner,
    required this.onImagePointerStateSetter,
    required this.onImagePointerStateCleaner,
    required this.onWindowPointerStateSetter,
    required this.onWindowPointerStateCleaner,
    required this.onMenuFocusChanged,
    required this.onCloseConnection,
    required this.setRemoteState,
    this.windowHost,
  }) : super(key: key);

  @override
  State<RemoteToolbar> createState() => _RemoteToolbarState();
}

class _RemoteToolbarState extends State<RemoteToolbar> {
  Timer? _autoHideTimer;
  Timer? _pinnedDimTimer;
  StreamSubscription<RemoteToolbarSettingsSnapshot>?
      _globalOptionSubscription;
  StreamSubscription<bool>? _showMonitorsSubscription;
  Worker? _pinWorker;
  bool _isCursorOverToolbar = false;
  int _menuHoverDepth = 0;
  bool _visible = true;
  final _toolbarOpacityState =
      ValueNotifier<_ToolbarOpacityState>(_ToolbarOpacityState.opaque);
  bool _wasSessionHidden = false;
  Offset? _lastWindowPointer;
  final _fractionX = 0.5.obs;
  final _fractionY = 0.0.obs;
  final _dragging = false.obs;
  final _toolbarKey = GlobalKey();
  final _menuController = flutter_widgets.MenuController();
  late final ToolbarMenuCoordinator<_ToolbarMenuId> _menuCoordinator;
  Offset _toolbarDragStartPointer = Offset.zero;
  Size _toolbarDragSize = Size.zero;
  double _toolbarDragStartFractionX = 0.5;
  double _toolbarDragStartFractionY = 0.0;
  double _dragLeft = 0.0;
  double _dragRight = 1.0;
  RemoteToolbarSettingsSnapshot? _pendingGlobalOptions;
  bool _refreshingGlobalOptions = false;
  bool _menuFocusGuardActive = false;
  ToolbarMenuPhase _lastMenuPhase = ToolbarMenuPhase.closed;

  int get windowId => stateGlobal.windowId;

  void _setFullscreen(bool v) {
    final host = widget.windowHost;
    if (host == null) {
      stateGlobal.setFullscreen(v);
    } else {
      unawaited(host.setFullscreen(v));
    }
    // stateGlobal.fullscreen is RxBool now, no need to call setState.
    // setState(() {});
  }

  RxBool get collapse => widget.state.collapse;
  RxBool get hide => widget.state.hide;
  bool get pin => widget.state.pin;

  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;

  void _minimize() async {
    final host = widget.windowHost;
    if (host == null) {
      await WindowController.fromWindowId(windowId).minimize();
    } else {
      await host.minimize();
    }
  }

  bool get _isInRevealZone =>
      _lastWindowPointer != null &&
      _lastWindowPointer!.dy <= widget.state.revealZonePx;

  void _cancelAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  void _cancelPinnedDim() {
    _pinnedDimTimer?.cancel();
    _pinnedDimTimer = null;
  }

  void _cancelGlobalOptionRefresh() {
    final subscription = _globalOptionSubscription;
    _globalOptionSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final showMonitorsSubscription = _showMonitorsSubscription;
    _showMonitorsSubscription = null;
    if (showMonitorsSubscription != null) {
      unawaited(showMonitorsSubscription.cancel());
    }
  }

  bool get _menuIsOpen => _menuCoordinator.isInteractionActive;
  bool get _isCursorOverMenu => _menuHoverDepth > 0;
  bool get _menuInteractionActive =>
      _menuFocusGuardActive || _menuIsOpen || _isCursorOverMenu;
  bool get _shouldDimPinnedToolbar =>
      pin &&
      _visible &&
      !_isCursorOverToolbar &&
      !_menuInteractionActive &&
      _dragging.isFalse;

  void _startGlobalOptionRefresh() {
    _globalOptionSubscription = remoteToolbarSettings.watch().listen((snapshot) {
      _pendingGlobalOptions = snapshot;
      if (!_refreshingGlobalOptions) {
        unawaited(_handleGlobalOptionsMaybeChanged());
      }
    });
    _showMonitorsSubscription = remoteDisplaySettings
        .watch(RemoteDisplaySettingsRegistry.showMonitorsToolbar)
        .listen((_) {
      if (mounted) setState(() {});
    });
  }

  bool _shouldOpenVerticalMenusLeft() =>
      widget.state.vertical.value && _fractionX.value >= 0.5;

  void _closeMenus() {
    _menuCoordinator.closeAll();
  }

  void _initDragBounds() {
    _dragLeft = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.toolbarDragLeft,
    );
    _dragRight = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.toolbarDragRight,
    );
  }

  void _startToolbarDrag(DragStartDetails details) {
    final renderObj = _toolbarKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox) {
      _toolbarDragSize = renderObj.size;
    } else {
      _toolbarDragSize = Size.zero;
    }
    _toolbarDragStartPointer = details.globalPosition;
    _toolbarDragStartFractionX = _fractionX.value;
    _toolbarDragStartFractionY = _fractionY.value;
    _closeMenus();
    _cancelAutoHide();
    _showPinnedToolbarOpaque();
    _setVisible(true);
    _dragging.value = true;
  }

  void _updateToolbarDrag(BuildContext context, DragUpdateDetails details) {
    final mediaSize = MediaQueryData.fromView(View.of(context)).size;
    final rangeX = math.max(1.0, mediaSize.width - _toolbarDragSize.width);
    final dx = details.globalPosition.dx - _toolbarDragStartPointer.dx;
    _fractionX.value = (_toolbarDragStartFractionX + dx / rangeX)
        .clamp(_dragLeft, _dragRight)
        .toDouble();
    if (pin) {
      final rangeY = math.max(1.0, mediaSize.height - _toolbarDragSize.height);
      final dy = details.globalPosition.dy - _toolbarDragStartPointer.dy;
      _fractionY.value =
          (_toolbarDragStartFractionY + dy / rangeY).clamp(0.0, 1.0).toDouble();
    }
  }

  void _endToolbarDrag() {
    final settings = SessionPeerSettingsRepository.forSession(
      widget.ffi.sessionId,
    );
    unawaited(
      settings.write(
        SessionPeerSettingsRegistry.toolbarDragX,
        _fractionX.value,
      ),
    );
    unawaited(
      settings.write(
        SessionPeerSettingsRegistry.toolbarDragY,
        _fractionY.value,
      ),
    );
    _dragging.value = false;
    if (pin) {
      if (_shouldDimPinnedToolbar) {
        _schedulePinnedDim();
      }
    } else if (!_isCursorOverToolbar &&
        !_isCursorOverMenu &&
        !_isInRevealZone &&
        !_menuIsOpen) {
      _scheduleAutoHide();
    }
  }

  void _bindToolbarYToTopEdge() {
    if (_fractionY.value == _kRemoteMenubarTopEdgeY) return;
    _fractionY.value = _kRemoteMenubarTopEdgeY;
    unawaited(
      SessionPeerSettingsRepository.forSession(widget.ffi.sessionId).write(
        SessionPeerSettingsRegistry.toolbarDragY,
        _fractionY.value,
      ),
    );
  }

  void _handleMenuCoordinatorChanged() {
    if (!mounted) return;
    final phase = _menuCoordinator.phase;
    if (phase == ToolbarMenuPhase.closing &&
        _lastMenuPhase != ToolbarMenuPhase.closing) {
      // Closing overlays do not always emit a matching mouse-exit event.
      _menuHoverDepth = 0;
    }
    _lastMenuPhase = phase;

    if (_menuCoordinator.isInteractionActive) {
      _setMenuFocusGuard(true);
      _cancelAutoHide();
      _showPinnedToolbarOpaque();
      _setVisible(true);
      return;
    }

    _setMenuFocusGuard(false);
    if (hide.value) return;
    if (pin ||
        _isCursorOverToolbar ||
        _isCursorOverMenu ||
        _isInRevealZone ||
        _menuIsOpen) {
      _cancelAutoHide();
      _setVisible(true);
      if (pin && _shouldDimPinnedToolbar) {
        _schedulePinnedDim();
      }
      return;
    }
    if (_visible) {
      _scheduleAutoHide();
    }
  }

  void _setMenuFocusGuard(bool active) {
    if (_menuFocusGuardActive == active) return;
    _menuFocusGuardActive = active;
    widget.onMenuFocusChanged(active);
  }

  void _setVisible(bool value) {
    if (_visible == value || !mounted) return;
    if (!value) {
      _closeMenus();
    }
    setState(() {
      _visible = value;
      if (!value) {
        _toolbarOpacityState.value = _ToolbarOpacityState.opaque;
      }
    });
  }

  void _showCurrentShape({bool scheduleHide = true}) {
    _cancelAutoHide();
    _showPinnedToolbarOpaque();
    _setVisible(true);
    if (scheduleHide &&
        !pin &&
        !_isCursorOverToolbar &&
        !_isCursorOverMenu &&
        !_isInRevealZone &&
        !_menuIsOpen &&
        _dragging.isFalse) {
      _scheduleAutoHide();
    }
  }

  void _scheduleAutoHide() {
    if (pin || !_visible || _dragging.isTrue || _menuIsOpen) return;
    _autoHideTimer?.cancel();
    _cancelPinnedDim();
    _autoHideTimer = Timer(
      Duration(milliseconds: widget.state.hideDelayMs),
      () {
        if (!mounted) return;
        if (!pin &&
            !_isCursorOverToolbar &&
            !_isCursorOverMenu &&
            !_isInRevealZone &&
            !_menuIsOpen &&
            _dragging.isFalse) {
          _setVisible(false);
        }
      },
    );
  }

  void _setToolbarOpacity(double opacity, Duration duration) {
    final nextOpacity = opacity.clamp(0.0, 1.0).toDouble();
    if (!mounted) return;
    final current = _toolbarOpacityState.value;
    if (current.opacity == nextOpacity && current.duration == duration) {
      return;
    }
    _toolbarOpacityState.value = _ToolbarOpacityState(
      opacity: nextOpacity,
      duration: duration,
    );
  }

  void _showPinnedToolbarOpaque() {
    _cancelPinnedDim();
    _setToolbarOpacity(1.0, const Duration(milliseconds: 180));
  }

  void _schedulePinnedDim() {
    if (!_shouldDimPinnedToolbar) return;
    if (_pinnedDimTimer?.isActive == true ||
        _toolbarOpacityState.value.opacity <= widget.state.pinnedDimOpacity) {
      return;
    }
    _pinnedDimTimer = Timer(
      Duration(milliseconds: widget.state.pinnedDimDelayMs),
      () {
        _pinnedDimTimer = null;
        if (!_shouldDimPinnedToolbar) return;
        _setToolbarOpacity(
          widget.state.pinnedDimOpacity,
          Duration(milliseconds: widget.state.pinnedDimDurationMs),
        );
      },
    );
  }

  void _handlePinChanged(bool pinned) {
    if (!mounted) return;
    if (pinned) {
      _cancelAutoHide();
      _setVisible(true);
      if (_shouldDimPinnedToolbar) {
        _schedulePinnedDim();
      } else {
        _showPinnedToolbarOpaque();
      }
      return;
    }

    _bindToolbarYToTopEdge();
    _showPinnedToolbarOpaque();
    if (!_isCursorOverToolbar &&
        !_isCursorOverMenu &&
        !_isInRevealZone &&
        !_menuIsOpen) {
      _scheduleAutoHide();
    }
  }

  Future<void> _handleGlobalOptionsMaybeChanged() async {
    if (_refreshingGlobalOptions || !mounted) return;
    _refreshingGlobalOptions = true;
    try {
      while (mounted && _pendingGlobalOptions != null) {
        final next = _pendingGlobalOptions!;
        _pendingGlobalOptions = null;
        final previous = widget.state.userDefaults;
        if (next == previous) continue;
        widget.state.applyUserDefaults(next);

        if (pin) {
          if (_shouldDimPinnedToolbar) {
            _cancelPinnedDim();
            if (_toolbarOpacityState.value.opacity < 1.0) {
              _setToolbarOpacity(
                widget.state.pinnedDimOpacity,
                const Duration(milliseconds: 180),
              );
            } else {
              _schedulePinnedDim();
            }
          } else {
            _showPinnedToolbarOpaque();
          }
        } else {
          _cancelAutoHide();
          _handleWindowPointerState(_lastWindowPointer);
        }

        if (widget.ffi.canvasModel.scrollStyle.stringValue ==
                previous.scrollStyle &&
            next.scrollStyle != previous.scrollStyle) {
          await bind.sessionSetScrollStyle(
            sessionId: widget.ffi.sessionId,
            value: next.scrollStyle,
          );
          await widget.ffi.canvasModel.updateScrollStyle();
        }

        if (widget.ffi.canvasModel.edgeScrollEdgeThickness ==
                previous.edgeThickness &&
            next.edgeThickness != previous.edgeThickness) {
          await bind.sessionSetEdgeScrollEdgeThickness(
            sessionId: widget.ffi.sessionId,
            value: next.edgeThickness,
          );
          widget.ffi.canvasModel.updateEdgeScrollEdgeThickness(
            next.edgeThickness,
          );
        }

        if (widget.ffi.inputModel.trackpadSpeed == previous.trackpadSpeed &&
            next.trackpadSpeed != previous.trackpadSpeed) {
          await bind.sessionSetTrackpadSpeed(
            sessionId: widget.ffi.sessionId,
            value: next.trackpadSpeed,
          );
          await widget.ffi.inputModel.updateTrackpadSpeed();
        }
      }
    } finally {
      _refreshingGlobalOptions = false;
    }
  }

  void _handleToolbarPointerEnter() {
    _isCursorOverToolbar = true;
    _cancelAutoHide();
    _showPinnedToolbarOpaque();
    widget.ffi.canvasModel.cancelEdgeScroll();
  }

  void _handleToolbarPointerDown() {
    // Synthesized pointer streams from nested remote-control clients do not
    // always deliver hover/enter before the button event. Treat pointer-down
    // as an explicit toolbar interaction. Menu activation happens in the raw
    // pointer-up listener, so restoring opacity here cannot lose the click if
    // this rebuild cancels the TextButton gesture recognizer.
    _cancelAutoHide();
    _showPinnedToolbarOpaque();
    _setVisible(true);
    widget.ffi.canvasModel.cancelEdgeScroll();
  }

  void _handleToolbarPointerUp() {
    // Pointer-up reaches the menu button before the next frame, so restoring
    // opacity here cannot replace the active gesture recognizer.
    _showPinnedToolbarOpaque();
  }

  void _handleToolbarPointerExit() {
    _isCursorOverToolbar = false;
    if (pin) {
      if (!_isCursorOverMenu && !_menuIsOpen) {
        _schedulePinnedDim();
      }
    } else if (!_isCursorOverMenu && !_isInRevealZone && !_menuIsOpen) {
      _scheduleAutoHide();
    }
  }

  void _handleMenuPointerEnter() {
    _menuHoverDepth += 1;
    _cancelAutoHide();
    _showPinnedToolbarOpaque();
    widget.ffi.canvasModel.cancelEdgeScroll();
  }

  void _handleMenuPointerExit() {
    if (_menuHoverDepth > 0) {
      _menuHoverDepth -= 1;
    }
    if (pin) {
      if (_shouldDimPinnedToolbar) {
        _schedulePinnedDim();
      }
    } else if (!_isCursorOverToolbar &&
        !_isCursorOverMenu &&
        !_isInRevealZone &&
        !_menuIsOpen) {
      _scheduleAutoHide();
    }
  }

  void _handleWindowPointerState(Offset? position) {
    _lastWindowPointer = position;

    if (hide.value) return;

    if (_menuIsOpen) {
      _showCurrentShape(scheduleHide: false);
      return;
    }

    if (!pin && _isInRevealZone) {
      _showCurrentShape(scheduleHide: false);
      return;
    }

    if (_lastWindowPointer == null) {
      if (pin && !_isCursorOverToolbar) {
        _schedulePinnedDim();
      } else if (!pin && !_isCursorOverToolbar) {
        _scheduleAutoHide();
      }
      return;
    }

    if (_visible && !pin && !_isCursorOverToolbar) {
      _scheduleAutoHide();
    } else if (_visible && pin && !_isCursorOverToolbar) {
      _schedulePinnedDim();
    }
  }

  @override
  initState() {
    super.initState();
    _menuCoordinator = ToolbarMenuCoordinator<_ToolbarMenuId>(
      isGroupOpen: () => _menuController.isOpen,
      closeGroup: _menuController.close,
      scheduleCallback: (callback) {
        WidgetsBinding.instance.addPostFrameCallback((_) => callback());
      },
    )..addListener(_handleMenuCoordinatorChanged);
    _initDragBounds();
    _startGlobalOptionRefresh();
    _pinWorker = ever<bool>(widget.state._pin, _handlePinChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final settings = SessionPeerSettingsRepository.forSession(
        widget.ffi.sessionId,
      );
      final position = await Future.wait([
        settings.read(SessionPeerSettingsRegistry.toolbarDragX),
        settings.read(SessionPeerSettingsRegistry.toolbarDragY),
      ]);
      _fractionX.value = position[0].clamp(_dragLeft, _dragRight).toDouble();
      _fractionY.value = position[1].clamp(0.0, 1.0).toDouble();
      // Initialize toolbar states (collapse, hide) from session options
      await widget.state.init(widget.ffi.sessionId);
      if (!pin) {
        _bindToolbarYToTopEdge();
      }
    });

    widget.onWindowPointerStateSetter(
      identityHashCode(this),
      _handleWindowPointerState,
    );
  }

  @override
  dispose() {
    _setMenuFocusGuard(false);
    _cancelAutoHide();
    _cancelPinnedDim();
    _cancelGlobalOptionRefresh();
    _pinWorker?.dispose();
    _menuCoordinator.removeListener(_handleMenuCoordinatorChanged);
    _closeMenus();
    _menuCoordinator.dispose();
    _toolbarOpacityState.dispose();
    widget.onEnterOrLeaveImageCleaner(identityHashCode(this));
    widget.onImagePointerStateCleaner(identityHashCode(this));
    widget.onWindowPointerStateCleaner(identityHashCode(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value) {
        return const SizedBox.shrink();
      }
      // If toolbar is hidden, return empty widget
      if (hide.value) {
        _wasSessionHidden = true;
        _cancelAutoHide();
        _cancelPinnedDim();
        _toolbarOpacityState.value = _ToolbarOpacityState.opaque;
        _closeMenus();
        return const SizedBox.shrink();
      }
      if (_wasSessionHidden) {
        _wasSessionHidden = false;
        _visible = true;
        _toolbarOpacityState.value = _ToolbarOpacityState.opaque;
      }
      final currentShape = collapse.isFalse
          ? _buildToolbar(context)
          : _buildDraggableCollapse(context);
      final y = pin ? _fractionY.value : 0.0;
      return Align(
        alignment: FractionalOffset(_fractionX.value, y),
        child: IgnorePointer(
          ignoring: !_visible,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            offset: _visible ? Offset.zero : const Offset(0, -1.15),
            child: _ToolbarOpacityLayer(
              state: _toolbarOpacityState,
              visible: _visible,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _handleToolbarPointerDown(),
                onPointerUp: (_) => _handleToolbarPointerUp(),
                child: MouseRegion(
                  onEnter: (_) => _handleToolbarPointerEnter(),
                  onExit: (_) => _handleToolbarPointerExit(),
                  child: _ToolbarMenuLifecycleScope(
                    coordinator: _menuCoordinator,
                    onMenuPointerEnter: _handleMenuPointerEnter,
                    onMenuPointerExit: _handleMenuPointerExit,
                    verticalToolbar: widget.state.vertical.value,
                    openMenusLeft: _shouldOpenVerticalMenusLeft(),
                    child: flutter_widgets.RawMenuAnchorGroup(
                      controller: _menuController,
                      child: currentShape,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildDraggableCollapse(BuildContext context) {
    final borderRadius = BorderRadius.vertical(
      bottom: Radius.circular(5),
    );
    return Obx(() => Offstage(
          offstage: _dragging.isTrue,
          child: Material(
            elevation: _ToolbarTheme.elevation,
            shadowColor: MyTheme.color(context).shadow,
            borderRadius: borderRadius,
            child: _DraggableShowHide(
              id: widget.id,
              sessionId: widget.ffi.sessionId,
              dragging: _dragging,
              fractionX: _fractionX,
              fractionY: _fractionY,
              toolbarState: widget.state,
              setFullscreen: _setFullscreen,
              setMinimize: _minimize,
              borderRadius: borderRadius,
            ),
          ),
        ));
  }

  Widget _buildToolbar(BuildContext context) {
    final verticalToolbar = widget.state.vertical.value;
    final List<Widget> toolbarItems = [];
    toolbarItems.add(_buildExpandedDragHandle(context));
    toolbarItems.add(_PinMenu(state: widget.state));
    toolbarItems.add(_OrientationMenu(
      sessionId: widget.ffi.sessionId,
      state: widget.state,
    ));
    if (!isWebDesktop) {
      toolbarItems.add(_MobileActionMenu(ffi: widget.ffi));
    }

    toolbarItems.add(Obx(() {
      if (PrivacyModeState.find(widget.id).isEmpty &&
          pi.displaysCount.value > 1) {
        return _MonitorMenu(
            id: widget.id,
            ffi: widget.ffi,
            sourceWindowId: widget.windowHost?.windowId,
            setRemoteState: widget.setRemoteState);
      } else {
        return Offstage();
      }
    }));

    toolbarItems
        .add(_ControlMenu(id: widget.id, ffi: widget.ffi, state: widget.state));
    toolbarItems.add(_DisplayMenu(
      id: widget.id,
      ffi: widget.ffi,
      state: widget.state,
      windowHost: widget.windowHost,
      setFullscreen: _setFullscreen,
    ));
    toolbarItems.add(_QualityMonitorMenu(ffi: widget.ffi));
    // Do not show keyboard for camera connection type.
    if (widget.ffi.connType == ConnType.defaultConn) {
      toolbarItems.add(_KeyboardMenu(id: widget.id, ffi: widget.ffi));
    }
    toolbarItems.add(_ChatMenu(id: widget.id, ffi: widget.ffi));
    if (!isWeb) {
      toolbarItems.add(_VoiceCallMenu(id: widget.id, ffi: widget.ffi));
    }
    if (!isWeb) toolbarItems.add(_RecordMenu());
    toolbarItems.add(_CollapseMenu(
      sessionId: widget.ffi.sessionId,
      state: widget.state,
    ));
    toolbarItems.add(_CloseMenu(
      ffi: widget.ffi,
      onCloseConnection: widget.onCloseConnection,
    ));
    final toolbarBorderRadius = BorderRadius.all(Radius.circular(4.0));
    final toolbarContent = verticalToolbar
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: _ToolbarTheme.buttonHMargin * 2),
              ...toolbarItems,
              SizedBox(height: _ToolbarTheme.buttonHMargin * 2),
            ],
          )
        : Row(
            children: [
              SizedBox(width: _ToolbarTheme.buttonHMargin * 2),
              ...toolbarItems,
              SizedBox(width: _ToolbarTheme.buttonHMargin * 2)
            ],
          );
    return Material(
      key: _toolbarKey,
      elevation: _ToolbarTheme.elevation,
      shadowColor: MyTheme.color(context).shadow,
      borderRadius: toolbarBorderRadius,
      color: Theme.of(context)
          .menuBarTheme
          .style
          ?.backgroundColor
          ?.resolve(MaterialState.values.toSet()),
      child: SingleChildScrollView(
        scrollDirection: verticalToolbar ? Axis.vertical : Axis.horizontal,
        child: Theme(
          data: themeData(),
          child: _ToolbarTheme.borderWrapper(
              context, toolbarContent, toolbarBorderRadius),
        ),
      ),
    );
  }

  Widget _buildExpandedDragHandle(BuildContext context) {
    return Padding(
      padding: _toolbarItemMargin(context),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _startToolbarDrag,
          onPanUpdate: (details) => _updateToolbarDrag(context, details),
          onPanEnd: (_) => _endToolbarDrag(),
          onPanCancel: _endToolbarDrag,
          child: SizedBox(
            width: _ToolbarTheme.buttonSize,
            height: _ToolbarTheme.buttonSize,
            child: Icon(
              Icons.drag_indicator,
              size: 20,
              color: MyTheme.color(context).drag_indicator,
            ),
          ),
        ),
      ),
    );
  }

  ThemeData themeData() {
    return Theme.of(context).copyWith(
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStatePropertyAll(Size(64, 32)),
          textStyle: MaterialStatePropertyAll(
            TextStyle(fontWeight: FontWeight.normal),
          ),
          shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(_ToolbarTheme.menuButtonBorderRadius))),
        ),
      ),
      dividerTheme: DividerThemeData(
        space: _ToolbarTheme.dividerSpaceToAction,
        color: _ToolbarTheme.dividerColor(context),
      ),
      menuBarTheme: MenuBarThemeData(
          style: MenuStyle(
        padding: MaterialStatePropertyAll(EdgeInsets.zero),
        elevation: MaterialStatePropertyAll(0),
        shape: MaterialStatePropertyAll(BeveledRectangleBorder()),
      ).copyWith(
              backgroundColor:
                  Theme.of(context).menuBarTheme.style?.backgroundColor)),
    );
  }
}

class _PinMenu extends StatelessWidget {
  final ToolbarState state;
  const _PinMenu({Key? key, required this.state}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => _IconMenuButton(
        assetName: state.pin ? "assets/pinned.svg" : "assets/unpinned.svg",
        tooltip: state.pin ? 'Unpin Toolbar' : 'Pin Toolbar',
        onPressed: state.switchPin,
        color:
            state.pin ? _ToolbarTheme.blueColor : _ToolbarTheme.inactiveColor,
        hoverColor: state.pin
            ? _ToolbarTheme.hoverBlueColor
            : _ToolbarTheme.hoverInactiveColor,
      ),
    );
  }
}

class _OrientationMenu extends StatelessWidget {
  final SessionID sessionId;
  final ToolbarState state;

  const _OrientationMenu({
    Key? key,
    required this.sessionId,
    required this.state,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final vertical = state.vertical.value;
      return _IconMenuButton(
        tooltip: vertical ? 'Vertical Toolbar' : 'Horizontal Toolbar',
        icon: _ToolbarOrientationGlyph(vertical: vertical),
        onPressed: () => state.switchOrientation(sessionId),
        color: _ToolbarTheme.inactiveColor,
        hoverColor: _ToolbarTheme.hoverInactiveColor,
      );
    });
  }
}

class _QualityMonitorMenu extends StatelessWidget {
  final FFI ffi;

  const _QualityMonitorMenu({Key? key, required this.ffi}) : super(key: key);

  Future<void> _toggle() async {
    await LiveSessionSettingsRepository.forSession(ffi.sessionId).toggle(
      LiveSessionSettingsRegistry.showQualityMonitor,
    );
    await ffi.qualityMonitorModel.checkShowQualityMonitor(ffi.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ffi.qualityMonitorModel.showListenable,
      builder: (context, visible, _) => _IconMenuButton(
        tooltip: 'Quality monitor',
        icon: const SizedBox(
          width: _ToolbarTheme.buttonSize,
          height: _ToolbarTheme.buttonSize,
          child: Center(
            child: Text(
              'QM',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
        onPressed: () => unawaited(_toggle()),
        color: visible
            ? _ToolbarTheme.blueColor
            : _ToolbarTheme.inactiveColor,
        hoverColor: visible
            ? _ToolbarTheme.hoverBlueColor
            : _ToolbarTheme.hoverInactiveColor,
      ),
    );
  }
}

class _ToolbarOrientationGlyph extends StatelessWidget {
  final bool vertical;
  final double size;

  const _ToolbarOrientationGlyph({
    Key? key,
    required this.vertical,
    this.size = _ToolbarTheme.buttonSize,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          vertical ? 'V' : 'H',
          style: TextStyle(
            color: Colors.white,
            fontSize: size <= 20 ? 11 : 15,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _MobileActionMenu extends StatelessWidget {
  final FFI ffi;
  const _MobileActionMenu({Key? key, required this.ffi}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (!ffi.ffiModel.isPeerAndroid) return Offstage();
    return Obx(() => _IconMenuButton(
          assetName: 'assets/actions_mobile.svg',
          tooltip: 'Mobile Actions',
          onPressed: () => ffi.dialogManager.setMobileActionsOverlayVisible(
              !ffi.dialogManager.mobileActionsOverlayVisible.value),
          color: ffi.dialogManager.mobileActionsOverlayVisible.isTrue
              ? _ToolbarTheme.blueColor
              : _ToolbarTheme.inactiveColor,
          hoverColor: ffi.dialogManager.mobileActionsOverlayVisible.isTrue
              ? _ToolbarTheme.hoverBlueColor
              : _ToolbarTheme.hoverInactiveColor,
        ));
  }
}

class _MonitorMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final int? sourceWindowId;
  final Function(VoidCallback) setRemoteState;
  const _MonitorMenu({
    Key? key,
    required this.id,
    required this.ffi,
    this.sourceWindowId,
    required this.setRemoteState,
  }) : super(key: key);

  bool get showMonitorsToolbar =>
      remoteDisplaySettings.read(
        RemoteDisplaySettingsRegistry.showMonitorsToolbar,
      );

  bool get supportIndividualWindows =>
      !isWeb && ffi.ffiModel.pi.isSupportMultiDisplay;

  @override
  Widget build(BuildContext context) => showMonitorsToolbar
      ? buildMultiMonitorMenu(context)
      : Obx(() => buildMonitorMenu(context));

  Widget buildMonitorMenu(BuildContext context) {
    final width = SimpleWrapper<double>(0);
    final height = SimpleWrapper<double>(_ToolbarTheme.buttonSize);
    final monitorsIcon = globalMonitorsWidget(
        context, width, height, Colors.white, Colors.black38,
        stackVertically: _isToolbarVertical(context));
    return _IconSubmenuButton(
        menuId: _ToolbarMenuId.monitor,
        tooltip: 'Select Monitor',
        icon: monitorsIcon,
        ffi: ffi,
        width: width.value,
        height: height.value,
        color: _ToolbarTheme.blueColor,
        hoverColor: _ToolbarTheme.hoverBlueColor,
        menuStyle: MenuStyle(
            padding:
                MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 6))),
        menuChildrenGetter: (_) => [buildMonitorSubmenuWidget(context)]);
  }

  Widget buildMultiMonitorMenu(BuildContext context) {
    final children = buildMonitorList(context, true);
    final vertical =
        _ToolbarMenuLifecycleScope.maybeOf(context)?.verticalToolbar == true;
    if (vertical) {
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    return Row(children: children);
  }

  Widget buildMonitorSubmenuWidget(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: buildMonitorList(context, false)),
        supportIndividualWindows ? Divider() : Offstage(),
        supportIndividualWindows ? chooseDisplayBehavior() : Offstage(),
      ],
    );
  }

  Widget chooseDisplayBehavior() {
    final value =
        bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
            'Y';
    return CkbMenuButton(
        value: value,
        onChanged: (value) async {
          if (value == null) return;
          await bind.sessionSetDisplaysAsIndividualWindows(
              sessionId: ffi.sessionId, value: value ? 'Y' : 'N');
        },
        ffi: ffi,
        child: Text(translate('Show displays as individual windows')));
  }

  buildOneMonitorButton(i, curDisplay) => Text(
        '${i + 1}',
        style: TextStyle(
          color: i == curDisplay
              ? _ToolbarTheme.blueColor
              : _ToolbarTheme.inactiveColor,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      );

  List<Widget> buildMonitorList(BuildContext context, bool isMulti) {
    final List<Widget> monitorList = [];
    final pi = ffi.ffiModel.pi;

    buildMonitorButton(int i) => Obx(() {
          RxInt display = CurrentDisplayState.find(id);

          final isAllMonitors = i == kAllDisplayValue;
          final width = SimpleWrapper<double>(0);
          final height = SimpleWrapper<double>(_ToolbarTheme.buttonSize);
          Widget? monitorsIcon;
          if (isAllMonitors) {
            monitorsIcon = globalMonitorsWidget(
                context, width, height, Colors.white, _ToolbarTheme.blueColor,
                stackVertically: isMulti && _isToolbarVertical(context));
          }
          return _IconMenuButton(
            tooltip: isMulti
                ? ''
                : isAllMonitors
                    ? 'all monitors'
                    : '#${i + 1} monitor',
            hMargin: isMulti ? null : 6,
            vMargin: isMulti ? null : 12,
            topLevel: false,
            useToolbarSpacing: isMulti,
            color: i == display.value
                ? _ToolbarTheme.blueColor
                : _ToolbarTheme.inactiveColor,
            hoverColor: i == display.value
                ? _ToolbarTheme.hoverBlueColor
                : _ToolbarTheme.hoverInactiveColor,
            width: isAllMonitors ? width.value : null,
            height: isAllMonitors ? height.value : null,
            icon: isAllMonitors
                ? monitorsIcon
                : Container(
                    alignment: AlignmentDirectional.center,
                    constraints:
                        const BoxConstraints(minHeight: _ToolbarTheme.height),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SvgPicture.asset(
                          "assets/screen.svg",
                          colorFilter:
                              ColorFilter.mode(Colors.white, BlendMode.srcIn),
                        ),
                        Obx(() => buildOneMonitorButton(i, display.value)),
                      ],
                    ),
                  ),
            onPressed: () => onPressed(i, pi, isMulti),
          );
        });

    for (int i = 0; i < pi.displays.length; i++) {
      monitorList.add(buildMonitorButton(i));
    }
    if (supportIndividualWindows && pi.displays.length > 1) {
      monitorList.add(buildMonitorButton(kAllDisplayValue));
    }
    return monitorList;
  }

  Widget globalMonitorsWidget(
    BuildContext context,
    SimpleWrapper<double> width,
    SimpleWrapper<double> height,
    Color activeTextColor,
    Color activeBgColor, {
    required bool stackVertically,
  }) {
    getMonitors() {
      final pi = ffi.ffiModel.pi;
      RxInt display = CurrentDisplayState.find(id);
      final rect = ffi.ffiModel.globalDisplaysRect();
      if (rect == null) {
        return Offstage();
      }

      if (stackVertically) {
        final displaySizes = pi.displays.map((d) {
          final scale = d.scale;
          return Size(d.width.toDouble() / scale, d.height.toDouble() / scale);
        }).toList();
        if (displaySizes.isEmpty) {
          return Offstage();
        }

        final slotSize = _ToolbarTheme.buttonSize;
        final maxWidth = displaySizes
            .map((size) => size.width)
            .reduce((a, b) => math.max(a, b));
        final scale = slotSize / maxWidth;
        final children = <Widget>[];
        var top = 0.0;
        for (var i = 0; i < displaySizes.length; i++) {
          final size = displaySizes[i];
          final monitorWidth = size.width * scale;
          final monitorHeight = size.height * scale;
          final fontSize =
              (math.min(monitorWidth, monitorHeight) * 0.65).clamp(6.0, 12.0);
          children.add(Positioned(
            left: (slotSize - monitorWidth) * 0.5,
            top: top,
            width: monitorWidth,
            height: monitorHeight,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.grey,
                  width: 1.0,
                ),
                color: display.value == i ? activeBgColor : Colors.white,
              ),
              child: Center(
                  child: Text(
                '${i + 1}',
                style: TextStyle(
                  color: display.value == i
                      ? activeTextColor
                      : _ToolbarTheme.inactiveColor,
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                ),
              )),
            ),
          ));
          top += monitorHeight;
        }

        width.value = slotSize;
        height.value = top;
        return SizedBox(
          width: width.value,
          height: height.value,
          child: Stack(
            children: children,
          ),
        );
      }

      final scale = _ToolbarTheme.buttonSize / rect.height * 0.75;
      final startY = (_ToolbarTheme.buttonSize - rect.height * scale) * 0.5;
      final startX = startY;

      final children = <Widget>[];
      for (var i = 0; i < pi.displays.length; i++) {
        final d = pi.displays[i];
        double s = d.scale;
        int dWidth = d.width.toDouble() ~/ s;
        int dHeight = d.height.toDouble() ~/ s;
        final fontSize = (dWidth * scale < dHeight * scale
                ? dWidth * scale
                : dHeight * scale) *
            0.65;
        children.add(Positioned(
          left: (d.x - rect.left) * scale + startX,
          top: (d.y - rect.top) * scale + startY,
          width: dWidth * scale,
          height: dHeight * scale,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.grey,
                width: 1.0,
              ),
              color: display.value == i ? activeBgColor : Colors.white,
            ),
            child: Center(
                child: Text(
              '${i + 1}',
              style: TextStyle(
                color: display.value == i
                    ? activeTextColor
                    : _ToolbarTheme.inactiveColor,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
              ),
            )),
          ),
        ));
      }
      width.value = rect.width * scale + startX * 2;
      height.value = _ToolbarTheme.buttonSize;
      return SizedBox(
        width: width.value,
        height: rect.height * scale + startY * 2,
        child: Stack(
          children: children,
        ),
      );
    }

    final monitors = getMonitors();
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(width: width.value, height: height.value),
        monitors,
      ],
    );
  }

  onPressed(int i, PeerInfo pi, bool isMulti) {
    if (!isMulti) {
      // If show monitors in toolbar(`buildMultiMonitorMenu()`), then the menu will dismiss automatically.
      _menuDismissCallback(ffi);
    }
    RxInt display = CurrentDisplayState.find(id);
    if (display.value != i) {
      final isChooseDisplayToOpenInNewWindow = pi.isSupportMultiDisplay &&
          bind.sessionGetDisplaysAsIndividualWindows(
                  sessionId: ffi.sessionId) ==
              'Y';
      if (isChooseDisplayToOpenInNewWindow) {
        openMonitorInNewTabOrWindow(
          i,
          ffi.id,
          pi,
          sourceWindowId: sourceWindowId,
          sourceSessionId: ffi.sessionId.toString(),
        );
      } else {
        openMonitorInTheSameTab(i, ffi, pi, updateCursorPos: !isMulti);
      }
    }
  }
}

class _ControlMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  _ControlMenu(
      {Key? key, required this.id, required this.ffi, required this.state})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconSubmenuButton(
        menuId: _ToolbarMenuId.control,
        tooltip: 'Control Actions',
        svg: "assets/actions.svg",
        color: _ToolbarTheme.blueColor,
        hoverColor: _ToolbarTheme.hoverBlueColor,
        ffi: ffi,
        menuChildrenGetter: (_) => toolbarControls(context, id, ffi).map((e) {
              if (e.divider) {
                return Divider();
              } else {
                return MenuButton(
                    child: e.child,
                    onPressed: e.onPressed,
                    ffi: ffi,
                    trailingIcon: e.trailingIcon);
              }
            }).toList());
  }
}

class ScreenAdjustor {
  final String id;
  final FFI ffi;
  final VoidCallback cbExitFullscreen;
  final SessionWindowHost? windowHost;
  window_size.Screen? _screen;

  ScreenAdjustor({
    required this.id,
    required this.ffi,
    required this.cbExitFullscreen,
    this.windowHost,
  });

  bool get isFullscreen => stateGlobal.fullscreen.isTrue;
  int get windowId => stateGlobal.windowId;

  adjustWindow(BuildContext context) {
    return futureBuilder(
        future: isWindowCanBeAdjusted(),
        hasData: (data) {
          final visible = data as bool;
          if (!visible) return Offstage();
          return Column(
            children: [
              MenuButton(
                  child: Text(translate('Adjust Window')),
                  onPressed: () => doAdjustWindow(context),
                  ffi: ffi),
              Divider(),
            ],
          );
        });
  }

  doAdjustWindow(BuildContext context) async {
    await updateScreen();
    if (_screen != null) {
      cbExitFullscreen();
      double scale = _screen!.scaleFactor;
      final wndRect = windowHost == null
          ? await WindowController.fromWindowId(windowId).getFrame()
          : await windowHost!.getFrame();
      final mediaSize = MediaQueryData.fromView(View.of(context)).size;
      // On windows, wndRect is equal to GetWindowRect and mediaSize is equal to GetClientRect.
      // https://stackoverflow.com/a/7561083
      double magicWidth =
          wndRect.right - wndRect.left - mediaSize.width * scale;
      double magicHeight =
          wndRect.bottom - wndRect.top - mediaSize.height * scale;
      final canvasModel = ffi.canvasModel;
      final width = (canvasModel.getDisplayWidth() * canvasModel.scale +
                  CanvasModel.leftToEdge +
                  CanvasModel.rightToEdge) *
              scale +
          magicWidth;
      final height = (canvasModel.getDisplayHeight() * canvasModel.scale +
                  CanvasModel.topToEdge +
                  CanvasModel.bottomToEdge) *
              scale +
          magicHeight;
      double left = wndRect.left + (wndRect.width - width) / 2;
      double top = wndRect.top + (wndRect.height - height) / 2;

      Rect frameRect = _screen!.frame;
      if (!isFullscreen) {
        frameRect = _screen!.visibleFrame;
      }
      if (left < frameRect.left) {
        left = frameRect.left;
      }
      if (top < frameRect.top) {
        top = frameRect.top;
      }
      if ((left + width) > frameRect.right) {
        left = frameRect.right - width;
      }
      if ((top + height) > frameRect.bottom) {
        top = frameRect.bottom - height;
      }
      final frame = Rect.fromLTWH(left, top, width, height);
      if (windowHost == null) {
        await WindowController.fromWindowId(windowId).setFrame(frame);
      } else {
        await windowHost!.setFrame(frame);
      }
      stateGlobal.setMaximized(false);
    }
  }

  updateScreen() async {
    final String info =
        isWeb ? screenInfo : await _getScreenInfoDesktop() ?? '';
    if (info.isEmpty) {
      _screen = null;
    } else {
      final screenMap = jsonDecode(info);
      _screen = window_size.Screen(
          Rect.fromLTRB(screenMap['frame']['l'], screenMap['frame']['t'],
              screenMap['frame']['r'], screenMap['frame']['b']),
          Rect.fromLTRB(
              screenMap['visibleFrame']['l'],
              screenMap['visibleFrame']['t'],
              screenMap['visibleFrame']['r'],
              screenMap['visibleFrame']['b']),
          screenMap['scaleFactor']);
    }
  }

  _getScreenInfoDesktop() async {
    final v = await rustDeskWinManager.call(
        WindowType.Main, kWindowGetWindowInfo, '');
    return v.result;
  }

  Future<bool> isWindowCanBeAdjusted() async {
    final viewStyle =
        await bind.sessionGetViewStyle(sessionId: ffi.sessionId) ?? '';
    if (viewStyle != kRemoteViewStyleOriginal) {
      return false;
    }
    if (!isWeb) {
      final remoteCount = RemoteCountState.find().value;
      if (remoteCount != 1) {
        return false;
      }
    }
    if (_screen == null) {
      return false;
    }
    final scale = kIgnoreDpi ? 1.0 : _screen!.scaleFactor;
    double selfWidth = _screen!.visibleFrame.width;
    double selfHeight = _screen!.visibleFrame.height;
    if (isFullscreen) {
      selfWidth = _screen!.frame.width;
      selfHeight = _screen!.frame.height;
    }

    final canvasModel = ffi.canvasModel;
    final displayWidth = canvasModel.getDisplayWidth();
    final displayHeight = canvasModel.getDisplayHeight();
    final requiredWidth =
        CanvasModel.leftToEdge + displayWidth + CanvasModel.rightToEdge;
    final requiredHeight =
        CanvasModel.topToEdge + displayHeight + CanvasModel.bottomToEdge;
    return selfWidth > (requiredWidth * scale) &&
        selfHeight > (requiredHeight * scale);
  }
}

class _DisplayMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  final Function(bool) setFullscreen;
  final SessionWindowHost? windowHost;
  final Widget pluginItem;
  _DisplayMenu(
      {Key? key,
      required this.id,
      required this.ffi,
      required this.state,
      this.windowHost,
      required this.setFullscreen})
      : pluginItem = LocationItem.createLocationItem(
          id,
          ffi,
          kLocationClientRemoteToolbarDisplay,
          true,
        ),
        super(key: key);

  @override
  State<_DisplayMenu> createState() => _DisplayMenuState();
}

class _DisplayMenuState extends State<_DisplayMenu> {
  final RxInt _customPercent = 100.obs;
  late final ScreenAdjustor _screenAdjustor = ScreenAdjustor(
    id: widget.id,
    ffi: widget.ffi,
    cbExitFullscreen: () => widget.setFullscreen(false),
    windowHost: widget.windowHost,
  );

  int get windowId => stateGlobal.windowId;
  Map<String, bool> get perms => widget.ffi.ffiModel.permissions;
  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;
  FFI get ffi => widget.ffi;
  String get id => widget.id;

  @override
  void initState() {
    super.initState();
    // Initialize custom percent from stored option once
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final v = await getSessionCustomScalePercent(widget.ffi.sessionId);
        if (_customPercent.value != v) {
          _customPercent.value = v;
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    _screenAdjustor.updateScreen();
    menuChildrenGetter(_IconSubmenuButtonState state) {
      final menuChildren = <Widget>[
        _screenAdjustor.adjustWindow(context),
        viewStyle(customPercent: _customPercent),
        scrollStyle(state),
        imageQuality(),
        codec(),
        captureBackend(),
        if (ffi.connType == ConnType.defaultConn)
          _ResolutionsMenu(
            id: widget.id,
            ffi: widget.ffi,
            screenAdjustor: _screenAdjustor,
          ),
        if (showVirtualDisplayMenu(ffi) && ffi.connType == ConnType.defaultConn)
          _SubmenuButton(
            ffi: widget.ffi,
            menuChildren: getVirtualDisplayMenuChildren(ffi, id, null),
            child: Text(translate("Virtual display")),
          ),
        if (ffi.connType == ConnType.defaultConn) cursorToggles(),
        Divider(),
        tabsInFullscreenToggle(),
        toggles(),
      ];
      // privacy mode
      if (ffi.connType == ConnType.defaultConn &&
          ffiModel.keyboard &&
          pi.features.privacyMode) {
        final privacyModeState = PrivacyModeState.find(id);
        final privacyModeList =
            toolbarPrivacyMode(privacyModeState, context, id, ffi);
        if (privacyModeList.length == 1) {
          menuChildren.add(CkbMenuButton(
              value: privacyModeList[0].value,
              onChanged: privacyModeList[0].onChanged,
              child: privacyModeList[0].child,
              ffi: ffi));
        } else if (privacyModeList.length > 1) {
          menuChildren.addAll([
            Divider(),
            _SubmenuButton(
                ffi: widget.ffi,
                child: Text(translate('Privacy mode')),
                menuChildren: privacyModeList
                    .map((e) => CkbMenuButton(
                        value: e.value,
                        onChanged: e.onChanged,
                        child: e.child,
                        ffi: ffi))
                    .toList()),
          ]);
        }
      }
      if (ffi.connType == ConnType.defaultConn) {
        menuChildren.add(widget.pluginItem);
      }
      return menuChildren;
    }

    return _IconSubmenuButton(
      menuId: _ToolbarMenuId.display,
      tooltip: 'Display Settings',
      svg: "assets/display.svg",
      ffi: widget.ffi,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      menuChildrenGetter: menuChildrenGetter,
    );
  }

  viewStyle({required RxInt customPercent}) {
    return futureBuilder(
        future: toolbarViewStyle(context, widget.id, widget.ffi),
        hasData: (data) {
          final v = data as List<TRadioMenu<String>>;
          final bool isCustomSelected = v.isNotEmpty
              ? v.first.groupValue == kRemoteViewStyleCustom
              : false;
          return Column(children: [
            ...v.map((e) {
              final isCustom = e.value == kRemoteViewStyleCustom;
              final child =
                  isCustom ? Text(translate('Scale custom')) : e.child;
              // Whether the current selection is already custom
              final bool isGroupCustomSelected =
                  e.groupValue == kRemoteViewStyleCustom;
              // Keep menu open when switching INTO custom so the slider is visible immediately
              final bool keepOpenForThisItem =
                  isCustom && !isGroupCustomSelected;
              return RdoMenuButton<String>(
                  value: e.value,
                  groupValue: e.groupValue,
                  onChanged: (value) {
                    // Perform the original change
                    e.onChanged?.call(value);
                    // Only force a rebuild when we keep the menu open to reveal the slider
                    if (keepOpenForThisItem) {
                      setState(() {});
                    }
                  },
                  child: child,
                  ffi: ffi,
                  // When entering custom, keep submenu open to show the slider controls
                  closeOnActivate: !keepOpenForThisItem);
            }).toList(),
            if (isCustomSelected) ...[
              Divider(),
              _ScalePresetsMenu(
                ffi: widget.ffi,
                customPercent: customPercent,
              ),
            ] else
              Divider(),
            _customControlsIfCustomSelected(
                onChanged: (v) => customPercent.value = v),
          ]);
        });
  }

  Widget _customControlsIfCustomSelected({ValueChanged<int>? onChanged}) {
    return futureBuilder(future: () async {
      final current = await bind.sessionGetViewStyle(sessionId: ffi.sessionId);
      return current == kRemoteViewStyleCustom;
    }(), hasData: (data) {
      final isCustom = data as bool;
      return AnimatedSwitcher(
        duration: Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: isCustom
            ? _CustomScaleMenuControls(ffi: ffi, onChanged: onChanged)
            : SizedBox.shrink(),
      );
    });
  }

  scrollStyle(_IconSubmenuButtonState state) {
    return futureBuilder(future: () async {
      final viewStyle =
          await bind.sessionGetViewStyle(sessionId: ffi.sessionId) ?? '';
      final visible = viewStyle == kRemoteViewStyleOriginal ||
          viewStyle == kRemoteViewStyleCustom;
      final scrollStyle =
          await bind.sessionGetScrollStyle(sessionId: ffi.sessionId) ?? '';
      return {
        'visible': visible,
        'scrollStyle': scrollStyle,
      };
    }(), hasData: (data) {
      final visible = data['visible'] as bool;
      if (!visible) return Offstage();
      final groupValue = data['scrollStyle'] as String;

      onChangeScrollStyle(String? value) async {
        if (value == null) return;
        await bind.sessionSetScrollStyle(
            sessionId: ffi.sessionId, value: value);
        widget.ffi.canvasModel.updateScrollStyle();
        state.setState(() {});
      }

      onChangeEdgeThickness(double value) {
        final thickness = value.round();
        widget.ffi.canvasModel.updateEdgeScrollEdgeThickness(thickness);
        unawaited(bind.sessionSetEdgeScrollEdgeThickness(
          sessionId: ffi.sessionId,
          value: thickness,
        ));
      }

      final usesEdgeThickness = groupValue == kRemoteScrollStyleEdge ||
          groupValue == kRemoteScrollStyleEdgeAcceleration;

      return Obx(() => Column(children: [
            RdoMenuButton<String>(
              child: Text(translate('ScrollAuto')),
              value: kRemoteScrollStyleAuto,
              groupValue: groupValue,
              onChanged: widget.ffi.canvasModel.imageOverflow.value
                  ? (value) => onChangeScrollStyle(value)
                  : null,
              ffi: widget.ffi,
            ),
            RdoMenuButton<String>(
              child: Text(translate('Scrollbar')),
              value: kRemoteScrollStyleBar,
              groupValue: groupValue,
              onChanged: widget.ffi.canvasModel.imageOverflow.value
                  ? (value) => onChangeScrollStyle(value)
                  : null,
              ffi: widget.ffi,
            ),
            if (!isWeb) ...[
              RdoMenuButton<String>(
                child: Text(translate('ScrollEdge')),
                value: kRemoteScrollStyleEdge,
                groupValue: groupValue,
                onChanged: widget.ffi.canvasModel.imageOverflow.value
                    ? (value) => onChangeScrollStyle(value)
                    : null,
                ffi: widget.ffi,
              ),
              RdoMenuButton<String>(
                child: Text(translate('ScrollEdgeAcceleration')),
                value: kRemoteScrollStyleEdgeAcceleration,
                groupValue: groupValue,
                onChanged: widget.ffi.canvasModel.imageOverflow.value
                    ? (value) => onChangeScrollStyle(value)
                    : null,
                ffi: widget.ffi,
              ),
              if (usesEdgeThickness)
                EdgeThicknessControl(
                  key: const Key('desktop-toolbar-edge-thickness'),
                  value: widget.ffi.canvasModel.edgeScrollEdgeThickness
                      .toDouble(),
                  onChanged: onChangeEdgeThickness,
                ),
            ],
            Divider(),
          ]));
    });
  }

  imageQuality() {
    return futureBuilder(
        future: toolbarImageQuality(context, widget.id, widget.ffi),
        hasData: (data) {
          final v = data as List<TRadioMenu<String>>;
          return _SubmenuButton(
            ffi: widget.ffi,
            child: Text(translate('Image Quality')),
            menuChildren: v
                .map((e) => RdoMenuButton<String>(
                    value: e.value,
                    groupValue: e.groupValue,
                    onChanged: e.onChanged,
                    child: e.child,
                    ffi: ffi))
                .toList(),
          );
        });
  }

  codec() {
    return futureBuilder(
        future: toolbarCodec(context, id, ffi),
        hasData: (data) {
          final v = data as List<TRadioMenu<String>>;
          if (v.isEmpty) return Offstage();

          return _SubmenuButton(
              ffi: widget.ffi,
              child: Text(translate('Codec')),
              menuChildren: v
                  .map((e) => RdoMenuButton(
                      value: e.value,
                      groupValue: e.groupValue,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi))
                  .toList());
        });
  }

  captureBackend() {
    return futureBuilder(
        future: toolbarCaptureBackend(ffi),
        hasData: (data) {
          final v = data as List<TRadioMenu<String>>;
          if (v.isEmpty) return Offstage();

          return _SubmenuButton(
              ffi: widget.ffi,
              child: Text(translate('Capture')),
              menuChildren: v
                  .map((e) => RdoMenuButton(
                      value: e.value,
                      groupValue: e.groupValue,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi))
                  .toList());
        });
  }

  Widget tabsInFullscreenToggle() {
    return Obx(() => CkbMenuButton(
          value: stateGlobal.tabsInFullscreen.value,
          onChanged: (value) {
            if (value != null) {
              unawaited(rustDeskWinManager.setTabsInFullscreen(value));
            }
          },
          child: Text(translate('Tabs in fullscreen')),
          ffi: ffi,
        ));
  }

  cursorToggles() {
    return futureBuilder(
        future: toolbarCursor(context, id, ffi),
        hasData: (data) {
          final v = data as List<TToggleMenu>;
          if (v.isEmpty) return Offstage();
          return Column(children: [
            Divider(),
            ...v
                .map((e) => CkbMenuButton(
                    value: e.value,
                    onChanged: e.onChanged,
                    child: e.child,
                    ffi: ffi))
                .toList(),
          ]);
        });
  }

  toggles() {
    return futureBuilder(
        future: Future.wait([
          toolbarQualityMonitorPosition(ffi),
          toolbarQualityMonitorDetails(ffi),
          toolbarClipboardDirection(ffi),
          toolbarDisplayToggle(context, id, ffi),
        ]),
        hasData: (data) {
          final qualityMonitor = data[0] as List<TRadioMenu<String>>;
          final qualityMonitorDetails = data[1] as List<TRadioMenu<String>>;
          final clipboard = data[2] as List<TRadioMenu<String>>;
          final toggles = data[3] as List<TToggleMenu>;
          if (qualityMonitor.isEmpty &&
              qualityMonitorDetails.isEmpty &&
              clipboard.isEmpty &&
              toggles.isEmpty) {
            return Offstage();
          }
          return Column(children: [
            if (qualityMonitor.isNotEmpty || qualityMonitorDetails.isNotEmpty)
              _SubmenuButton(
                ffi: widget.ffi,
                child: Text(translate('Quality monitor')),
                menuChildren: [
                  ...qualityMonitor.map((e) => RdoMenuButton<String>(
                        value: e.value,
                        groupValue: e.groupValue,
                        onChanged: e.onChanged,
                        child: e.child,
                        ffi: ffi,
                      )),
                  if (qualityMonitor.isNotEmpty &&
                      qualityMonitorDetails.isNotEmpty)
                    const Divider(),
                  ...qualityMonitorDetails.map((e) => RdoMenuButton<String>(
                        value: e.value,
                        groupValue: e.groupValue,
                        onChanged: e.onChanged,
                        child: e.child,
                        ffi: ffi,
                      )),
                ],
              ),
            if (clipboard.isNotEmpty)
              _SubmenuButton(
                ffi: widget.ffi,
                child: Text(translate('Clipboard')),
                menuChildren: clipboard
                    .map((e) => RdoMenuButton<String>(
                          value: e.value,
                          groupValue: e.groupValue,
                          onChanged: e.onChanged,
                          child: e.child,
                          ffi: ffi,
                        ))
                    .toList(),
              ),
            ...toggles
                .map((e) => CkbMenuButton(
                    value: e.value,
                    onChanged: e.onChanged,
                    child: e.child,
                    ffi: ffi))
                .toList(),
          ]);
        });
  }
}

class _CustomScaleMenuControls extends StatefulWidget {
  final FFI ffi;
  final ValueChanged<int>? onChanged;
  const _CustomScaleMenuControls({Key? key, required this.ffi, this.onChanged})
      : super(key: key);

  @override
  State<_CustomScaleMenuControls> createState() =>
      _CustomScaleMenuControlsState();
}

class _CustomScaleMenuControlsState
    extends CustomScaleControls<_CustomScaleMenuControls> {
  @override
  FFI get ffi => widget.ffi;

  @override
  ValueChanged<int>? get onScaleChanged => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const smallBtnConstraints = BoxConstraints(minWidth: 28, minHeight: 28);

    final sliderControl = Semantics(
      label: translate('Custom scale slider'),
      value: '$scaleValue%',
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: colorScheme.primary,
          thumbColor: colorScheme.primary,
          overlayColor: colorScheme.primary.withValues(alpha: 0.1),
          showValueIndicator: ShowValueIndicator.never,
          thumbShape: _RectValueThumbShape(
            min: CustomScaleControls.minPercent.toDouble(),
            max: CustomScaleControls.maxPercent.toDouble(),
            width: 52,
            height: 24,
            radius: 4,
            displayValueForNormalized: (t) => mapPosToPercent(t),
          ),
        ),
        child: Slider(
          value: scalePos,
          min: 0.0,
          max: 1.0,
          onChanged: onSliderChanged,
        ),
      ),
    );

    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(children: [
          Tooltip(
            message: translate('Decrease'),
            child: IconButton(
              iconSize: 16,
              padding: EdgeInsets.all(1),
              constraints: smallBtnConstraints,
              icon: const Icon(Icons.remove),
              onPressed: () => nudgeScale(-1),
            ),
          ),
          Expanded(child: sliderControl),
          Tooltip(
            message: translate('Increase'),
            child: IconButton(
              iconSize: 16,
              padding: EdgeInsets.all(1),
              constraints: smallBtnConstraints,
              icon: const Icon(Icons.add),
              onPressed: () => nudgeScale(1),
            ),
          ),
        ]),
      ),
      Divider(),
    ]);
  }
}

class _ScalePresetsMenu extends StatelessWidget {
  final FFI ffi;
  final RxInt customPercent;

  const _ScalePresetsMenu({
    Key? key,
    required this.ffi,
    required this.customPercent,
  }) : super(key: key);

  Future<void> _applyPreset(int percent) async {
    final next = clampCustomScalePercent(percent);
    await setSessionCustomScalePercent(ffi.sessionId, next);
    customPercent.value = next;
    await ffi.canvasModel.updateViewStyle();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() => _SubmenuButton(
          ffi: ffi,
          child: const Text('Scale'),
          menuChildren: kCustomScalePresetPercents
              .map((percent) => RdoMenuButton<int>(
                    value: percent,
                    groupValue:
                        kCustomScalePresetPercents.contains(customPercent.value)
                            ? customPercent.value
                            : null,
                    onChanged: (value) {
                      if (value != null) {
                        _applyPreset(value);
                      }
                    },
                    child: Text('$percent%'),
                    ffi: ffi,
                  ))
              .toList(),
        ));
  }
}

// Lightweight rectangular thumb that paints the current percentage.
// Stateless and uses only SliderTheme colors; avoids allocations beyond a TextPainter per frame.
class _RectValueThumbShape extends SliderComponentShape {
  final double min;
  final double max;
  final double width;
  final double height;
  final double radius;
  // Optional mapper to compute display value from normalized position [0,1]
  // If null, falls back to linear interpolation between min and max.
  final int Function(double normalized)? displayValueForNormalized;

  const _RectValueThumbShape({
    required this.min,
    required this.max,
    required this.width,
    required this.height,
    required this.radius,
    this.displayValueForNormalized,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size(width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;

    // Resolve color based on enabled/disabled animation, with safe fallbacks.
    final ColorTween colorTween = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    );
    final Color? evaluatedColor = colorTween.evaluate(enableAnimation);
    final Color? thumbColor = sliderTheme.thumbColor;
    final Color fillColor = evaluatedColor ?? thumbColor ?? Colors.blueAccent;

    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(radius),
    );
    final Paint paint = Paint()..color = fillColor;
    canvas.drawRRect(rrect, paint);

    // Compute displayed value from normalized slider value.
    final int displayValue = displayValueForNormalized != null
        ? displayValueForNormalized!(value)
        : (min + value * (max - min)).round();
    final TextSpan span = TextSpan(
      text: '$displayValue%',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
    final TextPainter tp = TextPainter(
      text: span,
      textAlign: TextAlign.center,
      textDirection: textDirection,
    );
    tp.layout(maxWidth: width - 4);
    tp.paint(
        canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }
}

class _ResolutionsMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ScreenAdjustor screenAdjustor;

  _ResolutionsMenu({
    Key? key,
    required this.id,
    required this.ffi,
    required this.screenAdjustor,
  }) : super(key: key);

  @override
  State<_ResolutionsMenu> createState() => _ResolutionsMenuState();
}

const double _kCustomResolutionEditingWidth = 42;
const _kCustomResolutionValue = 'custom';

class _ResolutionsMenuState extends State<_ResolutionsMenu> {
  String _groupValue = '';
  Resolution? _localResolution;

  late final TextEditingController _customWidth =
      TextEditingController(text: rect?.width.toInt().toString() ?? '');
  late final TextEditingController _customHeight =
      TextEditingController(text: rect?.height.toInt().toString() ?? '');

  FFI get ffi => widget.ffi;
  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;
  Rect? get rect => scaledRect();
  List<Resolution> get resolutions => pi.resolutions;
  bool get isWayland => bind.mainCurrentIsWayland();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _getLocalResolutionWayland();
    });
  }

  Rect? scaledRect() {
    final scale = pi.scaleOfDisplay(pi.currentDisplay);
    final rect = ffiModel.rect;
    if (rect == null) {
      return null;
    }
    return Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width / scale,
      rect.height / scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVirtualDisplay = ffiModel.isVirtualDisplayResolution;
    final visible = ffiModel.keyboard &&
        (isVirtualDisplay || resolutions.length > 1) &&
        pi.currentDisplay != kAllDisplayValue;
    if (!visible) return Offstage();
    final showOriginalBtn =
        ffiModel.isOriginalResolutionSet && !ffiModel.isOriginalResolution;
    final showFitLocalBtn = !_isRemoteResolutionFitLocal();
    _setGroupValue();
    return _SubmenuButton(
      ffi: widget.ffi,
      menuChildren: <Widget>[
            _OriginalResolutionMenuButton(context, showOriginalBtn),
            _FitLocalResolutionMenuButton(context, showFitLocalBtn),
            _customResolutionMenuButton(context, isVirtualDisplay),
            _menuDivider(showOriginalBtn, showFitLocalBtn, isVirtualDisplay),
          ] +
          _supportedResolutionMenuButtons(),
      child: Text(translate("Resolution")),
    );
  }

  _setGroupValue() {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    final lastGroupValue =
        stateGlobal.getLastResolutionGroupValue(widget.id, pi.currentDisplay);
    if (lastGroupValue == _kCustomResolutionValue) {
      _groupValue = _kCustomResolutionValue;
    } else {
      _groupValue =
          '${(rect?.width ?? 0).toInt()}x${(rect?.height ?? 0).toInt()}';
    }
  }

  _menuDivider(
      bool showOriginalBtn, bool showFitLocalBtn, bool isVirtualDisplay) {
    return Offstage(
      offstage: !(showOriginalBtn || showFitLocalBtn || isVirtualDisplay),
      child: Divider(),
    );
  }

  Future<void> _getLocalResolutionWayland() async {
    if (!isWayland) return _getLocalResolution();
    final window = await window_size.getWindowInfo();
    final screen = window.screen;
    if (screen != null) {
      setState(() {
        _localResolution = Resolution(
          screen.frame.width.toInt(),
          screen.frame.height.toInt(),
        );
      });
    }
  }

  _getLocalResolution() {
    _localResolution = null;
    final String mainDisplay = bind.mainGetMainDisplay();
    if (mainDisplay.isNotEmpty) {
      try {
        final display = json.decode(mainDisplay);
        if (display['w'] != null && display['h'] != null) {
          _localResolution = Resolution(display['w'], display['h']);
          if (isWeb) {
            if (display['scaleFactor'] != null) {
              _localResolution = Resolution(
                (display['w'] / display['scaleFactor']).toInt(),
                (display['h'] / display['scaleFactor']).toInt(),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Failed to decode $mainDisplay, $e');
      }
    }
  }

  // This widget has been unmounted, so the State no longer has a context
  _onChanged(String? value) async {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    stateGlobal.setLastResolutionGroupValue(
        widget.id, pi.currentDisplay, value);
    if (value == null) return;

    int? w;
    int? h;
    if (value == _kCustomResolutionValue) {
      w = int.tryParse(_customWidth.text);
      h = int.tryParse(_customHeight.text);
    } else {
      final list = value.split('x');
      if (list.length == 2) {
        w = int.tryParse(list[0]);
        h = int.tryParse(list[1]);
      }
    }

    if (w != null && h != null) {
      if (w != rect?.width.toInt() || h != rect?.height.toInt()) {
        await _changeResolution(w, h);
      }
    }
  }

  _changeResolution(int w, int h) async {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    await bind.sessionChangeResolution(
      sessionId: ffi.sessionId,
      display: pi.currentDisplay,
      width: w,
      height: h,
    );
    Future.delayed(Duration(seconds: 3), () async {
      final rect = ffiModel.rect;
      if (rect == null) {
        return;
      }
      if (w == rect.width.toInt() && h == rect.height.toInt()) {
        if (await widget.screenAdjustor.isWindowCanBeAdjusted()) {
          widget.screenAdjustor.doAdjustWindow(context);
        }
      }
    });
  }

  Widget _OriginalResolutionMenuButton(
      BuildContext context, bool showOriginalBtn) {
    final display = pi.tryGetDisplayIfNotAllDisplay();
    if (display == null) {
      return Offstage();
    }
    if (!resolutions.any((e) =>
        e.width == display.originalWidth &&
        e.height == display.originalHeight)) {
      return Offstage();
    }
    return Offstage(
      offstage: !showOriginalBtn,
      child: MenuButton(
        onPressed: () =>
            _changeResolution(display.originalWidth, display.originalHeight),
        ffi: widget.ffi,
        child: Text(
            '${translate('resolution_original_tip')} ${display.originalWidth}x${display.originalHeight}'),
      ),
    );
  }

  Widget _FitLocalResolutionMenuButton(
      BuildContext context, bool showFitLocalBtn) {
    return Offstage(
      offstage: !showFitLocalBtn,
      child: MenuButton(
        onPressed: () {
          final resolution = _getBestFitResolution();
          if (resolution != null) {
            _changeResolution(resolution.width, resolution.height);
          }
        },
        ffi: widget.ffi,
        child: Text(
            '${translate('resolution_fit_local_tip')} ${_localResolution?.width ?? 0}x${_localResolution?.height ?? 0}'),
      ),
    );
  }

  Widget _customResolutionMenuButton(BuildContext context, isVirtualDisplay) {
    return Offstage(
      offstage: !isVirtualDisplay,
      child: RdoMenuButton(
        value: _kCustomResolutionValue,
        groupValue: _groupValue,
        onChanged: (String? value) => _onChanged(value),
        ffi: widget.ffi,
        child: Row(
          children: [
            Text('${translate('resolution_custom_tip')} '),
            SizedBox(
              width: _kCustomResolutionEditingWidth,
              child: _resolutionInput(_customWidth),
            ),
            Text(' x '),
            SizedBox(
              width: _kCustomResolutionEditingWidth,
              child: _resolutionInput(_customHeight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resolutionInput(TextEditingController controller) {
    return TextField(
      decoration: InputDecoration(
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.fromLTRB(3, 3, 3, 3),
      ),
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
      ],
      controller: controller,
    ).workaroundFreezeLinuxMint();
  }

  List<Widget> _supportedResolutionMenuButtons() => resolutions
      .map((e) => RdoMenuButton(
          value: '${e.width}x${e.height}',
          groupValue: _groupValue,
          onChanged: (String? value) => _onChanged(value),
          ffi: widget.ffi,
          child: Text('${e.width}x${e.height}')))
      .toList();

  Resolution? _getBestFitResolution() {
    if (_localResolution == null) {
      return null;
    }

    if (ffiModel.isVirtualDisplayResolution) {
      return _localResolution!;
    }

    for (final r in resolutions) {
      if (r.width == _localResolution!.width &&
          r.height == _localResolution!.height) {
        return r;
      }
    }

    return null;
  }

  bool _isRemoteResolutionFitLocal() {
    if (_localResolution == null) {
      return true;
    }
    final bestFitResolution = _getBestFitResolution();
    if (bestFitResolution == null) {
      return true;
    }
    return bestFitResolution.width == rect?.width.toInt() &&
        bestFitResolution.height == rect?.height.toInt();
  }
}

class _KeyboardMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  _KeyboardMenu({
    Key? key,
    required this.id,
    required this.ffi,
  }) : super(key: key);

  PeerInfo get pi => ffi.ffiModel.pi;

  @override
  Widget build(BuildContext context) {
    var ffiModel = Provider.of<FfiModel>(context);
    if (!ffiModel.keyboard) return Offstage();
    toolbarToggles() {
      final toggles = toolbarKeyboardToggles(ffi)
          .map((e) => CkbMenuButton(
              value: e.value,
              onChanged: e.onChanged,
              child: e.child,
              ffi: ffi) as Widget)
          .toList();
      if (toggles.isNotEmpty) {
        toggles.add(Divider());
      }
      return toggles;
    }

    return _IconSubmenuButton(
        menuId: _ToolbarMenuId.keyboard,
        tooltip: 'Keyboard Settings',
        svg: "assets/keyboard_mouse.svg",
        ffi: ffi,
        color: _ToolbarTheme.blueColor,
        hoverColor: _ToolbarTheme.hoverBlueColor,
        menuChildrenGetter: (_) => [
              keyboardMode(),
              localKeyboardType(),
              inputSource(),
              Divider(),
              viewMode(),
              if (pi.capabilities.desktopCursorControls)
                showMyCursor(),
              Divider(),
              ...toolbarToggles(),
              ...mouseSpeed(),
              ...mobileActions(),
            ]);
  }

  mouseSpeed() {
    final speedWidgets = [];
    final sessionId = ffi.sessionId;
    if (isDesktop) {
      if (ffi.ffiModel.keyboard) {
        final enabled = !ffi.ffiModel.viewOnly;
        final trackpad = MenuButton(
          child: Text(translate('Trackpad speed')).paddingOnly(left: 26.0),
          onPressed: enabled ? () => trackpadSpeedDialog(sessionId, ffi) : null,
          ffi: ffi,
        );
        speedWidgets.add(trackpad);
      }
    }
    return speedWidgets;
  }

  keyboardMode() {
    return futureBuilder(future: () async {
      return await bind.sessionGetKeyboardMode(sessionId: ffi.sessionId) ??
          kKeyLegacyMode;
    }(), hasData: (data) {
      final groupValue = data as String;
      List<InputModeMenu> modes = [
        InputModeMenu(key: kKeyLegacyMode, menu: 'Legacy mode'),
        InputModeMenu(key: kKeyMapMode, menu: 'Map mode'),
        InputModeMenu(key: kKeyTranslateMode, menu: 'Translate mode'),
      ];
      List<RdoMenuButton> list = [];
      final enabled = !ffi.ffiModel.viewOnly;
      onChanged(String? value) async {
        if (value == null) return;
        await ffi.inputModel.resetKeyboard(
          KeyboardResetReason.inputModeChange,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
        await bind.sessionSetKeyboardMode(
            sessionId: ffi.sessionId, value: value);
        await ffi.inputModel.updateKeyboardMode();
      }

      // If use flutter to grab keys, we can only use one mode.
      // Map mode and Legacy mode, at least one of them is supported.
      String? modeOnly;
      // Keep both map and legacy mode on web at the moment.
      // TODO: Remove legacy mode after web supports translate mode on web.
      if (isInputSourceFlutter && isDesktop) {
        if (bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId, mode: kKeyMapMode)) {
          modeOnly = kKeyMapMode;
        } else if (bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId, mode: kKeyLegacyMode)) {
          modeOnly = kKeyLegacyMode;
        }
      }

      for (InputModeMenu mode in modes) {
        if (modeOnly != null && mode.key != modeOnly) {
          continue;
        } else if (!bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId, mode: mode.key)) {
          continue;
        }

        if (pi.isWayland) {
          // Legacy mode is hidden on desktop control side because dead keys
          // don't work properly on Wayland. When the control side is mobile,
          // Legacy mode is used automatically (mobile always sends Legacy events).
          if (mode.key == kKeyLegacyMode) {
            continue;
          }
          // Translate mode requires server >= 1.4.6.
          if (mode.key == kKeyTranslateMode &&
              versionCmp(pi.version, '1.4.6') < 0) {
            continue;
          }
        }

        var text = translate(mode.menu);
        if (mode.key == kKeyTranslateMode) {
          text = '$text beta';
        }
        list.add(RdoMenuButton<String>(
          child: Text(text),
          value: mode.key,
          groupValue: groupValue,
          onChanged: enabled ? onChanged : null,
          ffi: ffi,
        ));
      }
      return Column(children: list);
    });
  }

  localKeyboardType() {
    final localPlatform = getLocalPlatformForKBLayoutType(pi.platform);
    final visible = localPlatform != '';
    if (!visible) return Offstage();
    final enabled = !ffi.ffiModel.viewOnly;
    return Column(
      children: [
        Divider(),
        MenuButton(
          child: Text(
              '${translate('Local keyboard type')}: ${KBLayoutType.value}'),
          trailingIcon: const Icon(Icons.settings),
          ffi: ffi,
          onPressed: enabled
              ? () => showKBLayoutTypeChooser(localPlatform, ffi.dialogManager)
              : null,
        )
      ],
    );
  }

  inputSource() {
    final supportedInputSource = bind.mainSupportedInputSource();
    if (supportedInputSource.isEmpty) return Offstage();
    late final List<dynamic> supportedInputSourceList;
    try {
      supportedInputSourceList = jsonDecode(supportedInputSource);
    } catch (e) {
      debugPrint('Failed to decode $supportedInputSource, $e');
      return;
    }
    if (supportedInputSourceList.length < 2) return Offstage();
    final inputSource = stateGlobal.getInputSource();
    final enabled = !ffi.ffiModel.viewOnly;
    final children = <Widget>[Divider()];
    children.addAll(supportedInputSourceList.map((e) {
      final d = e as List<dynamic>;
      return RdoMenuButton<String>(
        child: Text(translate(d[1] as String)),
        value: d[0] as String,
        groupValue: inputSource,
        onChanged: enabled
            ? (v) async {
                if (v != null) {
                  await ffi.inputModel.resetKeyboard(
                    KeyboardResetReason.inputModeChange,
                    invalidatePending: true,
                    allowBlockedReleases: true,
                  );
                  await stateGlobal.setInputSource(ffi.sessionId, v);
                  await ffi.ffiModel.checkDesktopKeyboardMode();
                  await ffi.inputModel.updateKeyboardMode();
                }
              }
            : null,
        ffi: ffi,
      );
    }));
    return Column(children: children);
  }

  viewMode() {
    final ffiModel = ffi.ffiModel;
    final liveSettings = LiveSessionSettingsRepository.forSession(ffi.sessionId);
    final enabled = versionCmp(pi.version, '1.2.0') >= 0 && ffiModel.keyboard;
    return CkbMenuButton(
        value: ffiModel.viewOnly,
        onChanged: enabled
            ? (value) async {
                if (value == null) return;
                final viewOnly = await liveSettings.toggleAndRead(
                  LiveSessionSettingsRegistry.viewOnly,
                  fallback: value,
                );
                ffiModel.setViewOnly(id, viewOnly);
                final showMyCursor = await liveSettings.read(
                  LiveSessionSettingsRegistry.showMyCursor,
                  fallback: value,
                );
                ffiModel.setShowMyCursor(showMyCursor);
              }
            : null,
        ffi: ffi,
        child: Text(translate('View Mode')));
  }

  showMyCursor() {
    final ffiModel = ffi.ffiModel;
    final liveSettings = LiveSessionSettingsRepository.forSession(ffi.sessionId);
    return CkbMenuButton(
            value: ffiModel.showMyCursor,
            onChanged: (value) async {
              if (value == null) return;
              final showMyCursor = await liveSettings.toggleAndRead(
                LiveSessionSettingsRegistry.showMyCursor,
                fallback: value,
              );
              ffiModel.setShowMyCursor(showMyCursor);

              // Also set view only if showMyCursor is enabled and viewOnly is not enabled.
              if (showMyCursor && !ffiModel.viewOnly) {
                final viewOnly = await liveSettings.toggleAndRead(
                  LiveSessionSettingsRegistry.viewOnly,
                  fallback: true,
                );
                ffiModel.setViewOnly(id, viewOnly);
              }
            },
            ffi: ffi,
            child: Text(translate('Show my cursor')))
        .paddingOnly(left: 26.0);
  }

  mobileActions() {
    if (!pi.capabilities.mobileSystemActions) return [];
    final enabled = versionCmp(pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      Divider(),
      MenuButton(
          child: Text(translate('Back')),
          onPressed: () => ffi.inputModel.onMobileBack(),
          ffi: ffi),
      MenuButton(
          child: Text(translate('Home')),
          onPressed: () => ffi.inputModel.onMobileHome(),
          ffi: ffi),
      MenuButton(
          child: Text(translate('Apps')),
          onPressed: () => ffi.inputModel.onMobileApps(),
          ffi: ffi),
      MenuButton(
          child: Text(translate('Volume up')),
          onPressed: () => ffi.inputModel.onMobileVolumeUp(),
          ffi: ffi),
      MenuButton(
          child: Text(translate('Volume down')),
          onPressed: () => ffi.inputModel.onMobileVolumeDown(),
          ffi: ffi),
      MenuButton(
          child: Text(translate('Power')),
          onPressed: () => ffi.inputModel.onMobilePower(),
          ffi: ffi),
    ];
  }
}

class _ChatMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  _ChatMenu({
    Key? key,
    required this.id,
    required this.ffi,
  }) : super(key: key);

  @override
  State<_ChatMenu> createState() => _ChatMenuState();
}

class _ChatMenuState extends State<_ChatMenu> {
  // Using in StatelessWidget got `Looking up a deactivated widget's ancestor is unsafe`.
  final chatButtonKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    if (isWeb) {
      return buildTextChatButton();
    } else {
      return _IconSubmenuButton(
          menuId: _ToolbarMenuId.chat,
          tooltip: 'Chat',
          key: chatButtonKey,
          svg: 'assets/chat.svg',
          ffi: widget.ffi,
          color: _ToolbarTheme.blueColor,
          hoverColor: _ToolbarTheme.hoverBlueColor,
          menuChildrenGetter: (_) => [textChat(), voiceCall()]);
    }
  }

  buildTextChatButton() {
    return _IconMenuButton(
      assetName: 'assets/message_24dp_5F6368.svg',
      tooltip: 'Text chat',
      key: chatButtonKey,
      onPressed: _textChatOnPressed,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
    );
  }

  textChat() {
    return MenuButton(
        child: Text(translate('Text chat')),
        ffi: widget.ffi,
        onPressed: _textChatOnPressed);
  }

  _textChatOnPressed() {
    RenderBox? renderBox =
        chatButtonKey.currentContext?.findRenderObject() as RenderBox?;
    Offset? initPos;
    if (renderBox != null) {
      final pos = renderBox.localToGlobal(Offset.zero);
      initPos = Offset(pos.dx, pos.dy + _ToolbarTheme.dividerHeight);
    }
    widget.ffi.chatModel
        .changeCurrentKey(MessageKey(widget.ffi.id, ChatModel.clientModeID));
    widget.ffi.chatModel.toggleChatOverlay(chatInitPos: initPos);
  }

  voiceCall() {
    return MenuButton(
      child: Text(translate('Voice call')),
      ffi: widget.ffi,
      onPressed: () =>
          bind.sessionRequestVoiceCall(sessionId: widget.ffi.sessionId),
    );
  }
}

class _VoiceCallMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  _VoiceCallMenu({
    Key? key,
    required this.id,
    required this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    menuChildrenGetter(_IconSubmenuButtonState state) {
      final audioInput = AudioInput(
        builder: (devices, currentDevice, setDevice) {
          return Column(
            children: devices
                .map((d) => RdoMenuButton<String>(
                      child: Container(
                        child: Text(
                          d,
                          overflow: TextOverflow.ellipsis,
                        ),
                        constraints: BoxConstraints(maxWidth: 250),
                      ),
                      value: d,
                      groupValue: currentDevice,
                      onChanged: (v) {
                        if (v != null) setDevice(v);
                      },
                      ffi: ffi,
                    ))
                .toList(),
          );
        },
        isCm: false,
        isVoiceCall: true,
      );
      return [
        audioInput,
        Divider(),
        MenuButton(
          child: Text(translate('End call')),
          onPressed: () => bind.sessionCloseVoiceCall(sessionId: ffi.sessionId),
          ffi: ffi,
        ),
      ];
    }

    return Obx(
      () {
        switch (ffi.chatModel.voiceCallStatus.value) {
          case VoiceCallStatus.waitingForResponse:
            return buildCallWaiting(context);
          case VoiceCallStatus.connected:
            return _IconSubmenuButton(
              menuId: _ToolbarMenuId.voiceCall,
              tooltip: 'Voice call',
              svg: 'assets/voice_call.svg',
              color: _ToolbarTheme.blueColor,
              hoverColor: _ToolbarTheme.hoverBlueColor,
              menuChildrenGetter: menuChildrenGetter,
              ffi: ffi,
            );
          default:
            return Offstage();
        }
      },
    );
  }

  Widget buildCallWaiting(BuildContext context) {
    return _IconMenuButton(
      assetName: "assets/call_wait.svg",
      tooltip: "Waiting",
      onPressed: () => bind.sessionCloseVoiceCall(sessionId: ffi.sessionId),
      color: _ToolbarTheme.redColor,
      hoverColor: _ToolbarTheme.hoverRedColor,
    );
  }
}

class _RecordMenu extends StatelessWidget {
  const _RecordMenu({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var ffi = Provider.of<FfiModel>(context);
    var recordingModel = Provider.of<RecordingModel>(context);
    final visible =
        (recordingModel.start || ffi.permissions['recording'] != false);
    if (!visible) return Offstage();
    return _IconMenuButton(
      assetName: 'assets/rec.svg',
      tooltip: recordingModel.start
          ? 'Stop session recording'
          : 'Start session recording',
      onPressed: () => recordingModel.toggle(),
      color: recordingModel.start
          ? _ToolbarTheme.redColor
          : _ToolbarTheme.blueColor,
      hoverColor: recordingModel.start
          ? _ToolbarTheme.hoverRedColor
          : _ToolbarTheme.hoverBlueColor,
    );
  }
}

class _CollapseMenu extends StatelessWidget {
  final SessionID sessionId;
  final ToolbarState state;

  const _CollapseMenu({
    Key? key,
    required this.sessionId,
    required this.state,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() => _IconMenuButton(
          tooltip: 'Collapse Toolbar',
          icon: _rotateToolbarIconForVertical(
            vertical: state.vertical.value,
            child: const Icon(
              Icons.expand_less,
              size: _ToolbarTheme.buttonSize,
              color: Colors.white,
            ),
          ),
          onPressed: () => state.switchCollapse(sessionId),
          color: _ToolbarTheme.inactiveColor,
          hoverColor: _ToolbarTheme.hoverInactiveColor,
        ));
  }
}

class _CloseMenu extends StatelessWidget {
  final FFI ffi;
  final VoidCallback onCloseConnection;
  const _CloseMenu({
    Key? key,
    required this.ffi,
    required this.onCloseConnection,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconMenuButton(
      assetName: 'assets/close.svg',
      tooltip: 'Close',
      onPressed: () async {
        if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) {
          return;
        }
        onCloseConnection();
      },
      color: _ToolbarTheme.redColor,
      hoverColor: _ToolbarTheme.hoverRedColor,
    );
  }
}

class _IconMenuButton extends StatefulWidget {
  final String? assetName;
  final Widget? icon;
  final String tooltip;
  final Color color;
  final Color hoverColor;
  final VoidCallback? onPressed;
  final double? hMargin;
  final double? vMargin;
  final bool topLevel;
  final double? width;
  final double? height;
  final bool useToolbarSpacing;
  const _IconMenuButton({
    Key? key,
    this.assetName,
    this.icon,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.onPressed,
    this.hMargin,
    this.vMargin,
    this.topLevel = true,
    this.width,
    this.height,
    this.useToolbarSpacing = false,
  }) : super(key: key);

  @override
  State<_IconMenuButton> createState() => _IconMenuButtonState();
}

class _IconMenuButtonState extends State<_IconMenuButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final menuLifecycle = _ToolbarMenuLifecycleScope.maybeOf(context);
    assert(widget.assetName != null || widget.icon != null);
    final icon = widget.icon ??
        SvgPicture.asset(
          widget.assetName!,
          colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn),
          width: _ToolbarTheme.buttonSize,
          height: _ToolbarTheme.buttonSize,
        );
    Widget button = Padding(
      padding: _toolbarItemMargin(
        context,
        hMargin: widget.hMargin,
        vMargin: widget.vMargin,
        useToolbarSpacing: widget.topLevel || widget.useToolbarSpacing,
      ),
      child: SizedBox(
        width: widget.width ?? _ToolbarTheme.buttonSize,
        height: widget.height ?? _ToolbarTheme.buttonSize,
        child: MenuItemButton(
            style: ButtonStyle(
                backgroundColor: MaterialStatePropertyAll(Colors.transparent),
                padding: MaterialStatePropertyAll(EdgeInsets.zero),
                overlayColor: MaterialStatePropertyAll(Colors.transparent)),
            onHover: (value) => setState(() {
                  hover = value;
                }),
            onPressed: widget.onPressed == null
                ? null
                : () {
                    if (widget.topLevel) {
                      menuLifecycle?.coordinator.closeAll();
                    }
                    widget.onPressed?.call();
                  },
            child: Tooltip(
              message: translate(widget.tooltip),
              child: Material(
                  type: MaterialType.transparency,
                  child: Ink(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(_ToolbarTheme.iconRadius),
                        color: hover ? widget.hoverColor : widget.color,
                      ),
                      child: icon)),
            )),
      ),
    );
    button = Tooltip(
      message: widget.tooltip,
      child: button,
    );
    return button;
  }
}

class _IconSubmenuButton extends StatefulWidget {
  final _ToolbarMenuId menuId;
  final String tooltip;
  final String? svg;
  final Widget? icon;
  final Color color;
  final Color hoverColor;
  final List<Widget> Function(_IconSubmenuButtonState state) menuChildrenGetter;
  final MenuStyle? menuStyle;
  final FFI? ffi;
  final double? width;
  final double? height;

  _IconSubmenuButton({
    Key? key,
    required this.menuId,
    this.svg,
    this.icon,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.menuChildrenGetter,
    this.ffi,
    this.menuStyle,
    this.width,
    this.height,
  }) : super(key: key);

  @override
  State<_IconSubmenuButton> createState() => _IconSubmenuButtonState();
}

class _IconSubmenuButtonState extends State<_IconSubmenuButton> {
  bool hover = false;
  bool _pointerMenuToggleHandled = false;
  final MenuController _menuController = MenuController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'toolbarMenuButton');
  late final ToolbarMenuHandle _menuHandle;
  ToolbarMenuCoordinator<_ToolbarMenuId>? _coordinator;

  @override
  void initState() {
    super.initState();
    _menuHandle = ToolbarMenuHandle(
      isOpen: () => _menuController.isOpen,
      open: () => _menuController.open(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _ToolbarMenuLifecycleScope.maybeOf(context)?.coordinator;
    if (identical(next, _coordinator)) return;
    _coordinator?.unregisterMenu(widget.menuId, _menuHandle);
    _coordinator = next;
    _coordinator?.registerMenu(widget.menuId, _menuHandle);
  }

  @override
  void didUpdateWidget(_IconSubmenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.menuId == widget.menuId) return;
    _coordinator?.unregisterMenu(oldWidget.menuId, _menuHandle);
    _coordinator?.registerMenu(widget.menuId, _menuHandle);
  }

  @override
  void dispose() {
    _coordinator?.unregisterMenu(widget.menuId, _menuHandle);
    _focusNode.dispose();
    super.dispose();
  }

  @override // discard @protected
  void setState(VoidCallback fn) {
    super.setState(fn);
  }

  void _activateMenu() => _coordinator?.activate(widget.menuId);

  @override
  Widget build(BuildContext context) {
    assert(widget.svg != null || widget.icon != null);
    final icon = widget.icon ??
        SvgPicture.asset(
          widget.svg!,
          colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn),
          width: _ToolbarTheme.buttonSize,
          height: _ToolbarTheme.buttonSize,
        );
    final buttonChild = Tooltip(
      message: translate(widget.tooltip),
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_ToolbarTheme.iconRadius),
            color: hover ? widget.hoverColor : widget.color,
          ),
          child: icon,
        ),
      ),
    );
    final button = SizedBox(
      width: widget.width ?? _ToolbarTheme.buttonSize,
      height: widget.height ?? _ToolbarTheme.buttonSize,
      child: MenuAnchor(
        controller: _menuController,
        childFocusNode: _focusNode,
        style: _topLevelToolbarMenuStyle(context, widget.menuStyle),
        alignmentOffset:
            _topLevelToolbarMenuAlignmentOffset(context, widget.menuStyle),
        consumeOutsideTap: false,
        onOpen: () => _coordinator?.menuOpened(widget.menuId),
        onClose: () => _coordinator?.menuClosed(widget.menuId),
        onAnimationStatusChanged: (status) {
          if (_menuController.isOpen &&
              (status == AnimationStatus.reverse ||
                  status == AnimationStatus.dismissed)) {
            _coordinator?.menuClosing(widget.menuId);
          }
        },
        menuChildren: _toolbarMenuChildren(
          context,
          widget.menuStyle,
          widget.menuChildrenGetter(this),
          widget.ffi,
        ),
        builder: (context, controller, child) => Semantics(
          expanded: controller.isOpen,
          child: Listener(
            onPointerDown: (event) {
              if ((event.buttons & kPrimaryButton) == 0) {
                return;
              }
              _pointerMenuToggleHandled = true;
            },
            onPointerUp: (_) {
              if (!_pointerMenuToggleHandled) {
                return;
              }
              // Open after pointer-down dismissal and dimming work completes.
              // The raw listener keeps this path reliable even when closing a
              // sibling overlay cancels the TextButton gesture recognizer.
              _activateMenu();
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _pointerMenuToggleHandled = false,
              );
            },
            onPointerCancel: (_) => _pointerMenuToggleHandled = false,
            child: TextButton(
              focusNode: _focusNode,
              style: _ToolbarTheme.defaultMenuButtonStyle,
              onHover: (value) => setState(() {
                hover = value;
              }),
              onPressed: () {
                if (_pointerMenuToggleHandled) {
                  return;
                }
                _activateMenu();
              },
              child: child ?? buttonChild,
            ),
          ),
        ),
        child: buttonChild,
      ),
    );
    return Padding(
      padding: _toolbarItemMargin(context),
      child: button,
    );
  }
}

class _SubmenuButton extends StatelessWidget {
  final List<Widget> menuChildren;
  final Widget? child;
  final FFI ffi;
  const _SubmenuButton({
    Key? key,
    required this.menuChildren,
    required this.child,
    required this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SubmenuButton(
      key: key,
      child: child,
      menuChildren: _toolbarMenuChildren(context, null, menuChildren, ffi),
      menuStyle: _toolbarMenuStyle(context, null),
      alignmentOffset: _toolbarMenuAlignmentOffset(context),
    );
  }
}

class MenuButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget? trailingIcon;
  final Widget? child;
  final FFI? ffi;
  MenuButton(
      {Key? key,
      this.onPressed,
      this.trailingIcon,
      required this.child,
      this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
        key: key,
        onPressed: onPressed != null
            ? () {
                if (ffi != null) {
                  _menuDismissCallback(ffi!);
                }
                onPressed?.call();
              }
            : null,
        trailingIcon: trailingIcon,
        child: child);
  }
}

class CkbMenuButton extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? child;
  final FFI? ffi;
  const CkbMenuButton(
      {Key? key,
      required this.value,
      required this.onChanged,
      required this.child,
      this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CheckboxMenuButton(
      key: key,
      value: value,
      child: child,
      onChanged: onChanged != null
          ? (bool? value) {
              if (ffi != null) {
                _menuDismissCallback(ffi!);
              }
              onChanged?.call(value);
            }
          : null,
    );
  }
}

class RdoMenuButton<T> extends StatelessWidget {
  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final Widget? child;
  final FFI? ffi;
  // When true, submenu will be dismissed on activate; when false, it stays open.
  final bool closeOnActivate;
  const RdoMenuButton({
    Key? key,
    required this.value,
    required this.groupValue,
    required this.child,
    this.ffi,
    this.onChanged,
    this.closeOnActivate = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return RadioMenuButton(
      value: value,
      groupValue: groupValue,
      child: child,
      closeOnActivate: closeOnActivate,
      onChanged: onChanged != null
          ? (T? value) {
              if (ffi != null && closeOnActivate) {
                _menuDismissCallback(ffi!);
              }
              onChanged?.call(value);
            }
          : null,
    );
  }
}

class _DraggableShowHide extends StatefulWidget {
  final String id;
  final SessionID sessionId;
  final RxDouble fractionX;
  final RxDouble fractionY;
  final RxBool dragging;
  final ToolbarState toolbarState;
  final BorderRadius borderRadius;

  final Function(bool) setFullscreen;
  final Function() setMinimize;

  const _DraggableShowHide({
    Key? key,
    required this.id,
    required this.sessionId,
    required this.fractionX,
    required this.fractionY,
    required this.dragging,
    required this.toolbarState,
    required this.setFullscreen,
    required this.setMinimize,
    required this.borderRadius,
  }) : super(key: key);

  @override
  State<_DraggableShowHide> createState() => _DraggableShowHideState();
}

class _DraggableShowHideState extends State<_DraggableShowHide> {
  Offset position = Offset.zero;
  Size size = Size.zero;
  double left = 0.0;
  double right = 1.0;

  RxBool get collapse => widget.toolbarState.collapse;
  RxBool get vertical => widget.toolbarState.vertical;

  @override
  initState() {
    super.initState();
    left = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.toolbarDragLeft,
    );
    right = remoteAppLocalSettings.read(
      RemoteAppLocalSettingsRegistry.toolbarDragRight,
    );
  }

  Widget _buildDraggable(BuildContext context) {
    return Draggable(
      axis: widget.toolbarState.pin ? null : Axis.horizontal,
      child: Icon(
        Icons.drag_indicator,
        size: 20,
        color: MyTheme.color(context).drag_indicator,
      ),
      feedback: widget,
      onDragStarted: (() {
        final RenderObject? renderObj = context.findRenderObject();
        if (renderObj != null) {
          final RenderBox renderBox = renderObj as RenderBox;
          size = renderBox.size;
          position = renderBox.localToGlobal(Offset.zero);
        }
        widget.dragging.value = true;
      }),
      onDragEnd: (details) {
        final mediaSize = MediaQueryData.fromView(View.of(context)).size;
        final rangeX = math.max(1.0, mediaSize.width - size.width);
        widget.fractionX.value +=
            (details.offset.dx - position.dx) / rangeX;
        if (widget.fractionX.value < left) {
          widget.fractionX.value = left;
        }
        if (widget.fractionX.value > right) {
          widget.fractionX.value = right;
        }
        if (widget.toolbarState.pin) {
          final rangeY = math.max(1.0, mediaSize.height - size.height);
          widget.fractionY.value += (details.offset.dy - position.dy) / rangeY;
          widget.fractionY.value =
              widget.fractionY.value.clamp(0.0, 1.0).toDouble();
        }
        final settings = SessionPeerSettingsRepository.forSession(
          widget.sessionId,
        );
        unawaited(
          settings.write(
            SessionPeerSettingsRegistry.toolbarDragX,
            widget.fractionX.value,
          ),
        );
        unawaited(
          settings.write(
            SessionPeerSettingsRegistry.toolbarDragY,
            widget.fractionY.value,
          ),
        );
        widget.dragging.value = false;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ButtonStyle buttonStyle = ButtonStyle(
      minimumSize: MaterialStateProperty.all(const Size(0, 0)),
      padding: MaterialStateProperty.all(EdgeInsets.zero),
    );
    final isFullscreen = stateGlobal.fullscreen;
    const double iconSize = 20;

    buttonWrapper(VoidCallback? onPressed, Widget child,
        {Color hoverColor = _ToolbarTheme.blueColor}) {
      final bgColor = buttonStyle.backgroundColor?.resolve({});
      return TextButton(
        onPressed: onPressed,
        child: child,
        style: buttonStyle.copyWith(
          backgroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.hovered)) {
              return (bgColor ?? hoverColor).withOpacity(0.15);
            }
            return bgColor;
          }),
        ),
      );
    }

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDraggable(context),
        Obx(() => buttonWrapper(
              () => widget.toolbarState.switchOrientation(widget.sessionId),
              Tooltip(
                message: translate(vertical.isTrue
                    ? 'Vertical Toolbar'
                    : 'Horizontal Toolbar'),
                child: _ToolbarOrientationGlyph(
                  vertical: vertical.value,
                  size: iconSize,
                ),
              ),
            )),
        Obx(() => buttonWrapper(
              () {
                widget.setFullscreen(!isFullscreen.value);
              },
              Tooltip(
                message: translate(
                    isFullscreen.isTrue ? 'Exit Fullscreen' : 'Fullscreen'),
                child: Icon(
                  isFullscreen.isTrue
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  size: iconSize,
                ),
              ),
            )),
        if (!isMacOS && !isWebDesktop)
          Obx(() => Offstage(
                offstage: isFullscreen.isFalse,
                child: buttonWrapper(
                  widget.setMinimize,
                  Tooltip(
                    message: translate('Minimize'),
                    child: Icon(
                      Icons.remove,
                      size: iconSize,
                    ),
                  ),
                ),
              )),
        buttonWrapper(
          () => setState(() {
            widget.toolbarState.switchCollapse(widget.sessionId);
          }),
          Obx((() {
            final isCollapsed = collapse.isTrue;
            return Tooltip(
              message: translate(
                  isCollapsed ? 'Expand Toolbar' : 'Collapse Toolbar'),
              child: _rotateToolbarIconForVertical(
                vertical: vertical.value,
                child: Icon(
                  isCollapsed ? Icons.expand_more : Icons.expand_less,
                  size: iconSize,
                ),
              ),
            );
          })),
        ),
        if (isWebDesktop)
          Obx(() {
            if (collapse.isFalse) {
              return Offstage();
            } else {
              return buttonWrapper(
                () => closeConnection(id: widget.id),
                Tooltip(
                  message: translate('Close'),
                  child: Icon(
                    Icons.close,
                    size: iconSize,
                    color: _ToolbarTheme.redColor,
                  ),
                ),
                hoverColor: _ToolbarTheme.redColor,
              ).paddingOnly(left: iconSize / 2);
            }
          })
      ],
    );
    return TextButtonTheme(
      data: TextButtonThemeData(style: buttonStyle),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context)
              .menuBarTheme
              .style
              ?.backgroundColor
              ?.resolve(MaterialState.values.toSet()),
          border: Border.all(
            color: _ToolbarTheme.borderColor(context),
            width: 1,
          ),
          borderRadius: widget.borderRadius,
        ),
        child: SizedBox(
          height: 20,
          child: child,
        ),
      ),
    );
  }
}

class InputModeMenu {
  final String key;
  final String menu;

  InputModeMenu({required this.key, required this.menu});
}

_menuDismissCallback(FFI ffi) => ffi.inputModel.refreshMousePos();

Widget _buildPointerTrackWidget(BuildContext context, Widget child, FFI? ffi) {
  final menuLifecycle = _ToolbarMenuLifecycleScope.maybeOf(context);
  final tracked = Listener(
    onPointerHover: (PointerHoverEvent e) => {
      if (ffi != null) {ffi.inputModel.lastMousePos = e.position}
    },
    child: MouseRegion(
      onEnter: (_) => menuLifecycle?.onMenuPointerEnter(),
      onExit: (_) => menuLifecycle?.onMenuPointerExit(),
      child: child,
    ),
  );
  if (menuLifecycle == null) {
    return tracked;
  }
  return _ToolbarMenuLifecycleScope(
    coordinator: menuLifecycle.coordinator,
    onMenuPointerEnter: menuLifecycle.onMenuPointerEnter,
    onMenuPointerExit: menuLifecycle.onMenuPointerExit,
    verticalToolbar: menuLifecycle.verticalToolbar,
    openMenusLeft: menuLifecycle.openMenusLeft,
    child: tracked,
  );
}
