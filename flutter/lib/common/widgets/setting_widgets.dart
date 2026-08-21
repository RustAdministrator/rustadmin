import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

Widget customImageQualityWidget({
  required double initQuality,
  required double initFps,
  required String initFpsMode,
  required Function(double)? setQuality,
  required Function(double)? setFps,
  required Function(String)? setFpsMode,
  required bool showFps,
  required bool showMoreQuality,
  bool showQuality = true,
  bool showFpsMode = true,
  String fpsLabel = 'FPS',
}) {
  return CustomImageQualityWidget(
    initQuality: initQuality,
    initFps: initFps,
    initFpsMode: initFpsMode,
    setQuality: setQuality,
    setFps: setFps,
    setFpsMode: setFpsMode,
    showFps: showFps,
    showMoreQuality: showMoreQuality,
    showQuality: showQuality,
    showFpsMode: showFpsMode,
    fpsLabel: fpsLabel,
  );
}

class CustomImageQualityWidget extends StatefulWidget {
  const CustomImageQualityWidget({
    super.key,
    required this.initQuality,
    required this.initFps,
    required this.initFpsMode,
    required this.setQuality,
    required this.setFps,
    required this.setFpsMode,
    required this.showFps,
    required this.showMoreQuality,
    this.showQuality = true,
    this.showFpsMode = true,
    this.fpsLabel = 'FPS',
    this.translateText,
  });

  final double initQuality;
  final double initFps;
  final String initFpsMode;
  final Function(double)? setQuality;
  final Function(double)? setFps;
  final Function(String)? setFpsMode;
  final bool showFps;
  final bool showMoreQuality;
  final bool showQuality;
  final bool showFpsMode;
  final String fpsLabel;
  final String Function(String)? translateText;

  @override
  State<CustomImageQualityWidget> createState() =>
      _CustomImageQualityWidgetState();
}

class _CustomImageQualityWidgetState extends State<CustomImageQualityWidget> {
  late final RxDouble _qualityValue;
  late final RxDouble _fpsValue;
  late final RxString _fpsModeValue;
  late final RxBool _moreQualityChecked;
  late Debouncer<double> _debouncerQuality;
  late Debouncer<double> _debouncerFps;

  double _normalizedQuality(double value, bool showMoreQuality) {
    if (value < kMinQuality ||
        value > (showMoreQuality ? kMaxMoreQuality : kMaxQuality)) {
      return kDefaultQuality;
    }
    return value;
  }

  double _normalizedFps(double value) {
    if (value < kMinFps || value > kMaxFps) {
      return kDefaultFps;
    }
    return value;
  }

  Debouncer<double> _qualityDebouncer(double initialValue) {
    return Debouncer<double>(
      const Duration(milliseconds: 1000),
      onChanged: (value) {
        if (mounted) {
          widget.setQuality?.call(value);
        }
      },
      initialValue: initialValue,
    );
  }

  Debouncer<double> _fpsDebouncer(double initialValue) {
    return Debouncer<double>(
      const Duration(milliseconds: 1000),
      onChanged: (value) {
        if (mounted) {
          widget.setFps?.call(value);
        }
      },
      initialValue: initialValue,
    );
  }

  @override
  void initState() {
    super.initState();
    final quality = _normalizedQuality(
      widget.initQuality,
      widget.showMoreQuality,
    );
    final fps = _normalizedFps(widget.initFps);
    _qualityValue = quality.obs;
    _fpsValue = fps.obs;
    _fpsModeValue =
        (widget.initFpsMode == kCustomFpsModeFixed
                ? kCustomFpsModeFixed
                : kCustomFpsModeAdaptive)
            .obs;
    _moreQualityChecked = RxBool(quality > kMaxQuality);
    _debouncerQuality = _qualityDebouncer(quality);
    _debouncerFps = _fpsDebouncer(fps);
  }

