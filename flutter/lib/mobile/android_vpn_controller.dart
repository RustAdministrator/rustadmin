import 'dart:async';

import 'package:flutter/foundation.dart';

import '../consts.dart';
import '../models/platform_model.dart';

abstract class AndroidVpnPlatformAdapter {
  Future<String> getPeerOption(String peerId, String key);
  Future<String> probePeer(String peerId);
  Future<dynamic> invoke(String method, [dynamic arguments]);
  Future<void> logDiagnostic(String message);
}

class _MethodChannelAndroidVpnPlatform implements AndroidVpnPlatformAdapter {
  @override
  Future<String> getPeerOption(String peerId, String key) {
    return bind.mainGetPeerOption(id: peerId, key: key);
  }

  @override
  Future<String> probePeer(String peerId) {
    return bind.mainProbePeerOnline(id: peerId, forceRefresh: true);
  }

  @override
  Future<dynamic> invoke(String method, [dynamic arguments]) {
    return platformFFI.invokeMethod(method, arguments);
  }

  @override
  Future<void> logDiagnostic(String message) {
    return bind.mainSetCommon(key: 'debug-probe-log', value: message);
  }
}

enum AndroidPeerAvailability {
  online,
  offline,
  unknown;

  static AndroidPeerAvailability fromWire(String value) {
    switch (value) {
      case 'online':
        return AndroidPeerAvailability.online;
      case 'offline':
        return AndroidPeerAvailability.offline;
      default:
        return AndroidPeerAvailability.unknown;
    }
  }
}

enum AndroidVpnPreconnectAction { connectWithoutVpnChange, startWireGuard }

AndroidVpnPreconnectAction decideAndroidVpnPreconnectAction({
  required AndroidPeerAvailability availability,
  required bool vpnActive,
  required bool localWifiPath,
}) {
  if (availability != AndroidPeerAvailability.offline ||
      vpnActive ||
      localWifiPath) {
    return AndroidVpnPreconnectAction.connectWithoutVpnChange;
  }
  return AndroidVpnPreconnectAction.startWireGuard;
}

class AndroidVpnPrepareResult {
  final bool proceed;
  final String message;

  const AndroidVpnPrepareResult._(this.proceed, this.message);

  const AndroidVpnPrepareResult.proceed() : this._(true, '');

  const AndroidVpnPrepareResult.stop(String message) : this._(false, message);
}

class AndroidOutgoingSessionClosedEvent {
  final String sessionId;
  final String reason;
  final int generation;

  const AndroidOutgoingSessionClosedEvent({
    required this.sessionId,
    required this.reason,
    required this.generation,
  });
}

class _AndroidNetworkSnapshot {
  final bool vpnActive;
  final bool nonVpnWifiActive;
  final bool localWifiPath;

  const _AndroidNetworkSnapshot({
    required this.vpnActive,
    required this.nonVpnWifiActive,
    required this.localWifiPath,
  });

  factory _AndroidNetworkSnapshot.fromDynamic(dynamic value) {
    if (value is! Map) {
      return const _AndroidNetworkSnapshot(
        vpnActive: false,
        nonVpnWifiActive: false,
        localWifiPath: false,
      );
    }
    return _AndroidNetworkSnapshot(
      vpnActive: value['vpn_active'] == true,
      nonVpnWifiActive: value['non_vpn_wifi_active'] == true,
      localWifiPath: value['local_wifi_path'] == true,
    );
  }
}

class _PendingVpnLease {
  final String peerId;
  final String tunnelName;
  final bool ownsTunnel;
  Timer? expiry;

  _PendingVpnLease({
    required this.peerId,
    required this.tunnelName,
    required this.ownsTunnel,
  });
}

class AndroidVpnSessionCoordinator {
  AndroidVpnSessionCoordinator._({
    AndroidVpnPlatformAdapter? platform,
    this._vpnActivationTimeout = const Duration(seconds: 12),
    this._vpnRetryDelay = const Duration(seconds: 2),
    this._networkPollInterval = const Duration(milliseconds: 250),
    this._routeSettleDelay = const Duration(milliseconds: 500),
    this._peerReachabilityTimeout = const Duration(seconds: 12),
    this._probeInterval = const Duration(milliseconds: 400),
    this._pendingLeaseTimeout = const Duration(seconds: 30),
  }) : _platform = platform ?? _MethodChannelAndroidVpnPlatform(),
       assert(_vpnActivationTimeout > Duration.zero),
       assert(_vpnRetryDelay >= Duration.zero),
       assert(_networkPollInterval > Duration.zero),
       assert(_routeSettleDelay >= Duration.zero),
       assert(_peerReachabilityTimeout > Duration.zero),
       assert(_probeInterval > Duration.zero),
       assert(_pendingLeaseTimeout > Duration.zero);

