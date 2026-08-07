import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class MobileCustomImageQualityControls extends StatefulWidget {
  const MobileCustomImageQualityControls({
    super.key,
    required this.peerId,
    required this.ffi,
  });

  final String peerId;
  final FFI ffi;

  @override
  State<MobileCustomImageQualityControls> createState() =>
      _MobileCustomImageQualityControlsState();
}

class _MobileCustomImageQualityControlsState
    extends State<MobileCustomImageQualityControls> {
  double _quality = kDefaultQuality;
  double _fps = kDefaultFps;
  String _fpsMode = kCustomFpsModeAdaptive;
  bool _showFps = true;
  bool _showMoreQuality = true;
  bool _loading = true;

  SessionID get _sessionId => widget.ffi.sessionId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      bool? direct;
      try {
        direct =
            ConnectionTypeState.find(widget.peerId).direct.value ==
            ConnectionType.strDirect;
      } catch (_) {}

      final usesPublicServer = await bind.mainIsUsingPublicServer();
      final restrictForRelay = usesPublicServer && direct != true;
      final peerVersion = widget.ffi.ffiModel.pi.version;
      final hideFps = restrictForRelay || versionCmp(peerVersion, '1.2.0') < 0;
      final hideMoreQuality =
          restrictForRelay || versionCmp(peerVersion, '1.2.2') < 0;

      final quality = await bind.sessionGetCustomImageQuality(
        sessionId: _sessionId,
      );
      var loadedQuality = quality != null && quality.isNotEmpty
          ? quality.first.toDouble()
          : kDefaultQuality;
      final maxQuality = hideMoreQuality ? kMaxQuality : kMaxMoreQuality;
      if (loadedQuality < kMinQuality || loadedQuality > maxQuality) {
        loadedQuality = kDefaultQuality;
      }

      final fpsOption = await bind.sessionGetOption(
        sessionId: _sessionId,
        arg: kOptionCustomFps,
      );
      var loadedFps = double.tryParse(fpsOption ?? '')?.abs() ?? kDefaultFps;
      if (loadedFps < kMinFps || loadedFps > kMaxFps) {
        loadedFps = kDefaultFps;
      }

      final fpsModeOption = await bind.sessionGetOption(
        sessionId: _sessionId,
        arg: kOptionCustomFpsMode,
      );
      final loadedFpsMode = fpsModeOption == kCustomFpsModeFixed
          ? kCustomFpsModeFixed
          : kCustomFpsModeAdaptive;

      if (!mounted) {
        return;
      }
      setState(() {
        _quality = loadedQuality;
        _fps = loadedFps;
        _fpsMode = loadedFpsMode;
        _showFps = !hideFps;
        _showMoreQuality = !hideMoreQuality;
        _loading = false;
      });
    } catch (error) {
      debugPrint('Failed to load mobile custom image quality: $error');
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  int _fpsForMode(double fps) {
    final value = fps.round();
    return _fpsMode == kCustomFpsModeFixed ? -value : value;
  }

  Future<void> _setQuality(double value) async {
    _quality = value;
    try {
      await bind.sessionSetCustomImageQuality(
        sessionId: _sessionId,
        value: value.round(),
      );
    } catch (error) {
      debugPrint('Failed to set mobile custom image quality: $error');
    }
  }

  Future<void> _setFps(double value) async {
    _fps = value;
    try {
      await bind.sessionSetCustomFps(
        sessionId: _sessionId,
        fps: _fpsForMode(value),
      );
    } catch (error) {
      debugPrint('Failed to set mobile custom FPS: $error');
    }
  }

  Future<void> _setFpsMode(String value) async {
    _fpsMode = value == kCustomFpsModeFixed
        ? kCustomFpsModeFixed
        : kCustomFpsModeAdaptive;
    try {
      await bind.sessionPeerOption(
        sessionId: _sessionId,
        name: kOptionCustomFpsMode,
        value: _fpsMode,
      );
      await bind.sessionSetCustomFps(
        sessionId: _sessionId,
        fps: _fpsForMode(_fps),
      );
    } catch (error) {
      debugPrint('Failed to set mobile custom FPS mode: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: customImageQualityWidget(
        initQuality: _quality,
        initFps: _fps,
        initFpsMode: _fpsMode,
        setQuality: _setQuality,
        setFps: _setFps,
        setFpsMode: _setFpsMode,
        showFps: _showFps,
        showMoreQuality: _showMoreQuality,
      ),
    );
  }
}
