import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../utils/multi_window_manager.dart';

const _qualityMonitorSnapshotLimit = 64 * 1024;
const _qualityMonitorValueLimit = 1024;

Map<String, String> qualityMonitorDataToWindowJson(QualityMonitorData data) {
  final values = <String, String?>{
    'speed': data.speed,
    'fps': data.fps,
    'delay': data.delay,
    'targetBitrate': data.targetBitrate,
    'codecFormat': data.codecFormat,
    'chroma': data.chroma,
    'connectionType': data.connectionType,
    'transportMtu': data.transportMtu,
    'transportRttMs': data.transportRttMs,
    'transportLostPackets': data.transportLostPackets,
    'datagramPayload': data.datagramPayload,
    'negotiatedDatagramPayload': data.negotiatedDatagramPayload,
    'quicProtocol': data.quicProtocol,
    'quicVideoTransport': data.quicVideoTransport,
    'quicReassemblyDrops': data.quicReassemblyDrops,
    'quicReassemblyReasons': data.quicReassemblyReasons,
    'quicReassemblyFrame': data.quicReassemblyFrame,
    'quicReassemblyTiming': data.quicReassemblyTiming,
    'quicKeyframeRequests': data.quicKeyframeRequests,
    'quicKeyframeBarrier': data.quicKeyframeBarrier,
    'quicReceiverRecovery': data.quicReceiverRecovery,
    'quicSenderRecovery': data.quicSenderRecovery,
    'quicSenderAdmission': data.quicSenderAdmission,
    'quicSenderFrame': data.quicSenderFrame,
    'quicSenderPercentiles': data.quicSenderPercentiles,
    'quicSenderSpace': data.quicSenderSpace,
    'quicDisposableDrops': data.quicDisposableDrops,
    'quicVideoQueueTargetMs': data.quicVideoQueueTargetMs,
    'hostVersion': data.hostVersion,
    'clientVersion': data.clientVersion,
    'decoder': data.decoder,
    'renderer': data.renderer,
    'captureBackend': data.captureBackend,
    'captureFrame': data.captureFrame,
    'encoderBackend': data.encoderBackend,
    'encoderInput': data.encoderInput,
    'frameResolution': data.frameResolution,
    'decodeFps': data.decodeFps,
    'videoQueue': data.videoQueue,
    'videoThreads': data.videoThreads,
    'textureRender': data.textureRender,
    'direct': data.direct,
    'fpsMode': data.fpsMode,
    'autoFps': data.autoFps,
    'videoProgress': data.videoProgress,
    'videoDropped': data.videoDropped,
    'videoDecodeTimeUs': data.videoDecodeTimeUs,
    'videoRenderSubmitTimeUs': data.videoRenderSubmitTimeUs,
    'videoFeedbackQueue': data.videoFeedbackQueue,
    'displayRefresh': data.displayRefresh,
    'videoDeliveryPhase': data.videoDeliveryPhase,
    'videoRecoveryCount': data.videoRecoveryCount,
    'videoStallMs': data.videoStallMs,
    'requestedVideoProfile': data.requestedVideoProfile,
    'effectiveVideoProfile': data.effectiveVideoProfile,
    'movieTargetFps': data.movieTargetFps,
    'moviePacingFps': data.moviePacingFps,
    'movieHostPipelineP95Us': data.movieHostPipelineP95Us,
    'movieFallbackReason': data.movieFallbackReason,
    'moviePlayoutDelayMs': data.moviePlayoutDelayMs,
  };
  return {
    for (final entry in values.entries)
      if (entry.value != null)
        entry.key: entry.value!.length <= _qualityMonitorValueLimit
            ? entry.value!
            : entry.value!.substring(0, _qualityMonitorValueLimit),
  };
}

