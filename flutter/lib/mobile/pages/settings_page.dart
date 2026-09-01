import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/edge_thickness_control.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:settings_ui/settings_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../common/quality_monitor_settings.dart';
import '../../common/remote_display_settings.dart';
import '../../common/remote_toolbar_settings.dart';
import '../../common/transport_mode.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/login.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/dialog.dart';
import '../mobile_remote_settings_repository.dart';
import '../widgets/mobile_settings_layout.dart';
import '../widgets/remote_session_controls.dart';
import 'home_page.dart';
import 'scan_page.dart';

class SettingsPage extends StatefulWidget implements PageShape {
  @override
  final title = translate("Settings");

  @override
  final icon = Icon(Icons.settings);

  @override
  final appBarActions = bind.isDisableSettings() ? [] : [ScanButton()];

  @override
  State<SettingsPage> createState() => _SettingsState();
}

enum KeepScreenOn { never, duringControlled, serviceOn }

enum _MobileSettingsCategory { account, general, security, network, about }

String _keepScreenOnToOption(KeepScreenOn value) {
  switch (value) {
    case KeepScreenOn.never:
      return 'never';
    case KeepScreenOn.duringControlled:
      return 'during-controlled';
    case KeepScreenOn.serviceOn:
      return 'service-on';
  }
}

KeepScreenOn optionToKeepScreenOn(String value) {
  switch (value) {
    case 'never':
      return KeepScreenOn.never;
    case 'service-on':
      return KeepScreenOn.serviceOn;
    default:
      return KeepScreenOn.duringControlled;
  }
}

class _SettingsState extends State<SettingsPage> with WidgetsBindingObserver {
  final _hasIgnoreBattery =
      false; //androidVersion >= 26; // remove because not work on every device
  var _ignoreBatteryOpt = false;
  var _enableStartOnBoot = false;
  var _checkUpdateOnStartup = false;
  var _showTerminalExtraKeys = false;
  var _floatingWindowDisabled = false;
  var _keepScreenOn = KeepScreenOn.duringControlled; // relay on floating window
  var _enableAbr = false;
  var _lanDiscoveryMode = kLanDiscoveryModeStandard;
  var _onlyWhiteList = false;
  var _enableDirectIPAccess = false;
  var _directAccessPairingPassphraseSet = false;
  var _rememberPairedViewers = true;
  var _peerPairingPassphraseSet = false;
  var _enableRecordSession = false;
  var _enableHardwareCodec = false;
  var _useTextureRender = false;
  var _allowWebSocket = false;
  var _allowIdRelayServer = false;
  var _autoRecordIncomingSession = false;
  var _autoRecordOutgoingSession = false;
  var _allowAutoDisconnect = false;
  var _localIP = "";
  var _directAccessPort = "";
  var _fingerprint = "";
  var _buildDate = "";
  var _autoDisconnectTimeout = "";
  var _hideServer = false;
  var _hideProxy = false;
  var _hideNetwork = false;
  var _hideWebSocket = false;
  var _enableTrustedDevices = false;
  var _enableUdpPunch = false;
  var _allowInsecureTlsFallback = false;
  var _allowUnverifiedPeerTrust = false;
  var _transportMode = RemoteTransportPreference.auto;
  var _enableIpv6Punch = false;
  var _isUsingPublicServer = false;
  var _allowAskForNoteAtEndOfConnection = false;
  var _preventSleepWhileConnected = true;
  var _allowClipboardDebug = false;
  var _diagnosticLogging = true;
  late MobileSettingsLayout _settingsLayout;
  _MobileSettingsCategory? _selectedSettingsCategory;

  _SettingsState() {
    _settingsLayout = normalizeMobileSettingsLayout(
      bind.mainGetLocalOption(key: kOptionMobileSettingsLayout),
      fallback: isAndroid
          ? MobileSettingsLayout.modern
          : MobileSettingsLayout.classic,
    );
    _enableAbr = option2bool(
      kOptionEnableAbr,
      bind.mainGetOptionSync(key: kOptionEnableAbr),
    );
    _lanDiscoveryMode = normalizeLanDiscoveryMode(
      bind.mainGetOptionSync(key: kOptionLanDiscoveryMode),
      legacyOptionValue: bind.mainGetOptionSync(key: kOptionEnableLanDiscovery),
    );
    _onlyWhiteList = whitelistNotEmpty();
    _enableDirectIPAccess = option2bool(
      kOptionDirectServer,
      bind.mainGetOptionSync(key: kOptionDirectServer),
    );
    _directAccessPairingPassphraseSet = bind
        .mainGetOptionSync(key: kOptionDirectAccessPairingPassphrase)
        .isNotEmpty;
    _rememberPairedViewers = mainGetBoolOptionSync(
      kOptionRememberPairedViewers,
    );
    _peerPairingPassphraseSet = bind
        .mainGetOptionSync(key: kOptionPeerPairingPassphrase)
        .isNotEmpty;
    _enableRecordSession = option2bool(
      kOptionEnableRecordSession,
      bind.mainGetOptionSync(key: kOptionEnableRecordSession),
    );
    _enableHardwareCodec = option2bool(
      kOptionEnableHwcodec,
      bind.mainGetOptionSync(key: kOptionEnableHwcodec),
    );
    _useTextureRender = bind.mainGetUseTextureRender();
    _allowWebSocket = mainGetBoolOptionSync(kOptionAllowWebSocket);
    _allowIdRelayServer = mainGetBoolOptionSync(kOptionAllowIdRelayServer);
    _allowInsecureTlsFallback = mainGetBoolOptionSync(
      kOptionAllowInsecureTLSFallback,
    );
    _allowUnverifiedPeerTrust = mainGetBoolOptionSync(
      kOptionAllowUnverifiedPeerTrust,
    );
    _transportMode = remoteTransportPreferenceFromOptions(
      remoteTransport: bind.mainGetOptionSync(key: kOptionRemoteTransport),
      disableUdp: bind.mainGetOptionSync(key: kOptionDisableUdp),
    );
    _autoRecordIncomingSession = option2bool(
      kOptionAllowAutoRecordIncoming,
      bind.mainGetOptionSync(key: kOptionAllowAutoRecordIncoming),
    );
    _autoRecordOutgoingSession = option2bool(
      kOptionAllowAutoRecordOutgoing,
      bind.mainGetLocalOption(key: kOptionAllowAutoRecordOutgoing),
    );
    _localIP = bind.mainGetOptionSync(key: 'local-ip-addr');
    _directAccessPort = bind.mainGetOptionSync(key: kOptionDirectAccessPort);
    _allowAutoDisconnect = option2bool(
      kOptionAllowAutoDisconnect,
      bind.mainGetOptionSync(key: kOptionAllowAutoDisconnect),
    );
    _autoDisconnectTimeout = bind.mainGetOptionSync(
      key: kOptionAutoDisconnectTimeout,
    );
    _hideServer =
        bind.mainGetBuildinOption(key: kOptionHideServerSetting) == 'Y';
    _hideProxy = bind.mainGetBuildinOption(key: kOptionHideProxySetting) == 'Y';
    _hideNetwork =
        bind.mainGetBuildinOption(key: kOptionHideNetworkSetting) == 'Y';
    _hideWebSocket =
        bind.mainGetBuildinOption(key: kOptionHideWebSocketSetting) == 'Y' ||
        isWeb;
    _enableTrustedDevices = mainGetBoolOptionSync(kOptionEnableTrustedDevices);
    _enableUdpPunch = mainGetLocalBoolOptionSync(kOptionEnableUdpPunch);
    _enableIpv6Punch = mainGetLocalBoolOptionSync(kOptionEnableIpv6Punch);
    _allowAskForNoteAtEndOfConnection = mainGetLocalBoolOptionSync(
      kOptionAllowAskForNoteAtEndOfConnection,
    );
    _preventSleepWhileConnected = mainGetLocalBoolOptionSync(
      kOptionKeepAwakeDuringOutgoingSessions,
    );
    _allowClipboardDebug = mainGetLocalBoolOptionSync(
      kOptionAllowClipboardDebug,
    );
    _showTerminalExtraKeys = mainGetLocalBoolOptionSync(
      kOptionEnableShowTerminalExtraKeys,
    );
    _diagnosticLogging = option2bool(
      kOptionEnableAndroidDiagnosticLogging,
      bind.mainGetLocalOption(key: kOptionEnableAndroidDiagnosticLogging),
    );
  }

  Future<void> _setSettingsLayout(MobileSettingsLayout layout) async {
    await bind.mainSetLocalOption(
      key: kOptionMobileSettingsLayout,
      value: mobileSettingsLayoutOption(layout),
    );
    if (!mounted) return;
    setState(() {
      _settingsLayout = layout;
      _selectedSettingsCategory = null;
    });
  }

