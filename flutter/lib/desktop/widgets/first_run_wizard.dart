import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' hide Dialog;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class _FirstRunWizardRequest {
  final FirstRunWizardSettings initialSettings;
  final bool directAccessFixed;
  final bool lanDiscoveryFixed;
  final bool localPairingFixed;
  final Completer<FirstRunWizardSettings?> completer;

  const _FirstRunWizardRequest({
    required this.initialSettings,
    required this.directAccessFixed,
    required this.lanDiscoveryFixed,
    required this.localPairingFixed,
    required this.completer,
  });
}

final ValueNotifier<_FirstRunWizardRequest?> _firstRunWizardRequest =
    ValueNotifier(null);
bool _firstRunWizardHostAttached = false;

class FirstRunWizardSettings {
  final bool directAccessEnabled;
  final String lanDiscoveryMode;
  final String localPairingPassphrase;
  final bool showOnNextStart;

  const FirstRunWizardSettings({
    required this.directAccessEnabled,
    required this.lanDiscoveryMode,
    required this.localPairingPassphrase,
    required this.showOnNextStart,
  });

  FirstRunWizardSettings copyWith({
    bool? directAccessEnabled,
    String? lanDiscoveryMode,
    String? localPairingPassphrase,
    bool? showOnNextStart,
  }) {
    return FirstRunWizardSettings(
      directAccessEnabled: directAccessEnabled ?? this.directAccessEnabled,
      lanDiscoveryMode: lanDiscoveryMode ?? this.lanDiscoveryMode,
      localPairingPassphrase:
          localPairingPassphrase ?? this.localPairingPassphrase,
      showOnNextStart: showOnNextStart ?? this.showOnNextStart,
    );
  }
}

Future<void> showAndApplyFirstRunWizard(BuildContext context) async {
  final result = await showFirstRunWizardDialog(
    context: context,
    initialSettings: FirstRunWizardSettings(
      directAccessEnabled: mainGetBoolOptionSync(kOptionDirectServer),
      lanDiscoveryMode: await loadLanDiscoveryMode(),
      localPairingPassphrase:
          bind.mainGetOptionSync(key: kOptionDirectAccessPairingPassphrase),
      showOnNextStart: await shouldShowWelcomeOnStartup(),
    ),
    directAccessFixed: isOptionFixed(kOptionDirectServer),
    lanDiscoveryFixed: isLanDiscoveryModeFixed(),
    localPairingFixed: isOptionFixed(kOptionDirectAccessPairingPassphrase),
  );
  if (result == null) {
    return;
  }
  if (!isOptionFixed(kOptionDirectServer)) {
    await bind.mainSetOption(
      key: kOptionDirectServer,
      value: bool2option(kOptionDirectServer, result.directAccessEnabled),
    );
  }
  if (!isLanDiscoveryModeFixed()) {
    await setLanDiscoveryMode(result.lanDiscoveryMode);
  }
  if (!isOptionFixed(kOptionDirectAccessPairingPassphrase)) {
    await bind.mainSetOption(
      key: kOptionDirectAccessPairingPassphrase,
      value: result.localPairingPassphrase,
    );
  }
  await setShowWelcomeOnStartup(result.showOnNextStart);
}

Future<FirstRunWizardSettings?> showFirstRunWizardDialog({
  required BuildContext context,
  required FirstRunWizardSettings initialSettings,
  required bool directAccessFixed,
  required bool lanDiscoveryFixed,
  required bool localPairingFixed,
}) {
  if (!_firstRunWizardHostAttached) {
    return showDialog<FirstRunWizardSettings>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FirstRunWizardDialog(
        initialSettings: initialSettings,
        directAccessFixed: directAccessFixed,
        lanDiscoveryFixed: lanDiscoveryFixed,
        localPairingFixed: localPairingFixed,
      ),
    );
  }

  final completer = Completer<FirstRunWizardSettings?>();
  _firstRunWizardRequest.value = _FirstRunWizardRequest(
    initialSettings: initialSettings,
    directAccessFixed: directAccessFixed,
    lanDiscoveryFixed: lanDiscoveryFixed,
    localPairingFixed: localPairingFixed,
    completer: completer,
  );
  return completer.future;
}

class FirstRunWizardHost extends StatefulWidget {
  final Widget child;

  const FirstRunWizardHost({super.key, required this.child});

  @override
  State<FirstRunWizardHost> createState() => _FirstRunWizardHostState();
}

class _FirstRunWizardHostState extends State<FirstRunWizardHost> {
  @override
  void initState() {
    super.initState();
    _firstRunWizardHostAttached = true;
  }

  @override
  void dispose() {
    _firstRunWizardHostAttached = false;
    super.dispose();
  }