QualityMonitorData qualityMonitorDataFromWindowJson(
    Map<String, dynamic> json) {
  String? value(String key) {
    final raw = json[key];
    if (raw is! String || raw.isEmpty) return null;
    return raw.length <= _qualityMonitorValueLimit
        ? raw
        : raw.substring(0, _qualityMonitorValueLimit);
  }

  return QualityMonitorData()
    ..speed = value('speed')
    ..fps = value('fps')
    ..delay = value('delay')
    ..targetBitrate = value('targetBitrate')
    ..codecFormat = value('codecFormat')
    ..chroma = value('chroma')
    ..connectionType = value('connectionType')
    ..transportMtu = value('transportMtu')
    ..transportRttMs = value('transportRttMs')
    ..transportLostPackets = value('transportLostPackets')
    ..datagramPayload = value('datagramPayload')
    ..negotiatedDatagramPayload = value('negotiatedDatagramPayload')
    ..quicProtocol = value('quicProtocol')
    ..quicVideoTransport = value('quicVideoTransport')
    ..quicReassemblyDrops = value('quicReassemblyDrops')
    ..quicReassemblyReasons = value('quicReassemblyReasons')
    ..quicReassemblyFrame = value('quicReassemblyFrame')
    ..quicReassemblyTiming = value('quicReassemblyTiming')
    ..quicKeyframeRequests = value('quicKeyframeRequests')
    ..quicKeyframeBarrier = value('quicKeyframeBarrier')
    ..quicReceiverRecovery = value('quicReceiverRecovery')
    ..quicSenderRecovery = value('quicSenderRecovery')
    ..quicSenderAdmission = value('quicSenderAdmission')
    ..quicSenderFrame = value('quicSenderFrame')
    ..quicSenderPercentiles = value('quicSenderPercentiles')
    ..quicSenderSpace = value('quicSenderSpace')
    ..quicDisposableDrops = value('quicDisposableDrops')
    ..quicVideoQueueTargetMs = value('quicVideoQueueTargetMs')
    ..hostVersion = value('hostVersion')
    ..clientVersion = value('clientVersion')
    ..decoder = value('decoder')
    ..renderer = value('renderer')
    ..captureBackend = value('captureBackend')
    ..captureFrame = value('captureFrame')
    ..encoderBackend = value('encoderBackend')
    ..encoderInput = value('encoderInput')
    ..frameResolution = value('frameResolution')
    ..decodeFps = value('decodeFps')
    ..videoQueue = value('videoQueue')
    ..videoThreads = value('videoThreads')
    ..textureRender = value('textureRender')
    ..direct = value('direct')
    ..fpsMode = value('fpsMode')
    ..autoFps = value('autoFps')
    ..videoProgress = value('videoProgress')
    ..videoDropped = value('videoDropped')
    ..videoDecodeTimeUs = value('videoDecodeTimeUs')
    ..videoRenderSubmitTimeUs = value('videoRenderSubmitTimeUs')
    ..videoFeedbackQueue = value('videoFeedbackQueue')
    ..displayRefresh = value('displayRefresh')
    ..videoDeliveryPhase = value('videoDeliveryPhase')
    ..videoRecoveryCount = value('videoRecoveryCount')
    ..videoStallMs = value('videoStallMs')
    ..requestedVideoProfile = value('requestedVideoProfile')
    ..effectiveVideoProfile = value('effectiveVideoProfile')
    ..movieTargetFps = value('movieTargetFps')
    ..moviePacingFps = value('moviePacingFps')
    ..movieHostPipelineP95Us = value('movieHostPipelineP95Us')
    ..movieFallbackReason = value('movieFallbackReason')
    ..moviePlayoutDelayMs = value('moviePlayoutDelayMs');
}

class DesktopQualityMonitorWindowController {
  DesktopQualityMonitorWindowController({
    required this.model,
    required this.peerId,
    required this.sessionId,
    required this.sourceWindowId,
  });

  final QualityMonitorModel model;
  final String peerId;
  final String sessionId;
  final int sourceWindowId;

  int? _windowId;
  Timer? _syncTimer;
  bool _creating = false;
  bool _disposed = false;
  bool _closedByUser = false;

