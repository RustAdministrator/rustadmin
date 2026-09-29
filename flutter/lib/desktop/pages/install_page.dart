import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/content_sized_window.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:window_manager/window_manager.dart';

class InstallPage extends StatefulWidget {
  final bool isUpgrade;
  final ContentSizedWindowController? contentSizedWindowController;

  const InstallPage({
    Key? key,
    this.isUpgrade = false,
    this.contentSizedWindowController,
  }) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState(
    isUpgrade: isUpgrade,
    contentSizedWindowController: contentSizedWindowController,
  );
}

class _InstallPageState extends State<InstallPage> {
  final bool isUpgrade;
  final ContentSizedWindowController? contentSizedWindowController;
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState({
    required this.isUpgrade,
    this.contentSizedWindowController,
  }) {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(
      TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
          isUpgrade: isUpgrade,
          contentSizedWindowController: contentSizedWindowController,
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.background,
          body: DesktopTab(
            controller: tabController,
            persistWindowGeometry: false,
          ),
        ),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  final bool isUpgrade;
  final ContentSizedWindowController? contentSizedWindowController;

  const _InstallPageBody({
    Key? key,
    required this.isUpgrade,
    this.contentSizedWindowController,
  }) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = false.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    printer.value = installOptions['PRINTER'] == '1';
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  InkWell Option(RxBool option, {String label = ''}) {
    return InkWell(
      // todo mouseCursor: "SystemMouseCursors.forbidden" or no cursor on btnEnabled == false
      borderRadius: BorderRadius.circular(4.0),
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Row(
        children: [
          Obx(
            () => Checkbox(
              visualDensity: VisualDensity(horizontal: -4, vertical: -4),
              value: option.value,
              onChanged: (v) =>
                  btnEnabled.value ? option.value = !option.value : null,
            ).marginOnly(right: 8),
          ),
          Expanded(child: Text(translate(label))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double em = 13;
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    return Scaffold(
      backgroundColor: null,
      body: ContentSizedWindow(
        controller: widget.contentSizedWindowController,
        padding: EdgeInsets.fromLTRB(4 * em, 3 * em, 4 * em, 4 * em),
        additionalWindowHeight: kUseCompatibleUiMode
            ? 0
            : kDesktopRemoteTabBarHeight,
        child: Column(
          key: const ValueKey('install-body-column'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              translate(widget.isUpgrade ? 'Upgrade' : 'Installation'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final pathField = TextField(
                  controller: controller,
                  readOnly: true,
                  decoration: InputDecoration(
                    contentPadding: EdgeInsets.all(0.75 * em),
                  ),
                ).workaroundFreezeLinuxMint().marginOnly(right: 10);
                final changePathButton = Obx(
                  () => OutlinedButton.icon(
                    icon: MyTheme.desktopButtonIcon(
                      Icon(Icons.folder_outlined, size: 16),
                    ),
                    onPressed: btnEnabled.value && !widget.isUpgrade
                        ? selectInstallPath
                        : null,
                    label: Text(translate('Change Path'), softWrap: true),
                  ),
                );
                final pathControls = LayoutBuilder(
                  builder: (context, pathConstraints) =>
                      pathConstraints.maxWidth < 360
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            pathField,
                            Align(
                              alignment: Alignment.centerLeft,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: pathConstraints.maxWidth,
                                ),
                                child: changePathButton,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: pathField),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: pathConstraints.maxWidth * 0.45,
                              ),
                              child: changePathButton,
                            ),
                          ],
                        ),
                );
                return (constraints.maxWidth < 560
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${translate('Installation Path')}:',
                              ).marginOnly(bottom: 8),
                              pathControls,
                            ],
                          )
                        : Row(
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: constraints.maxWidth * 0.35,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Text(
                                    '${translate('Installation Path')}:',
                                    softWrap: true,
                                  ),
                                ),
                              ),
                              Expanded(child: pathControls),
                            ],
                          ))
                    .marginSymmetric(vertical: 2 * em);
              },
            ),
            if (!widget.isUpgrade)
              Option(
                startmenu,
                label: 'Create start menu shortcuts',
              ).marginOnly(bottom: 7),
            if (!widget.isUpgrade)
              Option(
                desktopicon,
                label: 'Create desktop icon',
              ).marginOnly(bottom: 7),
            if (!widget.isUpgrade)
              Option(printer, label: 'Install {$appName} Printer'),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDarkTheme
                    ? Color.fromARGB(135, 87, 87, 90)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(4.0),
                border: Border.all(color: Colors.grey),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 32,
                  ).marginOnly(right: 16),
                  Expanded(child: Text(translate('agreement_tip'))),
                ],
              ),
            ).marginSymmetric(vertical: 2 * em),
            Column(
              key: const ValueKey('install-actions'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Reserve progress row height so the button row does not jump.
                SizedBox(
                  height: 16,
                  child: Obx(
                    () => showProgress.value
                        ? const Align(
                            alignment: Alignment.topCenter,
                            child: LinearProgressIndicator(),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final installButton = Obx(
                      () => ElevatedButton.icon(
                        icon: MyTheme.desktopButtonIcon(
                          Icon(Icons.done_rounded, size: 16),
                        ),
                        label: Text(
                          translate(
                            widget.isUpgrade ? 'Upgrade' : 'Accept and Install',
                          ),
                          softWrap: true,
                        ),
                        onPressed: btnEnabled.value ? install : null,
                      ),
                    );
                    final runWithoutInstall = Obx(
                      () => OutlinedButton.icon(
                        icon: MyTheme.desktopButtonIcon(
                          Icon(Icons.screen_share_outlined, size: 16),
                        ),
                        label: Text(
                          translate('Run without install'),
                          softWrap: true,
                        ),
                        onPressed: btnEnabled.value
                            ? () => bind.installRunWithoutInstall()
                            : null,
                      ),
                    );
                    final cancelButton = Obx(
                      () => OutlinedButton.icon(
                        icon: MyTheme.desktopButtonIcon(
                          Icon(Icons.close_rounded, size: 16),
                        ),
                        label: Text(translate('Cancel'), softWrap: true),
                        onPressed: btnEnabled.value
                            ? () => windowManager.close()
                            : null,
                      ),
                    );
                    Widget constrainButton(Widget button) {
                      return ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: button,
                      );
                    }

                    return Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        constrainButton(installButton),
                        if (!widget.isUpgrade &&
                            !bind.installShowRunWithoutInstall())
                          constrainButton(runWithoutInstall),
                        constrainButton(cancelButton),
                      ],
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void install() {
    do_install() {
      btnEnabled.value = false;
      showProgress.value = true;
      String args = '';
      if (startmenu.value) args += ' startmenu';
      if (desktopicon.value) args += ' desktopicon';
      if (printer.value) args += ' printer';
      bind.installInstallMe(options: args, path: controller.text);
    }

    do_install();
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.getDirectoryPath(
      initialDirectory: controller.text,
    );
    if (install_path != null) {
      controller.text = join(install_path, await bind.mainGetAppName());
    }
  }
}