  Widget _settingsLayoutSelector() {
    return MobileSettingsLayoutSelector(
      layout: _settingsLayout,
      title: translate('Settings layout'),
      modernLabel: translate('Modern'),
      classicLabel: translate('Classic'),
      onChanged: (layout) => unawaited(_setSettingsLayout(layout)),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      var update = false;

      if (_hasIgnoreBattery) {
        if (await checkAndUpdateIgnoreBatteryStatus()) {
          update = true;
        }
      }

      if (await checkAndUpdateStartOnBoot()) {
        update = true;
      }

      // start on boot depends on ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS and SYSTEM_ALERT_WINDOW
      var enableStartOnBoot = await gFFI.invokeMethod(
        AndroidChannel.kGetStartOnBootOpt,
      );
      if (enableStartOnBoot) {
        if (!await canStartOnBoot()) {
          enableStartOnBoot = false;
          gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, false);
        }
      }

      if (enableStartOnBoot != _enableStartOnBoot) {
        update = true;
        _enableStartOnBoot = enableStartOnBoot;
      }

      var checkUpdateOnStartup = mainGetLocalBoolOptionSync(
        kOptionEnableCheckUpdate,
      );
      if (checkUpdateOnStartup != _checkUpdateOnStartup) {
        update = true;
        _checkUpdateOnStartup = checkUpdateOnStartup;
      }

      var floatingWindowDisabled =
          bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) == "Y" ||
          !await AndroidPermissionManager.check(kSystemAlertWindow);
      if (floatingWindowDisabled != _floatingWindowDisabled) {
        update = true;
        _floatingWindowDisabled = floatingWindowDisabled;
      }

      final keepScreenOn = _floatingWindowDisabled
          ? KeepScreenOn.never
          : optionToKeepScreenOn(
              bind.mainGetLocalOption(key: kOptionKeepScreenOn),
            );
      if (keepScreenOn != _keepScreenOn) {
        update = true;
        _keepScreenOn = keepScreenOn;
      }

      final fingerprint = await bind.mainGetFingerprint();
      if (_fingerprint != fingerprint) {
        update = true;
        _fingerprint = fingerprint;
      }

      final buildDate = await bind.mainGetBuildDate();
      if (_buildDate != buildDate) {
        update = true;
        _buildDate = buildDate;
      }

      final isUsingPublicServer = await bind.mainIsUsingPublicServer();
      if (_isUsingPublicServer != isUsingPublicServer) {
        update = true;
        _isUsingPublicServer = isUsingPublicServer;
      }