  static final instance = AndroidVpnSessionCoordinator._();

  @visibleForTesting
  factory AndroidVpnSessionCoordinator.forTest({
    required AndroidVpnPlatformAdapter platform,
    required Duration vpnActivationTimeout,
    required Duration vpnRetryDelay,
    required Duration networkPollInterval,
    required Duration peerReachabilityTimeout,
    required Duration probeInterval,
    Duration routeSettleDelay = Duration.zero,
    Duration pendingLeaseTimeout = const Duration(seconds: 1),
  }) {
    return AndroidVpnSessionCoordinator._(
      platform: platform,
      vpnActivationTimeout: vpnActivationTimeout,
      vpnRetryDelay: vpnRetryDelay,
      networkPollInterval: networkPollInterval,
      routeSettleDelay: routeSettleDelay,
      peerReachabilityTimeout: peerReachabilityTimeout,
      probeInterval: probeInterval,
      pendingLeaseTimeout: pendingLeaseTimeout,
    );
  }

  final Duration _vpnActivationTimeout;
  final Duration _vpnRetryDelay;
  final Duration _networkPollInterval;
  final Duration _routeSettleDelay;
  final Duration _peerReachabilityTimeout;
  final Duration _probeInterval;
  final Duration _pendingLeaseTimeout;
  final AndroidVpnPlatformAdapter _platform;

  final Map<String, _PendingVpnLease> _pendingLeases = {};
  final StreamController<AndroidOutgoingSessionClosedEvent>
  _sessionClosedController =
      StreamController<AndroidOutgoingSessionClosedEvent>.broadcast();
  bool _preparing = false;
  int _nextSessionGeneration = 0;
  int? _activeSessionGeneration;
  String _activeSessionId = '';
  (String, int)? _releasedSession;
  int? _notifiedCloseGeneration;

  Stream<AndroidOutgoingSessionClosedEvent> get sessionClosedEvents =>
      _sessionClosedController.stream;
  int? get activeSessionGeneration => _activeSessionGeneration;

  Future<bool> isEnabled(String peerId) async {
    return await _platform.getPeerOption(peerId, kOptionAndroidVpnPreconnect) ==
        'Y';
  }

