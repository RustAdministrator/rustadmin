import 'package:flutter_hbb/mobile/android_vpn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAndroidVpnPlatform implements AndroidVpnPlatformAdapter {
  final List<Object> probes;
  final List<bool> vpnStates;
  final List<bool> tunnelRequests = [];
  Map<dynamic, dynamic>? attached;
  bool _vpnActive = false;
  int peerProbeCount = 0;

  _FakeAndroidVpnPlatform(this.probes, {List<bool> vpnStates = const []})
    : vpnStates = List<bool>.from(vpnStates);

  @override
  Future<String> getPeerOption(String peerId, String key) async {
    if (key == 'android-vpn-preconnect') return 'Y';
    if (key == 'android-wireguard-tunnel') return 'office';
    return '';
  }

  @override
  Future<dynamic> invoke(String method, [dynamic arguments]) async {
    switch (method) {
      case 'vpn_network_snapshot':
        if (vpnStates.isNotEmpty) {
          _vpnActive = vpnStates.removeAt(0);
        }
        return {
          'vpn_active': _vpnActive,
          'non_vpn_wifi_active': false,
          'local_wifi_path': false,
        };
      case 'wireguard_status':
        return {'installed': true, 'permission_granted': true};
      case 'wireguard_set_tunnel':
        tunnelRequests.add((arguments as Map)['up'] == true);
        return true;
      case 'outgoing_session_attach':
        attached = Map<dynamic, dynamic>.from(arguments as Map);
        return true;
    }
    return null;
  }

  @override
  Future<void> logDiagnostic(String message) async {}

  @override
  Future<String> probePeer(String peerId) async {
    peerProbeCount += 1;
    if (probes.isEmpty) return 'offline';
    final result = probes.removeAt(0);
    if (result is Error) throw result;
    if (result is Exception) throw result;
    return result as String;
  }
}