      if (update) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      () async {
        final ibs = await checkAndUpdateIgnoreBatteryStatus();
        final sob = await checkAndUpdateStartOnBoot();
        if (ibs || sob) {
          setState(() {});
        }
      }();
    }
  }

  Future<bool> checkAndUpdateIgnoreBatteryStatus() async {
    final res = await AndroidPermissionManager.check(
      kRequestIgnoreBatteryOptimizations,
    );
    if (_ignoreBatteryOpt != res) {
      _ignoreBatteryOpt = res;
      return true;
    } else {
      return false;
    }
  }

  Future<bool> checkAndUpdateStartOnBoot() async {
    if (!await canStartOnBoot() && _enableStartOnBoot) {
      _enableStartOnBoot = false;
      debugPrint(
        "checkAndUpdateStartOnBoot and set _enableStartOnBoot -> false",
      );
      gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, false);
      return true;
    } else {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    final outgoingOnly = bind.isOutgoingOnly();
    final incomingOnly = bind.isIncomingOnly();
    final customClientSection = CustomSettingsSection(
      key: const ValueKey('mobile-settings-section-branding'),
      child: Column(
        children: [
          if (bind.isCustomClient())
            Align(alignment: Alignment.center, child: loadPowered(context)),
          Align(alignment: Alignment.center, child: loadLogo()),
        ],
      ),
    );
    final List<AbstractSettingsTile> enhancementsTiles = [];
    final enable2fa = bind.mainHasValid2FaSync();
    final List<AbstractSettingsTile> tfaTiles = [
      SettingsTile.switchTile(
        title: Text(translate('enable-2fa-title')),
        initialValue: enable2fa,
        onToggle: (v) async {
          update() async {
            setState(() {});
          }

          if (v == false) {
            CommonConfirmDialog(
              gFFI.dialogManager,
              translate('cancel-2fa-confirm-tip'),
              () {
                change2fa(callback: update);
              },
            );
          } else {
            change2fa(callback: update);
          }
        },
      ),
      if (enable2fa)
        SettingsTile.switchTile(
          title: Text(translate('Telegram bot')),
          initialValue: bind.mainHasValidBotSync(),
          onToggle: (v) async {
            update() async {
              setState(() {});
            }

            if (v == false) {
              CommonConfirmDialog(
                gFFI.dialogManager,
                translate('cancel-bot-confirm-tip'),
                () {
                  changeBot(callback: update);
                },
              );
            } else {
              changeBot(callback: update);
            }
          },
        ),
      if (enable2fa)
        SettingsTile.switchTile(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Enable trusted devices')),
              Text(
                '* ${translate('enable-trusted-devices-tip')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          initialValue: _enableTrustedDevices,
          onToggle: isOptionFixed(kOptionEnableTrustedDevices)
              ? null
              : (v) async {
                  mainSetBoolOption(kOptionEnableTrustedDevices, v);
                  setState(() {
                    _enableTrustedDevices = v;
                  });
                },
        ),
      if (enable2fa && _enableTrustedDevices)
        SettingsTile(
          title: Text(translate('Manage trusted devices')),
          trailing: Icon(Icons.arrow_forward_ios),
          onPressed: (context) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) {
                  return _ManageTrustedDevices();
                },
              ),
            );
          },
        ),
    ];
    final List<AbstractSettingsTile> shareScreenTiles = [
      _getPopupDialogRadioEntry(
        key: const ValueKey('mobile-settings-tile-network-lan-discovery'),
        title: 'LAN discovery',
        list: [
          _RadioEntry('Off', kLanDiscoveryModeOff),
          _RadioEntry('Trusted Peers Only', kLanDiscoveryModeTrustedPeersOnly),
          _RadioEntry('Standard', kLanDiscoveryModeStandard),
        ],
        getter: () => _lanDiscoveryMode,
        asyncSetter: isLanDiscoveryModeFixed()
            ? null
            : (value) async {
                await setLanDiscoveryMode(value);
                setState(() {
                  _lanDiscoveryMode = value;
                });
              },
      ),
      _getPopupDialogRadioEntry(
        key: const ValueKey('mobile-settings-tile-security-clipboard'),
        title: 'Clipboard direction',
        list: clipboardDirectionMenuKeys()
            .map((key) => _RadioEntry(clipboardDirectionPolicyLabel(key), key))
            .toList(),
        getter: () => normalizeClipboardDirectionPolicy(
          bind.mainGetOptionSync(key: kOptionClipboardDirection),
        ),
        asyncSetter: isOptionFixed(kOptionClipboardDirection)
            ? null
            : (value) async {
                await bind.mainSetOption(
                  key: kOptionClipboardDirection,
                  value: value,
                );
              },
      ),
      SettingsTile.switchTile(
        key: const ValueKey('mobile-settings-tile-security-whitelist'),
        title: Row(
          children: [
            Expanded(child: Text(translate('Use IP Whitelisting'))),
            Offstage(
              offstage: !_onlyWhiteList,
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Color.fromARGB(255, 255, 204, 0),
              ),
            ).marginOnly(left: 5),
          ],
        ),
        initialValue: _onlyWhiteList,
        onToggle: (_) async {
          update() async {
            final onlyWhiteList = whitelistNotEmpty();
            if (onlyWhiteList != _onlyWhiteList) {
              setState(() {
                _onlyWhiteList = onlyWhiteList;
              });
            }
          }

          changeWhiteList(callback: update);
        },
      ),
      SettingsTile.switchTile(
        key: const ValueKey('mobile-settings-tile-general-adaptive-bitrate'),
        title: Text(translate('Adaptive bitrate')),
        initialValue: _enableAbr,
        onToggle: isOptionFixed(kOptionEnableAbr)
            ? null
            : (v) async {
                await mainSetBoolOption(kOptionEnableAbr, v);
                final newValue = await mainGetBoolOption(kOptionEnableAbr);
                setState(() {
                  _enableAbr = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        key: const ValueKey('mobile-settings-tile-general-record-session'),
        title: Text(translate('Enable recording session')),
        initialValue: _enableRecordSession,
        onToggle: isOptionFixed(kOptionEnableRecordSession)
            ? null
            : (v) async {
                await mainSetBoolOption(kOptionEnableRecordSession, v);
                final newValue = await mainGetBoolOption(
                  kOptionEnableRecordSession,
                );
                setState(() {
                  _enableRecordSession = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate("Direct IP Access")),
                  Offstage(
                    offstage: !_enableDirectIPAccess,
                    child: Text(
                      '${translate("Local Address")}: $_localIP${_directAccessPort.isEmpty ? "" : ":$_directAccessPort"}${_directAccessPairingPassphraseSet ? "\nLocal pairing passphrase: Required" : ""}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Offstage(
              offstage: !_enableDirectIPAccess,
              child: Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.lock_outline, size: 20),
                    onPressed:
                        isOptionFixed(kOptionDirectAccessPairingPassphrase)
                        ? null
                        : () async {
                            final passphrase =
                                await changeDirectAccessPairingPassphrase(
                                  bind.mainGetOptionSync(
                                    key: kOptionDirectAccessPairingPassphrase,
                                  ),
                                );
                            setState(() {
                              _directAccessPairingPassphraseSet =
                                  passphrase.isNotEmpty;
                            });
                          },
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.edit, size: 20),
                    onPressed: isOptionFixed(kOptionDirectAccessPort)
                        ? null
                        : () async {
                            final port = await changeDirectAccessPort(
                              _localIP,
                              _directAccessPort,
                            );
                            setState(() {
                              _directAccessPort = port;
                            });
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
        initialValue: _enableDirectIPAccess,
        onToggle: isOptionFixed(kOptionDirectServer)
            ? null
            : (_) async {
                _enableDirectIPAccess = !_enableDirectIPAccess;
                String value = bool2option(
                  kOptionDirectServer,
                  _enableDirectIPAccess,
                );
                await bind.mainSetOption(
                  key: kOptionDirectServer,
                  value: value,
                );
                setState(() {});
              },
      ),
      if (_enableDirectIPAccess)
        SettingsTile.switchTile(
          title: Text(translate('Remember paired viewers')),
          initialValue: _rememberPairedViewers,
          onToggle: isOptionFixed(kOptionRememberPairedViewers)
              ? null
              : (v) async {
                  mainSetBoolOption(kOptionRememberPairedViewers, v);
                  setState(() {
                    _rememberPairedViewers = v;
                  });
                },
        ),
      if (_enableDirectIPAccess)
        SettingsTile(
          title: Text(translate('Manage paired viewers')),
          trailing: Icon(Icons.arrow_forward_ios),
          onPressed: (context) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) {
                  return const _ManagePairedViewers();
                },
              ),
            );
          },
        ),
      SettingsTile(
        title: Text(translate("Rendezvous pairing passphrase")),
        value: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _peerPairingPassphraseSet ? 'Configured' : 'Disabled',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        leading: Icon(Icons.verified_user_outlined),
        onPressed: isOptionFixed(kOptionPeerPairingPassphrase)
            ? null
            : (context) async {
                final passphrase = await changePeerPairingPassphrase(
                  bind.mainGetOptionSync(key: kOptionPeerPairingPassphrase),
                );
                setState(() {
                  _peerPairingPassphraseSet = passphrase.isNotEmpty;
                });
              },
      ),
      SettingsTile.switchTile(
        title: Text(translate('Allow unverified peer trust')),
        initialValue: _allowUnverifiedPeerTrust,
        onToggle: isOptionFixed(kOptionAllowUnverifiedPeerTrust)
            ? null
            : (v) async {
                await mainSetBoolOption(kOptionAllowUnverifiedPeerTrust, v);
                final newValue = mainGetBoolOptionSync(
                  kOptionAllowUnverifiedPeerTrust,
                );
                setState(() {
                  _allowUnverifiedPeerTrust = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate("auto_disconnect_option_tip")),
                  Offstage(
                    offstage: !_allowAutoDisconnect,
                    child: Text(
                      '${_autoDisconnectTimeout.isEmpty ? '10' : _autoDisconnectTimeout} min',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Offstage(
              offstage: !_allowAutoDisconnect,
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.edit, size: 20),
                onPressed: isOptionFixed(kOptionAutoDisconnectTimeout)
                    ? null
                    : () async {
                        final timeout = await changeAutoDisconnectTimeout(
                          _autoDisconnectTimeout,
                        );
                        setState(() {
                          _autoDisconnectTimeout = timeout;
                        });
                      },
              ),
            ),
          ],
        ),
        initialValue: _allowAutoDisconnect,
        onToggle: isOptionFixed(kOptionAllowAutoDisconnect)
            ? null
            : (_) async {
                _allowAutoDisconnect = !_allowAutoDisconnect;
                String value = bool2option(
                  kOptionAllowAutoDisconnect,
                  _allowAutoDisconnect,
                );
                await bind.mainSetOption(
                  key: kOptionAllowAutoDisconnect,
                  value: value,
                );
                setState(() {});
              },
      ),
    ];
    if (_hasIgnoreBattery) {
      enhancementsTiles.insert(
        0,
        SettingsTile.switchTile(
          initialValue: _ignoreBatteryOpt,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Keep RustDesk background service')),
              Text(
                '* ${translate('Ignore Battery Optimizations')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          onToggle: (v) async {
            if (v) {
              await AndroidPermissionManager.request(
                kRequestIgnoreBatteryOptimizations,
              );
            } else {
              final res = await gFFI.dialogManager.show<bool>(
                (setState, close, context) => CustomAlertDialog(
                  title: Text(translate("Open System Setting")),
                  content: Text(
                    translate("android_open_battery_optimizations_tip"),
                  ),
                  actions: [
                    dialogButton(
                      "Cancel",
                      onPressed: () => close(),
                      isOutline: true,
                    ),
                    dialogButton(
                      "Open System Setting",
                      onPressed: () => close(true),
                    ),
                  ],
                ),
              );
              if (res == true) {
                AndroidPermissionManager.startAction(
                  kActionApplicationDetailsSettings,
                );
              }
            }
          },
        ),
      );
    }
    enhancementsTiles.add(
      SettingsTile.switchTile(
        initialValue: _enableStartOnBoot,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('Start on boot')),
            Text(
              '* ${translate('Start the screen sharing service on boot, requires special permissions')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        onToggle: (toValue) async {
          if (toValue) {
            // 1. request kIgnoreBatteryOptimizations
            if (!await AndroidPermissionManager.check(
              kRequestIgnoreBatteryOptimizations,
            )) {
              if (!await AndroidPermissionManager.request(
                kRequestIgnoreBatteryOptimizations,
              )) {
                return;
              }
            }

            // 2. request kSystemAlertWindow
            if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
              if (!await AndroidPermissionManager.request(kSystemAlertWindow)) {
                return;
              }
            }

            // (Optional) 3. request input permission
          }
          setState(() => _enableStartOnBoot = toValue);

          gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, toValue);
        },
      ),
    );

    if (!bind.isCustomClient()) {
      enhancementsTiles.add(
        SettingsTile.switchTile(
          initialValue: _checkUpdateOnStartup,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(translate('Check for software update on startup'))],
          ),
          onToggle: (bool toValue) async {
            await mainSetLocalBoolOption(kOptionEnableCheckUpdate, toValue);
            setState(() => _checkUpdateOnStartup = toValue);
          },
        ),
      );
    }

    enhancementsTiles.add(
      SettingsTile.switchTile(
        initialValue: _showTerminalExtraKeys,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(translate('Show terminal extra keys'))],
        ),
        onToggle: (bool v) async {
          await mainSetLocalBoolOption(kOptionEnableShowTerminalExtraKeys, v);
          final newValue = mainGetLocalBoolOptionSync(
            kOptionEnableShowTerminalExtraKeys,
          );
          setState(() {
            _showTerminalExtraKeys = newValue;
          });
        },
      ),
    );

    onFloatingWindowChanged(bool toValue) async {
      if (toValue) {
        if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
          if (!await AndroidPermissionManager.request(kSystemAlertWindow)) {
            return;
          }
        }
      }
      final disable = !toValue;
      bind.mainSetLocalOption(
        key: kOptionDisableFloatingWindow,
        value: disable ? 'Y' : defaultOptionNo,
      );
      setState(() => _floatingWindowDisabled = disable);
      gFFI.serverModel.androidUpdatekeepScreenOn();
    }

    enhancementsTiles.add(
      SettingsTile.switchTile(
        initialValue: !_floatingWindowDisabled,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('Floating window')),
            Text(
              '* ${translate('floating_window_tip')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        onToggle: bind.mainIsOptionFixed(key: kOptionDisableFloatingWindow)
            ? null
            : onFloatingWindowChanged,
      ),
    );

    enhancementsTiles.add(
      _getPopupDialogRadioEntry(
        title: 'Keep screen on',
        list: [
          _RadioEntry('Never', _keepScreenOnToOption(KeepScreenOn.never)),
          _RadioEntry(
            'During controlled',
            _keepScreenOnToOption(KeepScreenOn.duringControlled),
          ),
          _RadioEntry(
            'During service is on',
            _keepScreenOnToOption(KeepScreenOn.serviceOn),
          ),
        ],
        getter: () => _keepScreenOnToOption(
          _floatingWindowDisabled
              ? KeepScreenOn.never
              : optionToKeepScreenOn(
                  bind.mainGetLocalOption(key: kOptionKeepScreenOn),
                ),
        ),
        asyncSetter:
            isOptionFixed(kOptionKeepScreenOn) || _floatingWindowDisabled
            ? null
            : (value) async {
                await bind.mainSetLocalOption(
                  key: kOptionKeepScreenOn,
                  value: value,
                );
                setState(() => _keepScreenOn = optionToKeepScreenOn(value));
                gFFI.serverModel.androidUpdatekeepScreenOn();
              },
      ),
    );

    final disabledSettings = bind.isDisableSettings();
    final hideSecuritySettings =
        bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) == 'Y';
    final settings = SettingsList(
      sections: [
        CustomSettingsSection(
          key: const ValueKey('mobile-settings-section-layout'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: _settingsLayoutSelector(),
          ),
        ),
        customClientSection,
        if (!bind.isDisableAccount())
          SettingsSection(
            key: const ValueKey('mobile-settings-section-account'),
            title: Text(translate('Account')),
            tiles: [
              SettingsTile(
                title: Obx(
                  () => Text(
                    gFFI.userModel.userName.value.isEmpty
                        ? translate('Login')
                        : '${translate('Logout')} (${gFFI.userModel.accountLabelWithHandle})',
                  ),
                ),
                leading: Obx(() {
                  final avatar = bind.mainResolveAvatarUrl(
                    avatar: gFFI.userModel.avatar.value,
                  );
                  return buildAvatarWidget(
                        avatar: avatar,
                        size: 28,
                        borderRadius: null,
                        fallback: Icon(Icons.person),
                      ) ??
                      Icon(Icons.person);
                }),
                onPressed: (context) {
                  if (gFFI.userModel.userName.value.isEmpty) {
                    loginDialog();
                  } else {
                    logOutConfirmDialog();
                  }
                },
              ),
            ],
          ),
        SettingsSection(
          key: const ValueKey('mobile-settings-section-primary'),
          title: Text(translate("Settings")),
          tiles: [
            if (!disabledSettings && !_hideNetwork && !_hideServer)
              SettingsTile(
                title: Text(translate('ID/Relay Server')),
                leading: Icon(Icons.cloud),
                onPressed: (context) {
                  showServerSettings(gFFI.dialogManager, (callback) async {
                    _isUsingPublicServer = await bind.mainIsUsingPublicServer();
                    _allowIdRelayServer = await mainGetBoolOption(
                      kOptionAllowIdRelayServer,
                    );
                    setState(callback);
                  });
                },
              ),
            if (!disabledSettings && !_hideNetwork && !_hideServer)
              SettingsTile.switchTile(
                title: Text(translate('Use ID/Relay Server')),
                initialValue: _allowIdRelayServer,
                onToggle: isOptionFixed(kOptionAllowIdRelayServer)
                    ? null
                    : (v) async {
                        await mainSetBoolOption(kOptionAllowIdRelayServer, v);
                        final newValue = await mainGetBoolOption(
                          kOptionAllowIdRelayServer,
                        );
                        final usingPublicServer = await bind
                            .mainIsUsingPublicServer();
                        setState(() {
                          _allowIdRelayServer = newValue;
                          _isUsingPublicServer = usingPublicServer;
                        });
                      },
              ),
            if (!_hideNetwork && !_hideProxy)
              SettingsTile(
                title: Text(translate('Socks5/Http(s) Proxy')),
                leading: Icon(Icons.network_ping),
                onPressed: (context) {
                  changeSocks5Proxy();
                },
              ),
            if (!disabledSettings && !_hideNetwork && !_hideWebSocket)
              SettingsTile.switchTile(
                title: Text(translate('Use WebSocket')),
                initialValue: _allowWebSocket,
                onToggle: isOptionFixed(kOptionAllowWebSocket)
                    ? null
                    : (v) async {
                        await mainSetBoolOption(kOptionAllowWebSocket, v);
                        final newValue = await mainGetBoolOption(
                          kOptionAllowWebSocket,
                        );
                        setState(() {
                          _allowWebSocket = newValue;
                        });
                      },
              ),
            if (!_isUsingPublicServer)
              SettingsTile.switchTile(
                title: Text(translate('Allow insecure TLS fallback')),
                initialValue: _allowInsecureTlsFallback,
                onToggle: isOptionFixed(kOptionAllowInsecureTLSFallback)
                    ? null
                    : (v) async {
                        await mainSetBoolOption(
                          kOptionAllowInsecureTLSFallback,
                          v,
                        );
                        final newValue = mainGetBoolOptionSync(
                          kOptionAllowInsecureTLSFallback,
                        );
                        setState(() {
                          _allowInsecureTlsFallback = newValue;
                        });
                      },
              ),
            if (!disabledSettings && !_hideNetwork)
              _getPopupDialogRadioEntry(
                title: 'Transport',
                list: RemoteTransportPreference.values
                    .map(
                      (mode) =>
                          _RadioEntry(remoteTransportLabel(mode), mode.name),
                    )
                    .toList(),
                getter: () => _transportMode.name,
                asyncSetter:
                    isOptionFixed(kOptionRemoteTransport) ||
                        isOptionFixed(kOptionDisableUdp)
                    ? null
                    : (value) async {
                        final mode = RemoteTransportPreference.values
                            .firstWhere((candidate) => candidate.name == value);
                        await bind.mainSetOption(
                          key: kOptionRemoteTransport,
                          value: remoteTransportOption(mode),
                        );
                        await bind.mainSetOption(
                          key: kOptionDisableUdp,
                          value: disableUdpOption(mode),
                        );
                        setState(() {
                          _transportMode = mode;
                        });
                      },
              ),
            if (!incomingOnly)
              SettingsTile.switchTile(
                title: Text(translate('Enable UDP hole punching')),
                initialValue: _enableUdpPunch,
                onToggle: (v) async {
                  await mainSetLocalBoolOption(kOptionEnableUdpPunch, v);
                  final newValue = mainGetLocalBoolOptionSync(
                    kOptionEnableUdpPunch,
                  );
                  setState(() {
                    _enableUdpPunch = newValue;
                  });
                },
              ),
            if (!incomingOnly)
              SettingsTile.switchTile(
                title: Text(translate('Enable IPv6 P2P connection')),
                initialValue: _enableIpv6Punch,
                onToggle: (v) async {
                  await mainSetLocalBoolOption(kOptionEnableIpv6Punch, v);
                  final newValue = mainGetLocalBoolOptionSync(
                    kOptionEnableIpv6Punch,
                  );
                  setState(() {
                    _enableIpv6Punch = newValue;
                  });
                },
              ),
            SettingsTile.switchTile(
              key: const ValueKey('mobile-settings-tile-diagnostics-clipboard'),
              title: Text(translate('Clipboard debug diagnostics')),
              initialValue: _allowClipboardDebug,
              onToggle: isOptionFixed(kOptionAllowClipboardDebug)
                  ? null
                  : (value) async {
                      await mainSetLocalBoolOption(
                        kOptionAllowClipboardDebug,
                        value,
                      );
                      setState(() {
                        _allowClipboardDebug = mainGetLocalBoolOptionSync(
                          kOptionAllowClipboardDebug,
                        );
                      });
                    },
            ),
            SettingsTile(
              key: const ValueKey('mobile-settings-tile-general-language'),
              title: Text(translate('Language')),
              leading: Icon(Icons.translate),
              onPressed: (context) {
                showLanguageSettings(gFFI.dialogManager);
              },
            ),
            SettingsTile(
              key: const ValueKey('mobile-settings-tile-general-theme'),
              title: Text(
                translate(
                  Theme.of(context).brightness == Brightness.light
                      ? 'Light Theme'
                      : 'Dark Theme',
                ),
              ),
              leading: Icon(
                Theme.of(context).brightness == Brightness.light
                    ? Icons.dark_mode
                    : Icons.light_mode,
              ),
              onPressed: (context) {
                showThemeSettings(gFFI.dialogManager);
              },
            ),
            if (!bind.isDisableAccount())
              SettingsTile.switchTile(
                key: const ValueKey('mobile-settings-tile-general-note'),
                title: Text(translate('note-at-conn-end-tip')),
                initialValue: _allowAskForNoteAtEndOfConnection,
                onToggle: (v) async {
                  if (v && !gFFI.userModel.isLogin) {
                    final res = await loginDialog();
                    if (res != true) return;
                  }
                  await mainSetLocalBoolOption(
                    kOptionAllowAskForNoteAtEndOfConnection,
                    v,
                  );
                  final newValue = mainGetLocalBoolOptionSync(
                    kOptionAllowAskForNoteAtEndOfConnection,
                  );
                  setState(() {
                    _allowAskForNoteAtEndOfConnection = newValue;
                  });
                },
              ),
            if (!incomingOnly)
              SettingsTile.switchTile(
                key: const ValueKey('mobile-settings-tile-general-keep-awake'),
                title: Text(
                  translate('keep-awake-during-outgoing-sessions-label'),
                ),
                initialValue: _preventSleepWhileConnected,
                onToggle: (v) async {
                  await mainSetLocalBoolOption(
                    kOptionKeepAwakeDuringOutgoingSessions,
                    v,
                  );
                  setState(() {
                    _preventSleepWhileConnected = v;
                  });
                },
              ),
          ],
        ),
        if (!disabledSettings && !hideSecuritySettings)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-security'),
            title: Text(translate('Security')),
            tiles: [
              SettingsTile(
                title: Text(translate('Stored peer security')),
                description: Text(
                  translate(
                    'View and remove saved host, password, pairing, and QUIC identity records.',
                  ),
                ),
                leading: const Icon(Icons.security_outlined),
                trailing: const Icon(Icons.arrow_forward_ios),
                onPressed: (context) => manageKnownHostsDialog(),
              ),
            ],
          ),
        if (isAndroid)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-hardware'),
            title: Text(translate('Hardware Codec')),
            tiles: [
              SettingsTile.switchTile(
                title: Text(translate('Enable hardware codec')),
                initialValue: _enableHardwareCodec,
                onToggle: isOptionFixed(kOptionEnableHwcodec)
                    ? null
                    : (v) async {
                        await mainSetBoolOption(kOptionEnableHwcodec, v);
                        final newValue = await mainGetBoolOption(
                          kOptionEnableHwcodec,
                        );
                        setState(() {
                          _enableHardwareCodec = newValue;
                        });
                      },
              ),
              if (bind.mainHasGpuTextureRender())
                SettingsTile.switchTile(
                  title: Text(translate('Use texture rendering')),
                  description: Text(translate('texture_render_tip')),
                  initialValue: _useTextureRender,
                  onToggle: (v) async {
                    await mobileRemoteLocalSettings.write(
                      MobileRemoteSettingsRegistry.textureRender,
                      v,
                    );
                    final actual = bind.mainGetUseTextureRender();
                    setState(() => _useTextureRender = actual);
                  },
                ),
            ],
          ),
        if (isAndroid)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-recording'),
            title: Text(translate("Recording")),
            tiles: [
              if (!outgoingOnly)
                SettingsTile.switchTile(
                  title: Text(
                    translate('Automatically record incoming sessions'),
                  ),
                  initialValue: _autoRecordIncomingSession,
                  onToggle: isOptionFixed(kOptionAllowAutoRecordIncoming)
                      ? null
                      : (v) async {
                          await bind.mainSetOption(
                            key: kOptionAllowAutoRecordIncoming,
                            value: bool2option(
                              kOptionAllowAutoRecordIncoming,
                              v,
                            ),
                          );
                          final newValue = option2bool(
                            kOptionAllowAutoRecordIncoming,
                            await bind.mainGetOption(
                              key: kOptionAllowAutoRecordIncoming,
                            ),
                          );
                          setState(() {
                            _autoRecordIncomingSession = newValue;
                          });
                        },
                ),
              if (!incomingOnly)
                SettingsTile.switchTile(
                  title: Text(
                    translate('Automatically record outgoing sessions'),
                  ),
                  initialValue: _autoRecordOutgoingSession,
                  onToggle: isOptionFixed(kOptionAllowAutoRecordOutgoing)
                      ? null
                      : (v) async {
                          await bind.mainSetLocalOption(
                            key: kOptionAllowAutoRecordOutgoing,
                            value: bool2option(
                              kOptionAllowAutoRecordOutgoing,
                              v,
                            ),
                          );
                          final newValue = option2bool(
                            kOptionAllowAutoRecordOutgoing,
                            bind.mainGetLocalOption(
                              key: kOptionAllowAutoRecordOutgoing,
                            ),
                          );
                          setState(() {
                            _autoRecordOutgoingSession = newValue;
                          });
                        },
                ),
              SettingsTile(
                title: Text(translate("Directory")),
                description: Text(bind.mainVideoSaveDirectory(root: false)),
              ),
            ],
          ),
        if (isAndroid &&
            !disabledSettings &&
            !outgoingOnly &&
            !hideSecuritySettings)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-2fa'),
            title: Text('2FA'),
            tiles: tfaTiles,
          ),
        if (isAndroid &&
            !disabledSettings &&
            !outgoingOnly &&
            !hideSecuritySettings)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-share-screen'),
            title: Text(translate("Share screen")),
            tiles: shareScreenTiles,
          ),
        if (!bind.isIncomingOnly()) defaultDisplaySection(),
        if (isAndroid &&
            !disabledSettings &&
            !outgoingOnly &&
            !hideSecuritySettings)
          SettingsSection(
            key: const ValueKey('mobile-settings-section-enhancements'),
            title: Text(translate("Enhancements")),
            tiles: enhancementsTiles,
          ),
        SettingsSection(
          key: const ValueKey('mobile-settings-section-about'),
          title: Text(translate("About")),
          tiles: [
            SettingsTile(
              key: const ValueKey('mobile-settings-tile-about-version'),
              title: Text('${translate("Version")}: $version'),
              leading: Icon(Icons.info),
            ),
            if (isAndroid)
              SettingsTile.switchTile(
                key: const ValueKey('mobile-settings-tile-diagnostics-logging'),
                title: Text(translate('Diagnostic logging')),
                leading: const Icon(Icons.article_outlined),
                initialValue: _diagnosticLogging,
                onToggle: (enabled) async {
                  await bind.mainSetLocalOption(
                    key: kOptionEnableAndroidDiagnosticLogging,
                    value: bool2option(
                      kOptionEnableAndroidDiagnosticLogging,
                      enabled,
                    ),
                  );
                  final actual = option2bool(
                    kOptionEnableAndroidDiagnosticLogging,
                    bind.mainGetLocalOption(
                      key: kOptionEnableAndroidDiagnosticLogging,
                    ),
                  );
                  platformFFI.setAndroidDiagnosticLoggingEnabled(actual);
                  setState(() => _diagnosticLogging = actual);
                },
              ),
            if (isAndroid)
              SettingsTile(
                key: const ValueKey('mobile-settings-tile-diagnostics-export'),
                onPressed: (context) async {
                  try {
                    await platformFFI.exportAndroidDiagnostics();
                  } catch (error) {
                    debugPrint('Failed to export diagnostics: $error');
                    showToast(translate('Failed'));
                  }
                },
                title: Text(translate('Export diagnostic report')),
                description: Text(
                  translate('Create a private log ZIP and share it'),
                ),
                leading: Icon(Icons.bug_report_outlined),
              ),
            if (isAndroid && !_diagnosticLogging)
              SettingsTile(
                key: const ValueKey('mobile-settings-tile-diagnostics-delete'),
                onPressed: (context) async {
                  final confirmed =
                      await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(translate('Delete diagnostic logs')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(translate('Cancel')),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(translate('Delete')),
                            ),
                          ],
                        ),
                      ) ??
                      false;
                  if (confirmed) {
                    await platformFFI.clearAndroidDiagnostics();
                  }
                },
                title: Text(translate('Delete diagnostic logs')),
                leading: const Icon(Icons.delete_outline),
              ),
            SettingsTile(
              key: const ValueKey('mobile-settings-tile-about-source'),
              onPressed: (context) async {
                await launchUrl(Uri.parse(kRustAdminSourceUrl));
              },
              title: Text('Source code'),
              value: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'github.com/RustAdministrator/rustadmin',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
              ),
              leading: Icon(Icons.code),
            ),
            SettingsTile(
              key: const ValueKey('mobile-settings-tile-about-build-date'),
              title: Text(translate("Build Date")),
              value: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(_buildDate),
              ),
              leading: Icon(Icons.query_builder),
            ),
            if (isAndroid)
              SettingsTile(
                key: const ValueKey('mobile-settings-tile-about-fingerprint'),
                onPressed: (context) => onCopyFingerprint(_fingerprint),
                title: Text(translate("Fingerprint")),
                value: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(_fingerprint),
                ),
                leading: Icon(Icons.fingerprint),
              ),
          ],
        ),
      ],
    );
    if (_settingsLayout == MobileSettingsLayout.classic) {
      return settings;
    }
    return _buildModernSettings(
      context,
      settings.sections,
      customClientSection,
    );
  }

  Widget _buildModernSettings(
    BuildContext context,
    List<AbstractSettingsSection> sections,
    CustomSettingsSection brandingSection,
  ) {
    SettingsSection? sectionById(String id) {
      final key = ValueKey<String>('mobile-settings-section-$id');
      for (final section in sections) {
        if (section is SettingsSection && section.key == key) return section;
      }
      return null;
    }

    String tileId(AbstractSettingsTile tile) {
      final key = tile.key;
      return key is ValueKey<String> ? key.value : '';
    }

    MobileSettingsCategoryGroup? group(
      String title,
      Iterable<AbstractSettingsTile> tiles,
    ) {
      final children = _compactSettingsTiles(tiles);
      return children.isEmpty
          ? null
          : MobileSettingsCategoryGroup(title: title, children: children);
    }

    final primaryTiles = sectionById('primary')?.tiles ?? const [];
    final generalTiles = primaryTiles.where(
      (tile) => tileId(tile).startsWith('mobile-settings-tile-general-'),
    );
    final primaryDiagnosticTiles = primaryTiles.where(
      (tile) => tileId(tile).startsWith('mobile-settings-tile-diagnostics-'),
    );
    final networkTiles = primaryTiles.where((tile) {
      final id = tileId(tile);
      return !id.startsWith('mobile-settings-tile-general-') &&
          !id.startsWith('mobile-settings-tile-diagnostics-');
    });
    final aboutTiles = sectionById('about')?.tiles ?? const [];
    final diagnosticTiles = [
      ...primaryDiagnosticTiles,
      ...aboutTiles.where(
        (tile) => tileId(tile).startsWith('mobile-settings-tile-diagnostics-'),
      ),
    ];
    final aboutInfoTiles = aboutTiles.where(
      (tile) => !tileId(tile).startsWith('mobile-settings-tile-diagnostics-'),
    );
    final shareTiles = sectionById('share-screen')?.tiles ?? const [];
    final shareNetworkTiles = shareTiles.where(
      (tile) => tileId(tile).startsWith('mobile-settings-tile-network-'),
    );
    final shareRecordingTiles = shareTiles.where(
      (tile) => tileId(tile) == 'mobile-settings-tile-general-record-session',
    );
    final shareSecurityTiles = shareTiles.where((tile) {
      final id = tileId(tile);
      return !id.startsWith('mobile-settings-tile-network-') &&
          !id.startsWith('mobile-settings-tile-general-');
    });

    List<MobileSettingsCategoryGroup> nonNullGroups(
      Iterable<MobileSettingsCategoryGroup?> groups,
    ) => [
      for (final group in groups)
        if (group != null) group,
    ];

    final categoryGroups =
        <_MobileSettingsCategory, List<MobileSettingsCategoryGroup>>{
          _MobileSettingsCategory.account: nonNullGroups([
            group(
              translate('Account'),
              sectionById('account')?.tiles ?? const [],
            ),
          ]),
          _MobileSettingsCategory.general: nonNullGroups([
            group(translate('Settings'), generalTiles),
            group(translate('Recording'), [
              ...(sectionById('recording')?.tiles ?? const []),
              ...shareRecordingTiles,
            ]),
            group(
              translate('Enhancements'),
              sectionById('enhancements')?.tiles ?? const [],
            ),
          ]),
          _MobileSettingsCategory.security: nonNullGroups([
            group(
              translate('Security'),
              sectionById('security')?.tiles ?? const [],
            ),
            group('2FA', sectionById('2fa')?.tiles ?? const []),
            group(translate('Share screen'), shareSecurityTiles),
          ]),
          _MobileSettingsCategory.network: nonNullGroups([
            group(translate('Network'), [
              ...networkTiles,
              ...shareNetworkTiles,
            ]),
          ]),
          _MobileSettingsCategory.about: [
            ...nonNullGroups([
              group(translate('Diagnostics'), diagnosticTiles),
              group(translate('About'), aboutInfoTiles),
            ]),
            MobileSettingsCategoryGroup(
              title: '',
              children: [brandingSection.child],
            ),
          ],
        };

    String categoryTitle(_MobileSettingsCategory category) =>
        switch (category) {
          _MobileSettingsCategory.account => translate('Account'),
          _MobileSettingsCategory.general => translate('General'),
          _MobileSettingsCategory.security => translate('Security'),
          _MobileSettingsCategory.network => translate('Network'),
          _MobileSettingsCategory.about => translate('About'),
        };

    final selected = _selectedSettingsCategory;
    if (selected != null && (categoryGroups[selected]?.isNotEmpty ?? false)) {
      return PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            setState(() => _selectedSettingsCategory = null);
          }
        },
        child: MobileSettingsCategoryView(
          id: selected.name,
          title: categoryTitle(selected),
          onBack: () => setState(() => _selectedSettingsCategory = null),
          groups: categoryGroups[selected]!,
        ),
      );
    }

    void openCategory(_MobileSettingsCategory category) {
      setState(() => _selectedSettingsCategory = category);
    }

    return MobileSettingsHome(
      selector: _settingsLayoutSelector(),
      items: [
        if (categoryGroups[_MobileSettingsCategory.account]?.isNotEmpty ??
            false)
          MobileSettingsNavigationItem(
            id: 'account',
            title: translate('Account'),
            icon: Icons.person_outline,
            onPressed: () => openCategory(_MobileSettingsCategory.account),
          ),
        MobileSettingsNavigationItem(
          id: 'general',
          title: translate('General'),
          icon: Icons.tune,
          onPressed: () => openCategory(_MobileSettingsCategory.general),
        ),
        if (categoryGroups[_MobileSettingsCategory.security]?.isNotEmpty ??
            false)
          MobileSettingsNavigationItem(
            id: 'security',
            title: translate('Security'),
            icon: Icons.shield_outlined,
            onPressed: () => openCategory(_MobileSettingsCategory.security),
          ),
        if (categoryGroups[_MobileSettingsCategory.network]?.isNotEmpty ??
            false)
          MobileSettingsNavigationItem(
            id: 'network',
            title: translate('Network'),
            icon: Icons.lan_outlined,
            onPressed: () => openCategory(_MobileSettingsCategory.network),
          ),
        if (!bind.isIncomingOnly())
          MobileSettingsNavigationItem(
            id: 'display',
            title: translate('Display Settings'),
            icon: Icons.desktop_windows_outlined,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => _DisplayPage()),
              );
            },
          ),
        MobileSettingsNavigationItem(
          id: 'about',
          title: translate('About'),
          icon: Icons.info_outline,
          onPressed: () => openCategory(_MobileSettingsCategory.about),
        ),
      ],
    );
  }

  Future<bool> canStartOnBoot() async {
    // start on boot depends on ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS and SYSTEM_ALERT_WINDOW
    if (_hasIgnoreBattery && !_ignoreBatteryOpt) {
      return false;
    }
    if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
      return false;
    }
    return true;
  }

  defaultDisplaySection() {
    return SettingsSection(
      key: const ValueKey('mobile-settings-section-display'),
      title: Text(translate("Display Settings")),
      tiles: [
        SettingsTile(
          title: Text(translate('Display Settings')),
          leading: Icon(Icons.desktop_windows_outlined),
          trailing: Icon(Icons.arrow_forward_ios),
          onPressed: (context) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) {
                  return _DisplayPage();
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CompactSettingsTileAdapter extends StatelessWidget {
  const _CompactSettingsTileAdapter({super.key, required this.tile});

  final AbstractSettingsTile tile;

  bool _isNavigationArrow(Widget? widget) {
    return widget is Icon &&
        (widget.icon == Icons.arrow_forward_ios ||
            widget.icon == Icons.chevron_right ||
            widget.icon == Icons.navigate_next);
  }

  @override
  Widget build(BuildContext context) {
    final settingsTile = tile;
    if (settingsTile is! SettingsTile) {
      return SettingsList(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        contentPadding: EdgeInsets.zero,
        sections: [
          SettingsSection(tiles: [tile]),
        ],
      );
    }

    final subtitle = settingsTile.description ?? settingsTile.value;
    if (settingsTile.tileType == SettingsTileType.switchTile) {
      final onToggle = settingsTile.enabled ? settingsTile.onToggle : null;
      return SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        secondary: settingsTile.leading,
        title: MobileSettingsRowTitle(child: settingsTile.title),
        subtitle: subtitle == null
            ? null
            : MobileSettingsRowSubtitle(child: subtitle),
        value: settingsTile.initialValue ?? false,
        onChanged: onToggle == null ? null : (value) => onToggle(value),
      );
    }

    final onPressed = settingsTile.enabled ? settingsTile.onPressed : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      enabled: settingsTile.enabled,
      leading: settingsTile.leading,
      title: MobileSettingsRowTitle(child: settingsTile.title),
      subtitle: subtitle == null
          ? null
          : MobileSettingsRowSubtitle(child: subtitle),
      trailing:
          _isNavigationArrow(settingsTile.trailing) ||
              (settingsTile.trailing == null && onPressed != null)
          ? const MobileSettingsNavigationChevron()
          : settingsTile.trailing,
      onTap: onPressed == null ? null : () => onPressed(context),
    );
  }
}

List<Widget> _compactSettingsTiles(Iterable<AbstractSettingsTile> tiles) => [
  for (final tile in tiles)
    _CompactSettingsTileAdapter(key: tile.key, tile: tile),
];

void showLanguageSettings(OverlayDialogManager dialogManager) async {
  try {
    final langs = json.decode(await bind.mainGetLangs()) as List<dynamic>;
    var lang = bind.mainGetLocalOption(key: kCommConfKeyLang);
    dialogManager.show(
      (setState, close, context) {
        setLang(v) async {
          if (lang != v) {
            setState(() {
              lang = v;
            });
            await bind.mainSetLocalOption(key: kCommConfKeyLang, value: v);
            HomePage.homeKey.currentState?.refreshPages();
            Future.delayed(Duration(milliseconds: 200), close);
          }
        }

        final isOptFixed = isOptionFixed(kCommConfKeyLang);
        return CustomAlertDialog(
          content: Column(
            children:
                [
                  getRadio(
                    Text(translate('Default')),
                    defaultOptionLang,
                    lang,
                    isOptFixed ? null : setLang,
                  ),
                  Divider(color: MyTheme.border),
                ] +
                langs.map((e) {
                  final key = e[0] as String;
                  final name = e[1] as String;
                  return getRadio(
                    Text(translate(name)),
                    key,
                    lang,
                    isOptFixed ? null : setLang,
                  );
                }).toList(),
          ),
        );
      },
      backDismiss: true,
      clickMaskDismiss: true,
    );
  } catch (e) {
    //
  }
}

void showThemeSettings(OverlayDialogManager dialogManager) async {
  var themeMode = MyTheme.getThemeModePreference();

  dialogManager.show(
    (setState, close, context) {
      setTheme(v) {
        if (themeMode != v) {
          setState(() {
            themeMode = v;
          });
          MyTheme.changeDarkMode(themeMode);
          Future.delayed(Duration(milliseconds: 200), close);
        }
      }

      final isOptFixed = isOptionFixed(kCommConfKeyTheme);
      return CustomAlertDialog(
        content: Column(
          children: [
            getRadio(
              Text(translate('Light')),
              ThemeMode.light,
              themeMode,
              isOptFixed ? null : setTheme,
            ),
            getRadio(
              Text(translate('Dark')),
              ThemeMode.dark,
              themeMode,
              isOptFixed ? null : setTheme,
            ),
            getRadio(
              Text(translate('Follow System')),
              ThemeMode.system,
              themeMode,
              isOptFixed ? null : setTheme,
            ),
          ],
        ),
      );
    },
    backDismiss: true,
    clickMaskDismiss: true,
  );
}

void showAbout(OverlayDialogManager dialogManager) {
  dialogManager.show(
    (setState, close, context) {
      final appName = bind.mainGetAppNameSync();
      return CustomAlertDialog(
        title: Text('${translate('About')} $appName'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FutureBuilder<String>(
                future: bind.mainGetVersion(),
                initialData: version,
                builder: (context, snapshot) {
                  final appVersion = (snapshot.data ?? version);
                  return Text('Version: $appVersion');
                },
              ),
              InkWell(
                onTap: () async {
                  await launchUrl(Uri.parse(kRustAdminSourceUrl));
                },
                child: Padding(
                  padding: EdgeInsets.only(top: 12, bottom: 8),
                  child: Text(
                    'Source code',
                    style: TextStyle(decoration: TextDecoration.underline),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [],
      );
    },
    clickMaskDismiss: true,
    backDismiss: true,
  );
}

class ScanButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.qr_code_scanner),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (BuildContext context) => ScanPage()),
        );
      },
    );
  }
}