  Future<AndroidVpnPrepareResult> prepare(String peerId) async {
    final enabled = await isEnabled(peerId);
    if (!enabled) return const AndroidVpnPrepareResult.proceed();
    if (_pendingLeases.containsKey(peerId)) {
      return const AndroidVpnPrepareResult.proceed();
    }
    if (_preparing) {
      return const AndroidVpnPrepareResult.stop(
        'Another VPN connection check is already running',
      );
    }

    _preparing = true;
    var tunnelName = '';
    var upRequested = false;
    try {
      _log('Android VPN preconnect started: peer=$peerId');
      tunnelName = (await _platform.getPeerOption(
        peerId,
        kOptionAndroidWireGuardTunnel,
      )).trim();
      if (tunnelName.isEmpty) {
        return const AndroidVpnPrepareResult.stop(
          'WireGuard tunnel name is not configured',
        );
      }

      final availability = await _probe(peerId);
      final network = await _networkSnapshot(peerId);
      final action = decideAndroidVpnPreconnectAction(
        availability: availability,
        vpnActive: network.vpnActive,
        localWifiPath: network.localWifiPath,
      );
      _log(
        'Android VPN preconnect decision: peer=$peerId, availability=${availability.name}, vpn=${network.vpnActive}, wifi=${network.nonVpnWifiActive}, localWifiPath=${network.localWifiPath}, action=${action.name}',
      );
      if (action == AndroidVpnPreconnectAction.connectWithoutVpnChange) {
        return const AndroidVpnPrepareResult.proceed();
      }

      final integration = await _platform.invoke('wireguard_status');
      if (integration is! Map || integration['installed'] != true) {
        return const AndroidVpnPrepareResult.stop('WireGuard is not installed');
      }
      var permissionGranted = integration['permission_granted'] == true;
      if (!permissionGranted) {
        permissionGranted =
            await _platform.invoke('wireguard_request_control_permission') ==
            true;
      }
      if (!permissionGranted) {
        return const AndroidVpnPrepareResult.stop(
          'WireGuard control permission was not granted',
        );
      }

      final beforeStart = await _networkSnapshot(peerId);
      if (beforeStart.vpnActive) {
        _log(
          'Android VPN preconnect skipped start because a VPN became active while permission was requested: peer=$peerId',
        );
        return const AndroidVpnPrepareResult.proceed();
      }

      final requestSent = await _setWireGuardTunnel(tunnelName, true);
      if (!requestSent) {
        return const AndroidVpnPrepareResult.stop(
          'Failed to request WireGuard tunnel start',
        );
      }
      upRequested = true;
      _log('Android VPN preconnect WireGuard start requested: peer=$peerId');

      if (!await _awaitVpnActivation(peerId, tunnelName)) {
        await _stopFailedPreconnect(
          peerId,
          tunnelName,
          'vpn-activation-timeout',
        );
        return const AndroidVpnPrepareResult.stop(
          'WireGuard tunnel did not become active. Check the tunnel name and Allow remote control apps in WireGuard',
        );
      }
      if (_routeSettleDelay > Duration.zero) {
        await Future<void>.delayed(_routeSettleDelay);
      }

      final peerStopwatch = Stopwatch()..start();
      while (peerStopwatch.elapsed < _peerReachabilityTimeout) {
        final availability = await _probe(peerId);
        if (availability == AndroidPeerAvailability.online) {
          await _replacePendingLease(
            _PendingVpnLease(
              peerId: peerId,
              tunnelName: tunnelName,
              ownsTunnel: true,
            ),
          );
          _log('Android VPN preconnect peer became reachable: peer=$peerId');
          return const AndroidVpnPrepareResult.proceed();
        }
        await Future<void>.delayed(_probeInterval);
      }

      await _stopFailedPreconnect(
        peerId,
        tunnelName,
        'peer-reachability-timeout',
      );
      return const AndroidVpnPrepareResult.stop(
        'WireGuard is active but did not make the peer reachable. Check the peer address and tunnel routes',
      );
    } catch (error, stackTrace) {
      if (upRequested && tunnelName.isNotEmpty) {
        try {
          await _setWireGuardTunnel(tunnelName, false);
          _log(
            'Android VPN preconnect compensated failed WireGuard start: peer=$peerId',
          );
        } catch (cleanupError, cleanupStackTrace) {
          _log(
            'Android VPN preconnect cleanup failed: peer=$peerId, error=$cleanupError\n$cleanupStackTrace',
          );
        }
      }
      _log(
        'Android VPN preconnect failed: peer=$peerId, error=$error\n$stackTrace',
      );
      return const AndroidVpnPrepareResult.stop(
        'VPN connection preparation failed',
      );
    } finally {
      _preparing = false;
    }
  }

  Future<bool> attach(String peerId, String sessionId) async {
    final lease = _pendingLeases.remove(peerId);
    lease?.expiry?.cancel();
    final generation = ++_nextSessionGeneration;
    _releasedSession = null;
    final attached =
        await _platform.invoke('outgoing_session_attach', {
          'session_id': sessionId,
          'generation': generation,
          'tunnel': lease?.tunnelName ?? '',
          'owns_tunnel': lease?.ownsTunnel == true,
        }) ==
        true;
    if (!attached && lease?.ownsTunnel == true) {
      await _setWireGuardTunnel(lease!.tunnelName, false);
    }
    if (attached) {
      _activeSessionId = sessionId;
      _activeSessionGeneration = generation;
    }
    _log(
      'Android outgoing session lease attached: peer=$peerId, session=$sessionId, generation=$generation, ownsVpn=${lease?.ownsTunnel == true}, attached=$attached',
    );
    return attached;
  }

  Future<void> release({required int? generation}) async {
    if (generation == null || generation != _activeSessionGeneration) {
      _log(
        'Ignored stale Android outgoing session release: generation=$generation, activeGeneration=$_activeSessionGeneration',
      );
      return;
    }
    final sessionId = _activeSessionId;
    await _platform.invoke('outgoing_session_release', {
      'session_id': sessionId,
      'generation': generation,
    });
    if (_activeSessionId == sessionId &&
        _activeSessionGeneration == generation) {
      // The native service reports a background timeout after its drain delay,
      // which may outlive the Rust event stream and this lease release.
      if (generation == _nextSessionGeneration) {
        _releasedSession = (sessionId, generation);
      }
      _activeSessionId = '';
      _activeSessionGeneration = null;
    }
  }