  void start() {
    model.addListener(_scheduleSync);
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_disposed || _syncTimer != null) return;
    _syncTimer = Timer(const Duration(milliseconds: 200), () {
      _syncTimer = null;
      unawaited(_sync());
    });
  }

  Map<String, dynamic> _snapshot() => {
        'sessionId': sessionId,
        'peerId': peerId,
        'details': model.details,
        'data': qualityMonitorDataToWindowJson(model.data),
  };

  Future<void> _sync() async {
    if (_disposed) return;
    final active =
        model.show && model.position == kQualityMonitorPositionDetached;
    if (!active) {
      _closedByUser = false;
      await _closeWindow();
      return;
    }
    if (_windowId == null) {
      if (!_closedByUser) await _createWindow();
      return;
    }

    final encoded = jsonEncode(_snapshot());
    if (encoded.length > _qualityMonitorSnapshotLimit) return;
    try {
      await DesktopMultiWindow.invokeMethod(
        _windowId!,
        kWindowEventQualityMonitorSnapshot,
        encoded,
      );
    } catch (error) {
      debugPrint('Quality Monitor window update failed: $error');
      _windowId = null;
      _closedByUser = true;
    }
  }

  Future<void> _createWindow() async {
    if (_creating || _disposed) return;
    _creating = true;
    try {
      final params = {
        'type': WindowType.QualityMonitor.index,
        'sourceWindowId': sourceWindowId,
        ..._snapshot(),
      };
      final controller = await DesktopMultiWindow.createWindow(
        jsonEncode(params),
      );
      if (_disposed) {
        await controller.close();
        return;
      }
      _windowId = controller.windowId;
      if (isWindows) {
        await controller.setInitBackgroundColor(MyTheme.canvasColor);
      }
      await controller.showTitleBar(true);
      final initialHeight = model.extendedDetails ? 760.0 : 300.0;
      await controller.setFrame(Offset.zero & Size(380, initialHeight));
      await controller.center();
      await controller.setTitle('${translate('Quality monitor')} - $peerId');
      await controller.show();
    } catch (error) {
      debugPrint('Quality Monitor window creation failed: $error');
      _windowId = null;
    } finally {
      _creating = false;
    }
  }

  Future<void> _closeWindow() async {
    final windowId = _windowId;
    _windowId = null;
    if (windowId == null) return;
    try {
      await WindowController.fromWindowId(windowId).close();
    } catch (error) {
      debugPrint('Quality Monitor window close failed: $error');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    model.removeListener(_scheduleSync);
    _syncTimer?.cancel();
    _syncTimer = null;
    await _closeWindow();
  }
}

class DesktopQualityMonitorWindow extends StatefulWidget {
  const DesktopQualityMonitorWindow({super.key, required this.params});

  final Map<String, dynamic> params;

  @override
  State<DesktopQualityMonitorWindow> createState() =>
      _DesktopQualityMonitorWindowState();
}

class _DesktopQualityMonitorWindowState
    extends State<DesktopQualityMonitorWindow> {
  final _model = QualityMonitorModel.detached();
  final _contentKey = GlobalKey();
  final _scrollController = ScrollController();
  bool _fitScheduled = false;
  late final int _windowId = widget.params['windowId'] as int? ?? -1;
  late final int _sourceWindowId =
      widget.params['sourceWindowId'] as int? ?? kMainWindowId;

  @override
  void initState() {
    super.initState();
    _applySnapshot(widget.params);
    _model.addListener(_scheduleFit);
    DesktopMultiWindow.setMethodHandler(_handleMethodCall);
    _scheduleFit();
  }

  Future<dynamic> _handleMethodCall(MethodCall call, int fromWindowId) async {
    if (fromWindowId != _sourceWindowId ||
        call.method != kWindowEventQualityMonitorSnapshot) {
      return false;
    }
    final raw = call.arguments;
    if (raw is! String || raw.length > _qualityMonitorSnapshotLimit) {
      return false;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      _applySnapshot(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _applySnapshot(Map<String, dynamic> snapshot) {
    final sessionId = snapshot['sessionId'];
    if (sessionId is! String ||
        sessionId != widget.params['sessionId']?.toString()) {
      return;
    }
    final details = snapshot['details'];
    final data = snapshot['data'];
    if (details is! String || data is! Map) return;
    _model.applyDetachedSnapshot(
      details: details,
      data: qualityMonitorDataFromWindowJson(
        data.map((key, value) => MapEntry(key.toString(), value)),
      ),
    );
  }

  void _scheduleFit() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      unawaited(_fitWindowToContent());
    });
  }

  Future<void> _fitWindowToContent() async {
    if (!mounted || _windowId < 0) return;
    final renderObject = _contentKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final contentSize = renderObject.size;
    final desired = Size(
      (contentSize.width + 24).clamp(304.0, 400.0).toDouble(),
      (contentSize.height + 24).clamp(180.0, 860.0).toDouble(),
    );
    final controller = WindowController.fromWindowId(_windowId);
    try {
      final frame = await controller.getFrame();
      if ((frame.width - desired.width).abs() < 1 &&
          (frame.height - desired.height).abs() < 1) {
        return;
      }
      await controller.setFrame(frame.topLeft & desired);
    } catch (error) {
      debugPrint('Quality Monitor window resize failed: $error');
    }
  }

  @override
  void dispose() {
    DesktopMultiWindow.setMethodHandler(null);
    _model.removeListener(_scheduleFit);
    _model.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MyTheme.canvasColor,
      body: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(8),
          child: RepaintBoundary(
            key: _contentKey,
            child: QualityMonitor(
              _model,
              opaque: true,
              fitContent: true,
              showHeader: false,
            ),
          ),
        ),
      ),
    );
  }
}