class _DisplayPage extends StatefulWidget {
  const _DisplayPage();

  @override
  State<_DisplayPage> createState() => __DisplayPageState();
}

class __DisplayPageState extends State<_DisplayPage> {
  @override
  Widget build(BuildContext context) {
    final Map codecsJson = jsonDecode(bind.mainSupportedHwdecodings());
    final av1 = codecsJson['av1'] ?? false;
    final h264 = codecsJson['h264'] ?? false;
    final h265 = codecsJson['h265'] ?? false;
    var codecList = [
      _RadioEntry('Auto', 'auto'),
      _RadioEntry('VP8', 'vp8'),
      _RadioEntry('VP9', 'vp9'),
      _RadioEntry('AV1', 'av1'),
      _RadioEntry('AV1 HW', 'av1-hw', enabled: av1),
      _RadioEntry('H264', 'h264', enabled: h264),
      _RadioEntry('H264 HQ', 'h264-hq', enabled: h264),
      _RadioEntry('H265', 'h265', enabled: h265),
      _RadioEntry('H265 HQ', 'h265-hq', enabled: h265),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back_ios),
        ),
        title: Text(translate('Display Settings')),
        centerTitle: true,
      ),
      body: _CompactDisplaySettings(codecList: codecList),
    );
  }

}