  bool handleNativeSessionClosed(dynamic arguments) {
    if (arguments is! Map) return false;
    final sessionId = arguments['session_id']?.toString() ?? '';
    final reason = arguments['reason']?.toString() ?? '';
    final generation = switch (arguments['generation']) {
      int value => value,
      String value => int.tryParse(value) ?? -1,
      _ => -1,
    };
    final matchesActive =
        sessionId == _activeSessionId && generation == _activeSessionGeneration;
    final matchesReleased =
        _activeSessionGeneration == null &&
        _releasedSession == (sessionId, generation);
    if (generation != _nextSessionGeneration ||
        generation == _notifiedCloseGeneration ||
        (!matchesActive && !matchesReleased)) {
      _log(
        'Ignored stale Android outgoing session close: session=$sessionId, generation=$generation, activeSession=$_activeSessionId, activeGeneration=$_activeSessionGeneration',
      );
      return false;
    }
    _releasedSession = null;
    _notifiedCloseGeneration = generation;
    _sessionClosedController.add(
      AndroidOutgoingSessionClosedEvent(
        sessionId: sessionId,
        reason: reason,
        generation: generation,
      ),
    );
    return true;
  }

  Future<AndroidPeerAvailability> _probe(String peerId) async {
    final value = await _platform.probePeer(peerId);
    return AndroidPeerAvailability.fromWire(value);
  }

  Future<_AndroidNetworkSnapshot> _networkSnapshot(String peerId) async {
    final value = await _platform.invoke('vpn_network_snapshot', {
      'peer': peerId,
    });
    return _AndroidNetworkSnapshot.fromDynamic(value);
  }

  Future<bool> _setWireGuardTunnel(String tunnelName, bool up) async {
    return await _platform.invoke('wireguard_set_tunnel', {
          'tunnel': tunnelName,
          'up': up,
        }) ==
        true;
  }

  Future<bool> _awaitVpnActivation(String peerId, String tunnelName) async {
    final stopwatch = Stopwatch()..start();
    var retrySent = false;
    while (stopwatch.elapsed < _vpnActivationTimeout) {
      await Future<void>.delayed(_networkPollInterval);
      final network = await _networkSnapshot(peerId);
      if (network.vpnActive) {
        _log(
          'Android VPN preconnect VPN became active: peer=$peerId, elapsedMs=${stopwatch.elapsedMilliseconds}, retrySent=$retrySent',
        );
        return true;
      }
      if (!retrySent && stopwatch.elapsed >= _vpnRetryDelay) {
        retrySent = true;
        final sent = await _setWireGuardTunnel(tunnelName, true);
        _log(
          'Android VPN preconnect WireGuard cold-start retry: peer=$peerId, sent=$sent, elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
        if (!sent) {
          throw StateError('Failed to retry WireGuard tunnel start');
        }
      }
    }
    _log(
      'Android VPN preconnect VPN activation timed out: peer=$peerId, elapsedMs=${stopwatch.elapsedMilliseconds}, retrySent=$retrySent',
    );
    return false;
  }

  Future<void> _stopFailedPreconnect(
    String peerId,
    String tunnelName,
    String reason,
  ) async {
    final sent = await _setWireGuardTunnel(tunnelName, false);
    _log(
      'Android VPN preconnect compensating DOWN: peer=$peerId, reason=$reason, sent=$sent',
    );
  }

  Future<void> _replacePendingLease(_PendingVpnLease lease) async {
    final previous = _pendingLeases.remove(lease.peerId);
    previous?.expiry?.cancel();
    if (previous?.ownsTunnel == true &&
        previous?.tunnelName != lease.tunnelName) {
      await _setWireGuardTunnel(previous!.tunnelName, false);
    }
    _pendingLeases[lease.peerId] = lease;
    lease.expiry = Timer(_pendingLeaseTimeout, () {
      final expired = _pendingLeases.remove(lease.peerId);
      if (expired?.ownsTunnel == true) {
        unawaited(_setWireGuardTunnel(expired!.tunnelName, false));
      }
    });
  }

  void _log(String message) {
    debugPrint(message);
    unawaited(_platform.logDiagnostic(message));
  }
}
