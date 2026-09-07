import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

/// The package version omits the RustAdmin revision; read the running native
/// library's full version once, including when the parent settings rebuild.
class MobileAppVersion extends StatefulWidget {
  const MobileAppVersion({super.key});

  @override
  State<MobileAppVersion> createState() => _MobileAppVersionState();
}

class _MobileAppVersionState extends State<MobileAppVersion> {
  late final Future<String> _fullVersion = bind.mainGetVersion();

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _fullVersion,
    initialData: version,
    builder: (context, snapshot) {
      final fullVersion = snapshot.data?.trim();
      final displayedVersion = fullVersion != null && fullVersion.isNotEmpty
          ? fullVersion
          : version;
      return Text('${translate('Version')}: $displayedVersion');
    },
  );
}