class _CompactDisplaySettings extends StatefulWidget {
  const _CompactDisplaySettings({required this.codecList});

  final List<_RadioEntry> codecList;

  @override
  State<_CompactDisplaySettings> createState() =>
      _CompactDisplaySettingsState();
}

class _CompactDisplaySettingsState extends State<_CompactDisplaySettings> {
  late final List<StreamSubscription<dynamic>> _subscriptions;

  @override
  void initState() {
    super.initState();
    void refresh(_) {
      if (mounted) setState(() {});
    }

    _subscriptions = [
      remoteDisplaySettings
          .watchKeys(RemoteDisplaySettingsRegistry.all)
          .listen(refresh),
      remoteToolbarSettings.watch().listen(refresh),
      qualityMonitorSettings.watch().listen(refresh),
      mobileRemoteDefaults.watch().listen(refresh),
    ];
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  List<MobileRemoteToggleItem> _runtimeDisplayToggles() {
    if (!isAndroid) return const [];

    final toggles = <MobileRemoteToggleItem>[
      MobileRemoteToggleItem(
        id: 'display-enable-hardware-codec',
        value: option2bool(
          kOptionEnableHwcodec,
          bind.mainGetOptionSync(key: kOptionEnableHwcodec),
        ),
        child: Text(translate('Enable hardware codec')),
        dividerBefore: true,
        onChanged: isOptionFixed(kOptionEnableHwcodec)
            ? null
            : (value) {
                if (value == null) return;
                unawaited(mainSetBoolOption(kOptionEnableHwcodec, value));
              },
      ),
    ];
    if (bind.mainHasGpuTextureRender()) {
      toggles.add(
        MobileRemoteToggleItem(
          id: 'display-use-texture-rendering',
          value: bind.mainGetUseTextureRender(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Use texture rendering')),
              Text(
                translate('texture_render_tip'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          onChanged: (value) {
            if (value == null) return;
            unawaited(
              mobileRemoteLocalSettings.write(
                MobileRemoteSettingsRegistry.textureRender,
                value,
              ),
            );
          },
        ),
      );
    }

    final hideSecuritySettings =
        bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) == 'Y';
    if (!bind.isDisableSettings() &&
        !bind.isOutgoingOnly() &&
        !hideSecuritySettings) {
      toggles.add(
        MobileRemoteToggleItem(
          id: 'display-adaptive-bitrate',
          value: option2bool(
            kOptionEnableAbr,
            bind.mainGetOptionSync(key: kOptionEnableAbr),
          ),
          child: Text(translate('Adaptive bitrate')),
          onChanged: isOptionFixed(kOptionEnableAbr)
              ? null
              : (value) {
                  if (value == null) return;
                  unawaited(mainSetBoolOption(kOptionEnableAbr, value));
                },
        ),
      );
    }
    return toggles;
  }

  MobileRemoteRadioItem _radioItem(
    String value,
    String label,
    Future<void> Function(String)? onChanged, {
    bool enabled = true,
  }) {
    return MobileRemoteRadioItem(
      value: value,
      child: Text(translate(label)),
      onChanged: !enabled || onChanged == null
          ? null
          : (selected) {
              if (selected != null) unawaited(onChanged(selected));
            },
    );
  }

  Future<void> _persistQualityMonitorFadeSettings(
    QualityMonitorFadeSettings settings,
  ) => qualityMonitorSettings.write(settings);

  @override
  Widget build(BuildContext context) {
    final viewStyle = remoteDisplaySettings.read(
      RemoteDisplaySettingsRegistry.viewStyle,
    );
    final scrollStyle = remoteToolbarSettings.readSetting(
      RemoteToolbarSettingsRegistry.scrollStyle,
    );
    final imageQuality = remoteDisplaySettings.read(
      RemoteDisplaySettingsRegistry.imageQuality,
    );
    final codec = remoteDisplaySettings.read(
      RemoteDisplaySettingsRegistry.codecPreference,
    );
    var edgeThickness = remoteToolbarSettings
        .readSetting(RemoteToolbarSettingsRegistry.edgeThickness)
        .toDouble();
    var cursorInertiaSettings = MobileCursorInertiaSettings(
      durationMs: mobileRemoteDefaults.read(
        MobileRemoteSettingsRegistry.cursorInertiaDefault,
      ),
    );
    final trackpadSpeed = SimpleWrapper(
      remoteToolbarSettings.readSetting(
        RemoteToolbarSettingsRegistry.trackpadSpeed,
      ),
    );
    var toolbarSettings = MobileRemoteToolbarTransparencySettings(
      overlapOpacityPercent: mobileRemoteDefaults.read(
        MobileRemoteSettingsRegistry.toolbarOverlapDefault,
      ),
    );
    var activeQualityMonitorSettings = qualityMonitorSettings.read();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MobileRemoteOptionsContent(
        showTitle: false,
        toggles: _runtimeDisplayToggles(),
        radioSections: [
          MobileRemoteRadioSection(
            id: 'default-view-style',
            value: viewStyle,
            heading: Text(translate('Default View Style')),
            items: [
              _radioItem(
                kRemoteViewStyleOriginal,
                'Scale original',
                isOptionFixed(kOptionViewStyle)
                    ? null
                    : (value) => remoteDisplaySettings.write(
                        RemoteDisplaySettingsRegistry.viewStyle,
                        value,
                      ),
              ),
              _radioItem(
                kRemoteViewStyleAdaptive,
                'Scale adaptive',
                isOptionFixed(kOptionViewStyle)
                    ? null
                    : (value) => remoteDisplaySettings.write(
                        RemoteDisplaySettingsRegistry.viewStyle,
                        value,
                      ),
              ),
            ],
          ),
          MobileRemoteRadioSection(
            id: 'default-screen-scrolling',
            value: scrollStyle,
            heading: Text(translate('Default Screen Scrolling')),
            items: [
              for (final entry in const <(String, String)>[
                (kRemoteScrollStyleAuto, 'ScrollAuto'),
                (kRemoteScrollStyleEdge, 'ScrollEdge'),
                (kRemoteScrollStyleEdgeAcceleration, 'ScrollEdgeAcceleration'),
              ])
                _radioItem(
                  entry.$1,
                  entry.$2,
                  isOptionFixed(kOptionScrollStyle)
                      ? null
                      : (value) => remoteToolbarSettings.write(
                          RemoteToolbarSettingsRegistry.scrollStyle,
                          value,
                        ),
                ),
            ],
            selectionDetailsBuilder: (value) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (value == kRemoteScrollStyleEdge ||
                    value == kRemoteScrollStyleEdgeAcceleration)
                  EdgeThicknessControl(
                    key: const Key('mobile-default-edge-thickness'),
                    value: edgeThickness,
                    onChanged: isOptionFixed(kOptionEdgeScrollEdgeThickness)
                        ? null
                        : (value) {
                            edgeThickness = value;
                            unawaited(
                              remoteToolbarSettings.write(
                                RemoteToolbarSettingsRegistry.edgeThickness,
                                value.round(),
                              ),
                            );
                          },
                  ),
                const SizedBox(height: 8),
                Text(translate('Cursor inertia time')),
                MobileCursorInertiaControl(
                  key: const Key('mobile-default-cursor-inertia'),
                  durationMs: cursorInertiaSettings.durationMs,
                  onChanged: isOptionFixed(kOptionMobileCursorInertiaDurationMs)
                      ? null
                      : (durationMs) {
                          cursorInertiaSettings = cursorInertiaSettings
                              .copyWith(durationMs: durationMs);
                        },
                  onChangeEnd:
                      isOptionFixed(kOptionMobileCursorInertiaDurationMs)
                      ? null
                      : (durationMs) => unawaited(
                          mobileRemoteDefaults.write(
                            MobileRemoteSettingsRegistry.cursorInertiaDefault,
                            durationMs,
                          ),
                        ),
                ),
              ],
            ),
          ),
          MobileRemoteRadioSection(
            id: 'default-trackpad-speed',
            value: '',
            items: const [],
            heading: Text(translate('Default trackpad speed')),
            content: IgnorePointer(
              ignoring: isOptionFixed(kKeyTrackpadSpeed),
              child: Opacity(
                opacity: isOptionFixed(kKeyTrackpadSpeed) ? 0.5 : 1,
                child: TrackpadSpeedWidget(
                  value: trackpadSpeed,
                  onDebouncer: isOptionFixed(kKeyTrackpadSpeed)
                      ? null
                      : (value) => remoteToolbarSettings.write(
                          RemoteToolbarSettingsRegistry.trackpadSpeed,
                          value,
                        ),
                ),
              ),
            ),
          ),
          MobileRemoteRadioSection(
            id: 'overlay-appearance',
            value: '',
            items: const [],
            heading: Text(translate('Overlay appearance')),
            content: MobileOverlayAppearanceControls(
              toolbarTitle: translate('Toolbar'),
              toolbarOpacityLabel: translate('Opacity under cursor'),
              qualityMonitorTitle: translate('Quality monitor'),
              inactiveOpacityLabel: translate('Inactive opacity'),
              fadeDelayLabel: translate('Fade delay'),
              fadeDurationLabel: translate('Fade duration'),
              toolbarSettings: toolbarSettings,
              qualityMonitorSettings: activeQualityMonitorSettings,
              toolbarEnabled: !isOptionFixed(
                kOptionMobileRemoteToolbarOverlapOpacityPercent,
              ),
              qualityMonitorOpacityEnabled: !isOptionFixed(
                kOptionQualityMonitorInactiveOpacityPercent,
              ),
              qualityMonitorDelayEnabled: !isOptionFixed(
                kOptionQualityMonitorDimDelayMs,
              ),
              qualityMonitorDurationEnabled: !isOptionFixed(
                kOptionQualityMonitorDimDurationMs,
              ),
              onToolbarChanged: (settings) => toolbarSettings = settings,
              onToolbarChangeEnd: (settings) {
                toolbarSettings = settings;
                unawaited(
                  mobileRemoteDefaults.write(
                    MobileRemoteSettingsRegistry.toolbarOverlapDefault,
                    settings.overlapOpacityPercent,
                  ),
                );
              },
              onQualityMonitorChanged: (settings) =>
                  activeQualityMonitorSettings = settings,
              onQualityMonitorChangeEnd: (settings) {
                activeQualityMonitorSettings = settings;
                unawaited(_persistQualityMonitorFadeSettings(settings));
              },
            ),
          ),
          MobileRemoteRadioSection(
            id: 'default-image-quality',
            value: imageQuality,
            heading: Text(translate('Default Image Quality')),
            items: [
              for (final entry in const <(String, String)>[
                (kRemoteImageQualityBest, 'Good image quality'),
                (kRemoteImageQualityBalanced, 'Balanced'),
                (kRemoteImageQualityLow, 'Optimize reaction time'),
                (kRemoteImageQualityCustom, 'Custom'),
              ])
                _radioItem(
                  entry.$1,
                  entry.$2,
                  isOptionFixed(kOptionImageQuality)
                      ? null
                      : (value) => remoteDisplaySettings.write(
                          RemoteDisplaySettingsRegistry.imageQuality,
                          value,
                        ),
                ),
            ],
            selectionDetailsBuilder: (value) =>
                value == kRemoteImageQualityCustom
                ? customImageQualitySetting()
                : const SizedBox.shrink(),
          ),
          MobileRemoteRadioSection(
            id: 'default-codec',
            value: codec,
            heading: Text(translate('Default Codec')),
            items: [
              for (final entry in widget.codecList)
                _radioItem(
                  entry.value,
                  entry.label,
                  isOptionFixed(kOptionCodecPreference)
                      ? null
                      : (value) => remoteDisplaySettings.write(
                          RemoteDisplaySettingsRegistry.codecPreference,
                          value,
                        ),
                  enabled: entry.enabled,
                ),
            ],
          ),
          MobileRemoteRadioSection(
            id: 'other-default-options',
            value: '',
            items: const [],
            heading: Text(translate('Other Default Options')),
            content: _CompactDefaultOptions(options: otherDefaultSettings()),
          ),
        ],
      ),
    );
  }
}