  void _closeRequest(
    _FirstRunWizardRequest request,
    FirstRunWizardSettings? result,
  ) {
    if (!request.completer.isCompleted) {
      request.completer.complete(result);
    }
    if (identical(_firstRunWizardRequest.value, request)) {
      _firstRunWizardRequest.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_FirstRunWizardRequest?>(
      valueListenable: _firstRunWizardRequest,
      builder: (context, request, _) {
        return Stack(
          children: [
            widget.child,
            if (request != null)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.center,
                  child: FirstRunWizardDialog(
                    initialSettings: request.initialSettings,
                    directAccessFixed: request.directAccessFixed,
                    lanDiscoveryFixed: request.lanDiscoveryFixed,
                    localPairingFixed: request.localPairingFixed,
                    onClose: (result) => _closeRequest(request, result),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class FirstRunWizardDialog extends StatefulWidget {
  final FirstRunWizardSettings initialSettings;
  final bool directAccessFixed;
  final bool lanDiscoveryFixed;
  final bool localPairingFixed;
  final ValueChanged<FirstRunWizardSettings?>? onClose;

  const FirstRunWizardDialog({
    super.key,
    required this.initialSettings,
    required this.directAccessFixed,
    required this.lanDiscoveryFixed,
    required this.localPairingFixed,
    this.onClose,
  });

  @override
  State<FirstRunWizardDialog> createState() => _FirstRunWizardDialogState();
}

class _FirstRunWizardDialogState extends State<FirstRunWizardDialog> {
  static const _pageCount = 4;

  late FirstRunWizardSettings _settings;
  late final TextEditingController _pairingController;
  int _page = 0;
  bool _obscurePairing = true;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _pairingController = TextEditingController(
      text: widget.initialSettings.localPairingPassphrase,
    );
  }

  @override
  void dispose() {
    _pairingController.dispose();
    super.dispose();
  }

  String _lanModeLabel(String mode) {
    switch (mode) {
      case kLanDiscoveryModeTrustedPeersOnly:
        return 'Trusted peers only';
      case kLanDiscoveryModeStandard:
        return 'Standard';
      default:
        return 'Off';
    }
  }

  void _close(FirstRunWizardSettings? result) {
    if (widget.onClose != null) {
      widget.onClose!(result);
    } else {
      Navigator.of(context).pop(result);
    }
  }

  void _finish() {
    _close(_settings.copyWith(
      localPairingPassphrase: _pairingController.text.trim(),
    ));
  }

  Widget _buildStepIndicator() {
    return Row(
      children: List.generate(_pageCount, (index) {
        final active = index == _page;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: index == _pageCount - 1 ? 0 : 8),
            height: 4,
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).dividerColor.withOpacity(0.4),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildWelcomePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WizardBullet(
          icon: Icons.vpn_lock_outlined,
          title: 'Direct local access',
          body:
              'Allow peers on your LAN or VPN to connect directly to this device.',
        ),
        _WizardBullet(
          icon: Icons.travel_explore_outlined,
          title: 'LAN discovery',
          body:
              'Optionally announce this device on the local network so nearby peers can find it faster.',
        ),
        _WizardBullet(
          icon: Icons.key_outlined,
          title: 'Local pairing',
          body:
              'Protect first direct local-only connections with a pairing passphrase when you need it.',
        ),
      ],
    );
  }

  Widget _buildBasicsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WizardCard(
          icon: Icons.public,
          title: 'Public or private server',
          body:
              'Use this when peers connect by ID through rendezvous and relay services.',
        ),
        const SizedBox(height: 12),
        _WizardCard(
          icon: Icons.router_outlined,
          title: 'Local or VPN mode',
          body:
              'Use this when peers can reach your local or VPN address directly. This avoids depending on a server for nearby/private connections.',
        ),
        const SizedBox(height: 12),
        _WizardCard(
          icon: Icons.settings_suggest_outlined,
          title: 'Change later',
          body:
              'Everything here stays available in Settings, so this wizard only sets a clean starting point.',
        ),
      ],
    );
  }

  Widget _buildQuickSetupPage() {
    final disabledStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: _settings.directAccessEnabled,
          onChanged: widget.directAccessFixed
              ? null
              : (value) {
                  setState(() {
                    _settings = _settings.copyWith(directAccessEnabled: value);
                  });
                },
          title: const Text('Enable direct local/VPN access'),
          subtitle: Text(
            widget.directAccessFixed
                ? 'Managed by your deployment.'
                : 'Recommended for new installs. This listens for direct encrypted connections on your local or VPN address.',
            style: disabledStyle,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'LAN discovery',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        Text(
          widget.lanDiscoveryFixed
              ? 'Managed by your deployment.'
              : 'Choose whether this device answers discovery requests on the local network.',
          style: disabledStyle,
        ),
        const SizedBox(height: 8),
        _LanModeTile(
          title: 'Off',
          body: 'Do not advertise this device on the local network.',
          value: kLanDiscoveryModeOff,
          groupValue: _settings.lanDiscoveryMode,
          enabled: !widget.lanDiscoveryFixed,
          onChanged: (value) {
            setState(() {
              _settings = _settings.copyWith(lanDiscoveryMode: value);
            });
          },
        ),
        _LanModeTile(
          title: 'Trusted peers only',
          body:
              'Reply only to discovery requests that match trusted peers already known to this device.',
          value: kLanDiscoveryModeTrustedPeersOnly,
          groupValue: _settings.lanDiscoveryMode,
          enabled: !widget.lanDiscoveryFixed,
          onChanged: (value) {
            setState(() {
              _settings = _settings.copyWith(lanDiscoveryMode: value);
            });
          },
        ),
        _LanModeTile(
          title: 'Standard',
          body:
              'Reply to local discovery requests from nearby peers on the same network.',
          value: kLanDiscoveryModeStandard,
          groupValue: _settings.lanDiscoveryMode,
          enabled: !widget.lanDiscoveryFixed,
          onChanged: (value) {
            setState(() {
              _settings = _settings.copyWith(lanDiscoveryMode: value);
            });
          },
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pairingController,
          enabled: !widget.localPairingFixed,
          obscureText: _obscurePairing,
          decoration: InputDecoration(
            labelText: 'Local pairing passphrase',
            hintText: 'Optional',
            helperText: widget.localPairingFixed
                ? 'Managed by your deployment.'
                : 'Optional. Require this for first direct local-only connections.',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: widget.localPairingFixed
                      ? null
                      : () {
                          setState(() {
                            _obscurePairing = !_obscurePairing;
                          });
                        },
                  icon: Icon(
                    _obscurePairing ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
                IconButton(
                  onPressed: widget.localPairingFixed
                      ? null
                      : () {
                          _pairingController.clear();
                          setState(() {});
                        },
                  icon: const Icon(Icons.clear, size: 18),
                ),
              ],
            ),
          ),
          onChanged: (value) {
            setState(() {
              _settings =
                  _settings.copyWith(localPairingPassphrase: value.trim());
            });
          },
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.info_outline, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'You can still set a permanent access password later from the main page or Settings.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.35),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewPage() {
    final pairing = _pairingController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WizardSummaryRow(
          label: 'Direct local/VPN access',
          value: _settings.directAccessEnabled ? 'Enabled' : 'Disabled',
        ),
        _WizardSummaryRow(
          label: 'LAN discovery',
          value: _lanModeLabel(_settings.lanDiscoveryMode),
        ),
        _WizardSummaryRow(
          label: 'Local pairing passphrase',
          value: pairing.isEmpty ? 'Not set' : 'Configured',
        ),
        const SizedBox(height: 18),
        Center(
          child: Icon(
            Icons.check_circle_outline_rounded,
            size: 34,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    late final String pageTitle;
    late final String pageBody;
    final Widget page;
    switch (_page) {
      case 0:
        pageTitle = 'Welcome to RustAdmin';
        pageBody =
            'This quick setup helps you start with direct local or VPN connections and shows where the main network controls live.';
        page = _buildWelcomePage();
        break;
      case 1:
        pageTitle = 'How connections work';
        pageBody =
            'RustAdmin can use a public or private rendezvous server, or it can accept direct encrypted local/VPN connections when direct access is enabled.';
        page = _buildBasicsPage();
        break;
      case 2:
        pageTitle = 'Quick setup';
        pageBody =
            'Choose the local network behavior you want on this device. These settings affect how nearby or VPN peers can find and reach you.';
        page = _buildQuickSetupPage();
        break;
      default:
        pageTitle = 'Ready to apply';
        pageBody =
            'RustAdmin will save these startup settings now. You can change them later from Settings.';
        page = _buildReviewPage();
        break;
    }
    final isLastPage = _page == 3;
    final navButtonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(const Size(132, 52)),
      padding: WidgetStatePropertyAll(
        const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4.0)),
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pageTitle,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 20),
              Flexible(
                child: SingleChildScrollView(child: page),
              ),
              const SizedBox(height: 14),
              Text(
                pageBody,
                style:
                    Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 16),
              _buildStepIndicator(),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _settings.showOnNextStart,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _settings = _settings.copyWith(showOnNextStart: value);
                  });
                },
                title: const Text('Show on next start'),
                subtitle: const Text(
                  'Keep this welcome window visible automatically when RustAdmin starts.',
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  if (_page == 0)
                    TextButton(
                      style: navButtonStyle,
                      onPressed: _finish,
                      child: const Text('Skip'),
                    )
                  else
                    TextButton(
                      style: navButtonStyle,
                      onPressed: () {
                        setState(() {
                          _page -= 1;
                        });
                      },
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  if (!isLastPage)
                    ElevatedButton(
                      style: navButtonStyle,
                      onPressed: () {
                        setState(() {
                          _page += 1;
                        });
                      },
                      child: const Text('Next'),
                    )
                  else
                    ElevatedButton(
                      style: navButtonStyle,
                      onPressed: _finish,
                      child: const Text('Finish'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WizardBullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _WizardBullet({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _WizardCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4.0),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LanModeTile extends StatelessWidget {
  final String title;
  final String body;
  final String value;
  final String groupValue;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _LanModeTile({
    required this.title,
    required this.body,
    required this.value,
    required this.groupValue,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RadioListTile<String>(
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: value,
      groupValue: groupValue,
      onChanged: enabled ? (newValue) => onChanged(newValue!) : null,
      title: Text(title),
      subtitle: Text(body),
    );
  }
}

class _WizardSummaryRow extends StatelessWidget {
  final String label;
  final String value;

  const _WizardSummaryRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