  @override
  void didUpdateWidget(covariant CustomImageQualityWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initQuality != widget.initQuality ||
        oldWidget.showMoreQuality != widget.showMoreQuality) {
      final quality = _normalizedQuality(
        widget.initQuality,
        widget.showMoreQuality,
      );
      _debouncerQuality.cancel();
      _debouncerQuality = _qualityDebouncer(quality);
      _qualityValue.value = quality;
      _moreQualityChecked.value = quality > kMaxQuality;
    }
    if (oldWidget.initFps != widget.initFps) {
      final fps = _normalizedFps(widget.initFps);
      _debouncerFps.cancel();
      _debouncerFps = _fpsDebouncer(fps);
      _fpsValue.value = fps;
    }
    if (oldWidget.initFpsMode != widget.initFpsMode) {
      _fpsModeValue.value = widget.initFpsMode == kCustomFpsModeFixed
          ? kCustomFpsModeFixed
          : kCustomFpsModeAdaptive;
    }
  }

  @override
  void dispose() {
    _debouncerQuality.cancel();
    _debouncerFps.cancel();
    _qualityValue.close();
    _fpsValue.close();
    _fpsModeValue.close();
    _moreQualityChecked.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qualityValue = _qualityValue;
    final fpsValue = _fpsValue;
    final fpsModeValue = _fpsModeValue;
    final moreQualityChecked = _moreQualityChecked;
    final debouncerQuality = _debouncerQuality;
    final debouncerFps = _debouncerFps;
    final setQuality = widget.setQuality;
    final setFps = widget.setFps;
    final setFpsMode = widget.setFpsMode;
    final showFps = widget.showFps;
    final showMoreQuality = widget.showMoreQuality;
    final showQuality = widget.showQuality;
    final showFpsMode = widget.showFpsMode;
    final translateText = widget.translateText ?? translate;

    void onMoreChanged(bool? value) {
      if (value == null) return;
      moreQualityChecked.value = value;
      if (!value && qualityValue.value > 100) {
        qualityValue.value = 100;
      }
      debouncerQuality.value = qualityValue.value;
    }

    return Column(
      children: [
        if (showQuality)
          Obx(
          () => Row(
            children: [
              Expanded(
                flex: 3,
                child: Slider(
                  key: const Key('custom-image-quality-slider'),
                  value: qualityValue.value,
                  min: kMinQuality,
                  max: moreQualityChecked.value ? kMaxMoreQuality : kMaxQuality,
                  divisions: moreQualityChecked.value
                      ? ((kMaxMoreQuality - kMinQuality) / 10).round()
                      : ((kMaxQuality - kMinQuality) / 5).round(),
                  onChanged: setQuality == null
                      ? null
                      : (double value) async {
                          qualityValue.value = value;
                          debouncerQuality.value = value;
                        },
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  '${qualityValue.value.round()}%',
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              Expanded(
                flex: isMobile ? 2 : 1,
                child: Text(
                  translateText('Bitrate'),
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              // mobile doesn't have enough space
              if (showMoreQuality && !isMobile)
                Expanded(
                  flex: 1,
                  child: Row(
                    children: [
                      Checkbox(
                        value: moreQualityChecked.value,
                        onChanged: onMoreChanged,
                      ),
                      Expanded(child: Text(translateText('More'))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (showQuality && showMoreQuality && isMobile)
          Obx(
            () => Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Checkbox(
                      value: moreQualityChecked.value,
                      onChanged: onMoreChanged,
                    ),
                  ),
                ),
                Expanded(child: Text(translateText('More'))),
              ],
            ),
          ),
        if (showFps)
          Column(
            children: [
              Obx(
                () => Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Slider(
                        key: const Key('custom-image-fps-slider'),
                        value: fpsValue.value,
                        min: kMinFps,
                        max: kMaxFps,
                        divisions: ((kMaxFps - kMinFps) / 5).round(),
                        onChanged: setFps == null
                            ? null
                            : (double value) async {
                                fpsValue.value = value;
                                debouncerFps.value = value;
                              },
                      ),
                    ),
                    Expanded(
                      flex: 1,
                      child: Text(
                        '${fpsValue.value.round()}',
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        translateText(widget.fpsLabel),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
              if (showFpsMode)
                Obx(() {
                void selectFpsMode(String value) {
                  fpsModeValue.value = value;
                  setFpsMode?.call(value);
                }

                if (isMobile) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        translateText('FPS mode'),
                        style: const TextStyle(fontSize: 15),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          key: const Key('custom-image-fps-mode-segmented'),
                          expandedInsets: EdgeInsets.zero,
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: kCustomFpsModeAdaptive,
                              label: Text(
                                translateText('Adaptive FPS cap'),
                                maxLines: 2,
                                textAlign: TextAlign.center,
                              ),
                            ),
                            ButtonSegment(
                              value: kCustomFpsModeFixed,
                              label: Text(
                                translateText('Fixed FPS'),
                                maxLines: 2,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                          selected: {fpsModeValue.value},
                          onSelectionChanged: setFpsMode == null
                              ? null
                              : (values) => selectFpsMode(values.first),
                        ),
                      ),
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: Text(
                        translateText('FPS mode'),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: DropdownButton<String>(
                        key: const Key('custom-image-fps-mode-dropdown'),
                        value: fpsModeValue.value,
                        isExpanded: true,
                        onChanged: setFpsMode == null
                            ? null
                            : (value) {
                                if (value != null) {
                                  selectFpsMode(value);
                                }
                              },
                        items: [
                          DropdownMenuItem(
                            value: kCustomFpsModeAdaptive,
                            child: Text(translateText('Adaptive FPS cap')),
                          ),
                          DropdownMenuItem(
                            value: kCustomFpsModeFixed,
                            child: Text(translateText('Fixed FPS')),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
      ],
    );
  }
}

customImageQualitySetting() {
  final qualityKey = 'custom_image_quality';
  final fpsKey = kOptionCustomFps;
  final fpsModeKey = kOptionCustomFpsMode;

  final initQuality =
      (double.tryParse(bind.mainGetUserDefaultOption(key: qualityKey)) ??
      kDefaultQuality);
  final isQuanlityFixed = isOptionFixed(qualityKey);
  final initFps =
      (double.tryParse(bind.mainGetUserDefaultOption(key: fpsKey)) ??
      kDefaultFps);
  final isFpsFixed = isOptionFixed(fpsKey);
  final initFpsMode = bind.mainGetUserDefaultOption(key: fpsModeKey);
  final isFpsModeFixed = isOptionFixed(fpsModeKey);

  return customImageQualityWidget(
    initQuality: initQuality,
    initFps: initFps,
    initFpsMode: initFpsMode,
    setQuality: isQuanlityFixed
        ? null
        : (v) {
            bind.mainSetUserDefaultOption(key: qualityKey, value: v.toString());
          },
    setFps: isFpsFixed
        ? null
        : (v) {
            bind.mainSetUserDefaultOption(key: fpsKey, value: v.toString());
          },
    setFpsMode: isFpsModeFixed
        ? null
        : (v) {
            bind.mainSetUserDefaultOption(key: fpsModeKey, value: v);
          },
    showFps: true,
    showMoreQuality: true,
  );
}

List<Widget> ServerConfigImportExportWidgets(
  List<TextEditingController> controllers,
  List<RxString> errMsgs,
) {
  import() {
    Clipboard.getData(Clipboard.kTextPlain).then((value) {
      importConfig(controllers, errMsgs, value?.text);
    });
  }

  export() {
    final text = ServerConfig(
      idServer: controllers[0].text.trim(),
      relayServer: controllers[1].text.trim(),
      apiServer: controllers[2].text.trim(),
      key: controllers[3].text.trim(),
    ).encode();
    debugPrint("ServerConfig export: $text");
    Clipboard.setData(ClipboardData(text: text));
    showToast(translate('Export server configuration successfully'));
  }

  return [
    Tooltip(
      message: translate('Import server config'),
      child: IconButton(
        icon: Icon(Icons.paste, color: Colors.grey),
        onPressed: import,
      ),
    ),
    Tooltip(
      message: translate('Export Server Config'),
      child: IconButton(
        icon: Icon(Icons.copy, color: Colors.grey),
        onPressed: export,
      ),
    ),
  ];
}

List<(String, String)> otherDefaultSettings() {
  List<(String, String)> v = [
    ('View Mode', kOptionViewOnly),
    ('show_monitors_tip', kKeyShowMonitorsToolbar),
    if ((isDesktop || isWebDesktop))
      ('Collapse toolbar', kOptionCollapseToolbar),
    ('Show remote cursor', kOptionShowRemoteCursor),
    ('Follow remote cursor', kOptionFollowRemoteCursor),
    ('Follow remote window focus', kOptionFollowRemoteWindow),
    if ((isDesktop || isWebDesktop)) ('Zoom cursor', kOptionZoomCursor),
    ('Show quality monitor', kOptionShowQualityMonitor),
    ('Mute', kOptionDisableAudio),
    if (isDesktop) ('Enable file copy and paste', kOptionEnableFileCopyPaste),
    ('Disable clipboard', kOptionDisableClipboard),
    ('Lock after session end', kOptionLockAfterSessionEnd),
    ('Privacy mode', kOptionPrivacyMode),
    ('True color (4:4:4)', kOptionI444),
    ('Reverse mouse wheel', kKeyReverseMouseWheel),
    ('swap-left-right-mouse', kOptionSwapLeftRightMouse),
    if (isDesktop)
      (
        'Show displays as individual windows',
        kKeyShowDisplaysAsIndividualWindows,
      ),
    if (isDesktop)
      (
        'Use all my displays for the remote session',
        kKeyUseAllMyDisplaysForTheRemoteSession,
      ),
    ('Keep terminal sessions on disconnect', kOptionTerminalPersistent),
  ];

  return v;
}

class TrackpadSpeedWidget extends StatefulWidget {
  final SimpleWrapper<int> value;
  // If null, no debouncer will be applied.
  final Function(int)? onDebouncer;

  TrackpadSpeedWidget({Key? key, required this.value, this.onDebouncer});

  @override
  TrackpadSpeedWidgetState createState() => TrackpadSpeedWidgetState();
}

class TrackpadSpeedWidgetState extends State<TrackpadSpeedWidget> {
  final TextEditingController _controller = TextEditingController();
  late final Debouncer<int> debouncerSpeed;

  set value(int v) => widget.value.value = v;
  int get value => widget.value.value;

  void updateValue(int newValue) {
    setState(() {
      value = newValue.clamp(kMinTrackpadSpeed, kMaxTrackpadSpeed);
      // Scale the trackpad speed value to a percentage for display purposes.
      _controller.text = value.toString();
      if (widget.onDebouncer != null) {
        debouncerSpeed.setValue(value);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    debouncerSpeed = Debouncer<int>(
      Duration(milliseconds: 1000),
      onChanged: widget.onDebouncer,
      initialValue: widget.value.value,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.text.isEmpty) {
      _controller.text = value.toString();
    }
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Slider(
            value: value.toDouble(),
            min: kMinTrackpadSpeed.toDouble(),
            max: kMaxTrackpadSpeed.toDouble(),
            divisions: ((kMaxTrackpadSpeed - kMinTrackpadSpeed) / 10).round(),
            onChanged: (double v) => updateValue(v.round()),
          ),
        ),
        Expanded(
          flex: 1,
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: TextField(
                  controller: _controller,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  onSubmitted: (text) {
                    int? v = int.tryParse(text);
                    if (v != null) {
                      updateValue(v);
                    }
                  },
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 8.0,
                      horizontal: 12.0,
                    ),
                  ),
                ),
              ).marginOnly(right: 8.0),
              Text('%', style: const TextStyle(fontSize: 15)),
            ],
          ),
        ),
      ],
    );
  }
}