class _CompactDefaultOptions extends StatefulWidget {
  const _CompactDefaultOptions({required this.options});

  final List<UserDefaultToggleSetting> options;

  @override
  State<_CompactDefaultOptions> createState() => _CompactDefaultOptionsState();
}

class _CompactDefaultOptionsState extends State<_CompactDefaultOptions> {
  late final Map<String, bool> _values = _readValues();
  late final StreamSubscription<String> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = remoteDisplaySettings.watchKeys(widget.options).listen((key) {
      if (!mounted) return;
      final setting = widget.options.firstWhere((option) => option.key == key);
      setState(() => _values[key] = remoteDisplaySettings.read(setting));
    });
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Map<String, bool> _readValues() => {
    for (final option in widget.options)
      option.key: remoteDisplaySettings.read(option),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in widget.options)
          SwitchListTile.adaptive(
            key: Key('mobile-default-option-${option.key}'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: _values[option.key] ?? false,
            title: Text(translate(option.label)),
            onChanged: isOptionFixed(option.key)
                ? null
                : (value) {
                    setState(() => _values[option.key] = value);
                    unawaited(
                      remoteDisplaySettings.write(option, value),
                    );
                  },
          ),
      ],
    );
  }
}

class _ManageTrustedDevices extends StatefulWidget {
  const _ManageTrustedDevices();

