import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/quality_monitor_window.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

QualityStatusSessionEvent qualityEvent(Map<String, dynamic> values) =>
    decodeTypedSessionEvent({'name': 'update_quality_status', ...values})
        as QualityStatusSessionEvent;

void main() {
  test('detached quality monitor snapshot round-trips bounded data', () {
    final source = QualityMonitorData()
      ..speed = '42KB/s'
      ..codecFormat = 'H265'
      ..connectionType = 'QUIC/UDP'
      ..quicReassemblyDrops = '3'
      ..movieFallbackReason = 'x' * 2000;

    final encoded = qualityMonitorDataToWindowJson(source);
    final decoded = qualityMonitorDataFromWindowJson(encoded);

    expect(decoded.speed, source.speed);
    expect(decoded.codecFormat, source.codecFormat);
    expect(decoded.quicReassemblyDrops, source.quicReassemblyDrops);
    expect(decoded.movieFallbackReason, hasLength(1024));
  });

  test('TCP transport clears and rejects stale QUIC metrics', () {
    final model = QualityMonitorModel.detached();
    addTearDown(model.dispose);

    model.updateQualityStatusEvent(
      qualityEvent({
        'connection_type': 'QUIC/UDP',
        'transport_mtu': '1360',
        'transport_rtt_ms': '8',
        'quic_protocol': 'v4',
        'quic_reassembly_drops': '7',
      }),
    );
    expect(model.data.isQuicTransport, isTrue);
    expect(model.data.quicProtocol, 'v4');
    expect(model.data.quicReassemblyDrops, '7');

    model.updateConnectionInfo('TCP', true);
    expect(model.data.connectionType, 'TCP');
    expect(model.data.isQuicTransport, isFalse);
    expect(model.data.transportMtu, isNull);
    expect(model.data.transportRttMs, isNull);
    expect(model.data.quicProtocol, isNull);
    expect(model.data.quicReassemblyDrops, isNull);

    model.updateQualityStatusEvent(
      qualityEvent({
        'connection_type': 'TCP',
        'transport_mtu': '1360',
        'quic_protocol': 'v4',
        'quic_reassembly_drops': '9',
      }),
    );
    expect(model.data.transportMtu, isNull);
    expect(model.data.quicProtocol, isNull);
    expect(model.data.quicReassemblyDrops, isNull);
  });

  test('detached TCP snapshots omit stale QUIC metrics', () {
    final source = QualityMonitorData()
      ..connectionType = 'TCP'
      ..transportMtu = '1360'
      ..quicProtocol = 'v4';

    final encoded = qualityMonitorDataToWindowJson(source);
    expect(encoded['connectionType'], 'TCP');
    expect(encoded.containsKey('transportMtu'), isFalse);
    expect(encoded.containsKey('quicProtocol'), isFalse);

    final decoded = qualityMonitorDataFromWindowJson({
      'connectionType': 'TCP',
      'transportMtu': '1360',
      'quicProtocol': 'v4',
    });
    expect(decoded.transportMtu, isNull);
    expect(decoded.quicProtocol, isNull);
  });

  test('detached model applies only normalized display state', () {
    final model = QualityMonitorModel.detached();
    addTearDown(model.dispose);

    model.applyDetachedSnapshot(
      details: 'invalid',
      data: QualityMonitorData()..fps = '60',
    );

    expect(model.show, isTrue);
    expect(model.position, kQualityMonitorPositionDetached);
    expect(model.details, kQualityMonitorDetailsBasic);
    expect(model.data.fps, '60');
  });
}