void main() {
  test(
    'starts WireGuard only for confirmed offline peer without Wi-Fi or VPN',
    () {
      expect(
        decideAndroidVpnPreconnectAction(
          availability: AndroidPeerAvailability.offline,
          vpnActive: false,
          localWifiPath: false,
        ),
        AndroidVpnPreconnectAction.startWireGuard,
      );
    },
  );

  test('never changes an existing VPN', () {
    expect(
      decideAndroidVpnPreconnectAction(
        availability: AndroidPeerAvailability.offline,
        vpnActive: true,
        localWifiPath: false,
      ),
      AndroidVpnPreconnectAction.connectWithoutVpnChange,
    );
  });

  test('does not auto-start VPN for an on-link local Wi-Fi peer', () {
    expect(
      decideAndroidVpnPreconnectAction(
        availability: AndroidPeerAvailability.offline,
        vpnActive: false,
        localWifiPath: true,
      ),
      AndroidVpnPreconnectAction.connectWithoutVpnChange,
    );
  });

  test('public Wi-Fi without a local peer route does not block VPN', () {
    expect(
      decideAndroidVpnPreconnectAction(
        availability: AndroidPeerAvailability.offline,
        vpnActive: false,
        localWifiPath: false,
      ),
      AndroidVpnPreconnectAction.startWireGuard,
    );
  });

  test('online and unknown peer states never trigger VPN', () {
    for (final availability in [
      AndroidPeerAvailability.online,
      AndroidPeerAvailability.unknown,
    ]) {
      expect(
        decideAndroidVpnPreconnectAction(
          availability: availability,
          vpnActive: false,
          localWifiPath: false,
        ),
        AndroidVpnPreconnectAction.connectWithoutVpnChange,
      );
    }
  });

  test(
    'does not claim a VPN that became active during permission flow',
    () async {
      final platform = _FakeAndroidVpnPlatform(
        ['offline'],
        vpnStates: [false, true],
      );
      final coordinator = AndroidVpnSessionCoordinator.forTest(
        platform: platform,
        vpnActivationTimeout: const Duration(milliseconds: 100),
        vpnRetryDelay: const Duration(milliseconds: 10),
        networkPollInterval: const Duration(milliseconds: 1),
        peerReachabilityTimeout: const Duration(milliseconds: 100),
        probeInterval: const Duration(milliseconds: 1),
      );

      final result = await coordinator.prepare('10.0.0.2');

      expect(result.proceed, isTrue);
      expect(platform.tunnelRequests, isEmpty);
    },
  );

  test(
    'VPN activation timeout retries UP once and compensates with DOWN',
    () async {
      final platform = _FakeAndroidVpnPlatform(['offline']);
      final coordinator = AndroidVpnSessionCoordinator.forTest(
        platform: platform,
        vpnActivationTimeout: const Duration(milliseconds: 8),
        vpnRetryDelay: Duration.zero,
        networkPollInterval: const Duration(milliseconds: 1),
        peerReachabilityTimeout: const Duration(milliseconds: 8),
        probeInterval: const Duration(milliseconds: 1),
      );

      final result = await coordinator.prepare('10.0.0.2');

      expect(result.proceed, isFalse);
      expect(platform.tunnelRequests, [true, true, false]);
      expect(platform.peerProbeCount, 1);
    },
  );

  test('probe exception after WireGuard UP is compensated with DOWN', () async {
    final platform = _FakeAndroidVpnPlatform(
      ['offline', StateError('probe failed')],
      vpnStates: [false, false, true],
    );
    final coordinator = AndroidVpnSessionCoordinator.forTest(
      platform: platform,
      vpnActivationTimeout: const Duration(milliseconds: 100),
      vpnRetryDelay: const Duration(milliseconds: 50),
      networkPollInterval: const Duration(milliseconds: 1),
      peerReachabilityTimeout: const Duration(milliseconds: 100),
      probeInterval: const Duration(milliseconds: 1),
    );

    final result = await coordinator.prepare('10.0.0.2');

    expect(result.proceed, isFalse);
    expect(platform.tunnelRequests, [true, false]);
  });

  test('cold WireGuard start retries before probing the peer', () async {
    final platform = _FakeAndroidVpnPlatform(
      ['offline', 'online'],
      vpnStates: [false, false, false, true],
    );
    final coordinator = AndroidVpnSessionCoordinator.forTest(
      platform: platform,
      vpnActivationTimeout: const Duration(milliseconds: 100),
      vpnRetryDelay: Duration.zero,
      networkPollInterval: const Duration(milliseconds: 1),
      peerReachabilityTimeout: const Duration(milliseconds: 100),
      probeInterval: const Duration(milliseconds: 1),
    );

    final result = await coordinator.prepare('10.0.0.2');

    expect(result.proceed, isTrue);
    expect(platform.tunnelRequests, [true, true]);
    expect(platform.peerProbeCount, 2);
  });

  test(
    'active VPN with unreachable peer is stopped with a distinct timeout',
    () async {
      final platform = _FakeAndroidVpnPlatform(
        ['offline'],
        vpnStates: [false, false, true],
      );
      final coordinator = AndroidVpnSessionCoordinator.forTest(
        platform: platform,
        vpnActivationTimeout: const Duration(milliseconds: 100),
        vpnRetryDelay: const Duration(milliseconds: 50),
        networkPollInterval: const Duration(milliseconds: 1),
        peerReachabilityTimeout: const Duration(milliseconds: 8),
        probeInterval: const Duration(milliseconds: 1),
      );

      final result = await coordinator.prepare('10.0.0.2');

      expect(result.proceed, isFalse);
      expect(result.message, contains('WireGuard is active'));
      expect(platform.tunnelRequests, [true, false]);
      expect(platform.peerProbeCount, greaterThan(1));
    },
  );

  test(
    'successful preconnect transfers owned lease to native session',
    () async {
      final platform = _FakeAndroidVpnPlatform(
        ['offline', 'online'],
        vpnStates: [false, false, true],
      );
      final coordinator = AndroidVpnSessionCoordinator.forTest(
        platform: platform,
        vpnActivationTimeout: const Duration(milliseconds: 100),
        vpnRetryDelay: const Duration(milliseconds: 50),
        networkPollInterval: const Duration(milliseconds: 1),
        peerReachabilityTimeout: const Duration(milliseconds: 100),
        probeInterval: const Duration(milliseconds: 1),
      );

      final result = await coordinator.prepare('10.0.0.2');
      final didAttach = await coordinator.attach('10.0.0.2', 'session-1');

      expect(result.proceed, isTrue);
      expect(didAttach, isTrue);
      expect(platform.attached?['session_id'], 'session-1');
      expect(platform.attached?['tunnel'], 'office');
      expect(platform.attached?['owns_tunnel'], isTrue);
    },
  );
}