  @override
  State<_ManageTrustedDevices> createState() => __ManageTrustedDevicesState();
}

class __ManageTrustedDevicesState extends State<_ManageTrustedDevices> {
  RxList<TrustedDevice> trustedDevices = RxList.empty(growable: true);
  RxList<Uint8List> selectedDevices = RxList.empty();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('Manage trusted devices')),
        centerTitle: true,
        actions: [
          Obx(
            () => IconButton(
              icon: Icon(Icons.delete, color: Colors.white),
              onPressed: selectedDevices.isEmpty
                  ? null
                  : () {
                      confrimDeleteTrustedDevicesDialog(
                        trustedDevices,
                        selectedDevices,
                      );
                    },
            ),
          ),
        ],
      ),
      body: FutureBuilder(
        future: TrustedDevice.get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final devices = snapshot.data as List<TrustedDevice>;
          trustedDevices = devices.obs;
          return trustedDevicesTable(trustedDevices, selectedDevices);
        },
      ),
    );
  }
}

class _ManagePairedViewers extends StatefulWidget {
  const _ManagePairedViewers();

  @override
  State<_ManagePairedViewers> createState() => __ManagePairedViewersState();
}

class __ManagePairedViewersState extends State<_ManagePairedViewers> {
  RxList<PairedViewer> pairedViewers = RxList.empty(growable: true);
  RxList<Uint8List> selectedViewers = RxList.empty();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('Manage paired viewers')),
        centerTitle: true,
        actions: [
          Obx(
            () => IconButton(
              icon: Icon(Icons.delete, color: Colors.white),
              onPressed: selectedViewers.isEmpty
                  ? null
                  : () {
                      confrimDeletePairedViewersDialog(
                        pairedViewers,
                        selectedViewers,
                      );
                    },
            ),
          ),
        ],
      ),
      body: FutureBuilder(
        future: PairedViewer.get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final viewers = snapshot.data as List<PairedViewer>;
          pairedViewers = viewers.obs;
          return pairedViewersTable(pairedViewers, selectedViewers);
        },
      ),
    );
  }
}

