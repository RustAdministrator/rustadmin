sealed class SessionEvent {
  const SessionEvent();
}

final class ConnectionReadySessionEvent extends SessionEvent {
  const ConnectionReadySessionEvent({
    required this.secure,
    required this.direct,
    required this.streamType,
  });

  final bool secure;
  final bool direct;
  final String streamType;
}

final class PermissionSessionEvent extends SessionEvent {
  PermissionSessionEvent(Map<String, bool> permissions)
    : permissions = Map.unmodifiable(permissions);

  final Map<String, bool> permissions;
}

final class InvalidSessionEvent extends SessionEvent {
  const InvalidSessionEvent(this.name, this.reason);

  final String name;
  final String reason;
}

SessionEvent? decodeTypedSessionEvent(Map<String, dynamic> event) {
  final name = event['name'];
  if (name is! String) return const InvalidSessionEvent('', 'missing name');
  switch (name) {
    case 'connection_ready':
      final secure = _decodeBool(event['secure']);
      final direct = _decodeBool(event['direct']);
      final streamType = event['stream_type'];
      if (secure == null || direct == null) {
        return const InvalidSessionEvent(
          'connection_ready',
          'invalid secure/direct flag',
        );
      }
      if (streamType != null && streamType is! String) {
        return const InvalidSessionEvent(
          'connection_ready',
          'invalid stream type',
        );
      }
      return ConnectionReadySessionEvent(
        secure: secure,
        direct: direct,
        streamType: streamType as String? ?? '',
      );
    case 'permission':
      final permissions = <String, bool>{};
      for (final entry in event.entries) {
        if (entry.key == 'name' || entry.key.isEmpty) continue;
        final value = _decodeBool(entry.value);
        if (value == null) {
          return InvalidSessionEvent('permission', 'invalid ${entry.key} flag');
        }
        permissions[entry.key] = value;
      }
      if (permissions.isEmpty) {
        return const InvalidSessionEvent('permission', 'empty snapshot');
      }
      return PermissionSessionEvent(permissions);
    default:
      return null;
  }
}

bool? _decodeBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    if (value.toLowerCase() == 'true') return true;
    if (value.toLowerCase() == 'false') return false;
  }
  return null;
}