class _RadioEntry {
  final String label;
  final String value;
  final bool enabled;
  _RadioEntry(this.label, this.value, {this.enabled = true});
}

typedef _RadioEntryGetter = String Function();
typedef _RadioEntrySetter = Future<void> Function(String);

SettingsTile _getPopupDialogRadioEntry({
  Key? key,
  required String title,
  required List<_RadioEntry> list,
  required _RadioEntryGetter getter,
  required _RadioEntrySetter? asyncSetter,
  Widget? tail,
  RxBool? showTail,
  String? notCloseValue,
}) {
  RxString groupValue = ''.obs;
  RxString valueText = ''.obs;

  init() {
    groupValue.value = getter();
    final e = list.firstWhereOrNull((e) => e.value == groupValue.value);
    if (e != null) {
      valueText.value = e.label;
    }
  }

  init();

  void showDialog() async {
    gFFI.dialogManager.show(
      (setState, close, context) {
        final onChanged = asyncSetter == null
            ? null
            : (String? value) async {
                if (value == null) return;
                final entry = list.firstWhereOrNull((e) => e.value == value);
                if (entry != null && !entry.enabled) {
                  showCodecUnavailableDialog(gFFI.dialogManager, entry.label);
                  return;
                }
                await asyncSetter(value);
                init();
                if (value != notCloseValue) {
                  close();
                }
              };

        return CustomAlertDialog(
          content: Obx(
            () => Column(
              children: [
                ...list
                    .map(
                      (e) => getRadio(
                        Text(
                          translate(e.label),
                          style: TextStyle(
                            color: disabledTextColor(context, e.enabled),
                          ),
                        ),
                        e.value,
                        groupValue.value,
                        onChanged,
                      ),
                    )
                    .toList(),
                Offstage(
                  offstage:
                      !(tail != null &&
                          showTail != null &&
                          showTail.value == true),
                  child: tail,
                ),
              ],
            ),
          ),
        );
      },
      backDismiss: true,
      clickMaskDismiss: true,
    );
  }

  return SettingsTile(
    key: key,
    title: Text(translate(title)),
    onPressed: asyncSetter == null ? null : (context) => showDialog(),
    value: Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Obx(() => Text(translate(valueText.value))),
    ),
  );
}
