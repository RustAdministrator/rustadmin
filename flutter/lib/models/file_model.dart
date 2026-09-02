import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/session_peer_settings.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/utils/event_loop.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/web_unique.dart';

import '../consts.dart';
import 'model.dart';
import 'platform_model.dart';
import 'session_event.dart';

enum SortBy {
  name,
  type,
  modified,
  size;

  @override
  String toString() {
    final str = this.name.toString();
    return "${str[0].toUpperCase()}${str.substring(1)}";
  }
}

class JobID {
  int _count = 0;
  int next() {
    try {
      if (!isWeb) {
        String v = bind.mainGetCommonSync(key: 'transfer-job-id');
        return int.parse(v);
      }
    } catch (e) {
      debugPrint("Failed to get transfer job id: $e");
    }
    // Finally increase the count if on the web or if failed to get the id.
    _count++;
    return _count;
  }
}

typedef GetSessionID = SessionID Function();
typedef GetDialogManager = OverlayDialogManager? Function();

class FileModel {
  final WeakReference<FFI> parent;
  // late final String sessionId;
  late final FileFetcher fileFetcher;
  late final JobController jobController;

  late final FileController localController;
  late final FileController remoteController;

  late final GetSessionID getSessionID;
  late final GetDialogManager getDialogManager;
  SessionID get sessionId => getSessionID();
  late final FileDialogEventLoop evtLoop;

  FileModel(this.parent) {
    getSessionID = () => parent.target!.sessionId;
    getDialogManager = () => parent.target?.dialogManager;
    fileFetcher = FileFetcher(getSessionID);
    jobController = JobController(getSessionID, getDialogManager);
    localController = FileController(
        isLocal: true,
        getSessionID: getSessionID,
        rootState: parent,
        jobController: jobController,
        fileFetcher: fileFetcher,
        getOtherSideDirectoryData: () => remoteController.directoryData());
    remoteController = FileController(
        isLocal: false,
        getSessionID: getSessionID,
        rootState: parent,
        jobController: jobController,
        fileFetcher: fileFetcher,
        getOtherSideDirectoryData: () => localController.directoryData());
    evtLoop = FileDialogEventLoop();
  }

  Future<void> onReady() async {
    await evtLoop.onReady();
    if (!isWeb) await localController.onReady();
    await remoteController.onReady();
  }

  Future<void> close() async {
    await evtLoop.close();
    parent.target?.dialogManager.dismissAll();
    await localController.close();
    await remoteController.close();
  }

  Future<void> refreshAll() async {
    if (!isWeb) await localController.refresh();
    await remoteController.refresh();
  }

  void receiveFileDirectoryEvent(FileDirectorySessionEvent event) {
    if (!event.isLocal) {
      // init remote home, the remote connection will send one dir event when established. TODO opt
      remoteController.initDirAndHome(event.directory);
    }
    fileFetcher.completeDirectory(event.directory);
  }

  void receiveEmptyDirectoriesEvent(EmptyDirectoriesSessionEvent event) {
    fileFetcher.completeEmptyDirectories(event);
  }

  // This method fixes a deadlock that occurred when the previous code directly
  // called jobController.jobErrorEvent() in the job_error event handler.
  //
  // The problem with directly calling jobController.jobErrorEvent():
  //   1. fetchDirectoryRecursiveToRemove(jobID) registers readRecursiveTasks[jobID]
  //      and waits for completion
  //   2. If the remote has no permission (or some other errors), it returns a FileTransferError
  //   3. The error triggers job_error event, which called jobController.jobErrorEvent()
  //   4. jobController.jobErrorEvent() calls getJob(jobID) to find the job in jobTable
  //   5. But addDeleteDirJob() is called AFTER fetchDirectoryRecursiveToRemove(),
  //      so the job doesn't exist yet in jobTable
  //   6. Result: jobController.jobErrorEvent() does nothing useful, and
  //      readRecursiveTasks[jobID] never completes, causing a 2s timeout
  //
  // Solution: Before calling jobController.jobErrorEvent(), we first check if there's
  // a pending readRecursiveTasks with this ID and complete it with the error.
  void handleJobErrorEvent(FileJobErrorSessionEvent event) {
    fileFetcher.tryCompleteRecursiveTaskWithError(event.id, event.error);
    jobController.jobErrorEvent(event);
  }

  Future<void> postOverrideFileConfirmEvent(
      FileOverrideConfirmSessionEvent event) async {
    evtLoop.pushEvent(_FileDialogEvent(
        WeakReference(this), FileDialogType.overwrite, event));
  }

  Future<void> overrideFileConfirmEvent(FileOverrideConfirmSessionEvent event,
      {bool? overrideConfirm, bool skip = false}) async {
    // If `skip == true`, it means to skip this file without showing dialog.
    // Because `resp` may be null after the user operation or the last remembered operation,
    // and we should distinguish them.
    final resp = overrideConfirm ??
        (!skip
            ? await showFileConfirmDialog(translate("Overwrite"),
                event.readPath, true, event.isIdentical)
            : null);
    final id = event.id;
    if (false == resp) {
      final jobIndex = jobController.getJob(id);
      if (jobIndex != -1) {
        await jobController.cancelJob(id);
        final job = jobController.jobTable[jobIndex];
        job.state = JobState.done;
        jobController.jobTable.refresh();
      }
    } else {
      var need_override = false;
      if (resp == null) {
        // skip
        need_override = false;
      } else {
        // overwrite
        need_override = true;
      }
      // Update the loop config.
      if (fileConfirmCheckboxRemember) {
        evtLoop.setSkip(!need_override);
      }
      await bind.sessionSetConfirmOverrideFile(
          sessionId: sessionId,
          actId: id,
          fileNum: event.fileNum,
          needOverride: need_override,
          remember: fileConfirmCheckboxRemember,
          isUpload: event.isUpload);
    }
    // Update the loop config.
    if (fileConfirmCheckboxRemember) {
      evtLoop.setOverrideConfirm(resp);
    }
  }

  bool fileConfirmCheckboxRemember = false;

  Future<bool?> showFileConfirmDialog(
      String title, String content, bool showCheckbox, bool isIdentical) async {
    fileConfirmCheckboxRemember = false;
    return await parent.target?.dialogManager.show<bool?>(
        (setState, Function(bool? v) close, context) {
      cancel() => close(false);
      submit() => close(true);
      return CustomAlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_rounded, color: Colors.red),
            Text(title).paddingOnly(
              left: 10,
            ),
          ],
        ),
        contentBoxConstraints:
            BoxConstraints(minHeight: 100, minWidth: 400, maxWidth: 400),
        content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(translate("This file exists, skip or overwrite this file?"),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 5),
              Text(content),
              Offstage(
                offstage: !isIdentical,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    Text(translate("identical_file_tip"),
                        style: const TextStyle(fontWeight: FontWeight.w500))
                  ],
                ),
              ),
              showCheckbox
                  ? CheckboxListTile(
                      contentPadding: const EdgeInsets.all(0),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        translate("Do this for all conflicts"),
                      ),
                      value: fileConfirmCheckboxRemember,
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => fileConfirmCheckboxRemember = v);
                      },
                    )
                  : const SizedBox.shrink()
            ]),
        actions: [
          dialogButton(
            "Cancel",
            icon: Icon(Icons.close_rounded),
            onPressed: cancel,
            isOutline: true,
          ),
          dialogButton(
            "Skip",
            icon: Icon(Icons.navigate_next_rounded),
            onPressed: () => close(null),
            isOutline: true,
          ),
          dialogButton(
            "OK",
            icon: Icon(Icons.done_rounded),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, useAnimation: false);
  }

  void onSelectedFileEvent(WebSelectedFileSessionEvent event) {
    localController.selectedItems.clear();

    final entry = Entry.fromSessionValue(event.file)..path = event.file.name;
    final otherSideData = remoteController.directoryData();
    final toPath = otherSideData.directory.path;
    final isWindows = otherSideData.options.isWindows;
    final showHidden = otherSideData.options.showHidden;
    final jobID = jobController.addTransferJob(entry, false);
    webSendLocalFiles(
      handleIndex: event.handleIndex,
      actId: jobID,
      path: entry.path,
      to: PathUtil.join(toPath, entry.name, isWindows),
      fileNum: 0,
      includeHidden: showHidden,
      isRemote: false,
    );
  }

  void sendEmptyDirectoriesEvent(WebEmptyDirectoriesSessionEvent event) {
    final otherSideData = remoteController.directoryData();
    final toPath = otherSideData.directory.path;
    final isPeerWindows = otherSideData.options.isWindows;

    final isLocalWindows = isWindows || isWebOnWindows;
    for (var dir in event.directories) {
      if (isLocalWindows != isPeerWindows) {
        dir = PathUtil.convert(dir, isLocalWindows, isPeerWindows);
      }
      var peerPath = PathUtil.join(toPath, dir, isPeerWindows);
      remoteController.createDirWithRemote(peerPath, true);
    }
  }
}

class DirectoryData {
  final DirectoryOptions options;
  final FileDirectory directory;
  DirectoryData(this.directory, this.options);
}

class FileController {
  final bool isLocal;
  final GetSessionID getSessionID;
  SessionID get sessionId => getSessionID();

  final FileFetcher fileFetcher;

  final options = DirectoryOptions().obs;
  final directory = FileDirectory().obs;

  final history = RxList<String>.empty(growable: true);
  final sortBy = SortBy.name.obs;
  var sortAscending = true;
  final JobController jobController;
  final WeakReference<FFI> rootState;

  final DirectoryData Function() getOtherSideDirectoryData;
  late final SelectedItems selectedItems = SelectedItems(isLocal: isLocal);

  FileController(
      {required this.isLocal,
      required this.getSessionID,
      required this.rootState,
      required this.jobController,
      required this.fileFetcher,
      required this.getOtherSideDirectoryData});

  String get homePath => options.value.home;
  void set homePath(String path) => options.value.home = path;
  OverlayDialogManager? get dialogManager => rootState.target?.dialogManager;

  String get shortPath {
    final dirPath = directory.value.path;
    if (dirPath.startsWith(homePath)) {
      var path = dirPath.replaceFirst(homePath, "");
      if (path.isEmpty) return "";
      if (path[0] == "/" || path[0] == "\\") {
        // remove more '/' or '\'
        path = path.replaceFirst(path[0], "");
      }
      return path;
    } else {
      return dirPath.replaceFirst(homePath, "");
    }
  }

  DirectoryData directoryData() {
    return DirectoryData(directory.value, options.value);
  }

  Future<void> onReady() async {
    final settings = SessionPeerSettingsRepository.forSession(sessionId);
    if (isLocal) {
      options.value.home = await bind.mainGetHomeDir();
    }
    final showHiddenSetting = isLocal
        ? SessionPeerSettingsRegistry.localShowHidden
        : SessionPeerSettingsRegistry.remoteShowHidden;
    options.value.showHidden = await settings.readPeer(showHiddenSetting);
    options.value.isWindows = isLocal
        ? isWindows
        : rootState.target?.ffiModel.pi.platform == kPeerPlatformWindows;

    await Future.delayed(Duration(milliseconds: 100));

    final directorySetting = isLocal
        ? SessionPeerSettingsRegistry.localDirectory
        : SessionPeerSettingsRegistry.remoteDirectory;
    final savedDir = await settings.readPeer(directorySetting);
    Future<bool> tryOpenReadyDirs() async {
      final dirs = <String>{
        if (directory.value.path.isNotEmpty) directory.value.path,
        if (savedDir.isNotEmpty) savedDir,
        options.value.home,
      };
      for (final dir in dirs) {
        if (await _openDirectoryPath(dir, isBack: true)) {
          return true;
        }
      }
      return false;
    }

    var opened = await tryOpenReadyDirs();

    await Future.delayed(Duration(seconds: 1));

    if (!opened) {
      // The peer may become ready during the reconnect delay, so retry the
      // same candidates instead of only retrying the default home directory.
      await tryOpenReadyDirs();
    }
  }

  Future<void> close() async {
    final settings = SessionPeerSettingsRepository.forSession(sessionId);
    await settings.write(
      isLocal
          ? SessionPeerSettingsRegistry.localDirectory
          : SessionPeerSettingsRegistry.remoteDirectory,
      directory.value.path,
    );
    await settings.write(
      isLocal
          ? SessionPeerSettingsRegistry.localShowHidden
          : SessionPeerSettingsRegistry.remoteShowHidden,
      options.value.showHidden,
    );
    directory.value.clear();
    options.value.clear();
  }

  void toggleShowHidden({bool? showHidden}) {
    options.value.showHidden = showHidden ?? !options.value.showHidden;
    refresh();
  }

  void changeSortStyle(SortBy sort, {bool? isLocal, bool ascending = true}) {
    sortBy.value = sort;
    sortAscending = ascending;
    directory.update((dir) {
      dir?.changeSortStyle(sort, ascending: ascending);
    });
  }

  Future<bool> refresh() async {
    // "." can be both a refresh command and a real remote directory path.
    // Refresh must bypass openDirectory's command dispatch to avoid recursion.
    return await _openDirectoryPath(directory.value.path, isBack: true);
  }

  Future<bool> openDirectory(String path, {bool isBack = false}) async {
    if (!isBack && path == ".") {
      return await refresh();
    }
    if (!isBack && path == "..") {
      return await _goToParentDirectory(isBack: isBack);
    }
    return await _openDirectoryPath(path, isBack: isBack);
  }

  Future<bool> _openDirectoryPath(String path, {bool isBack = false}) async {
    if (!isBack) {
      pushHistory();
    }
    final showHidden = options.value.showHidden;
    final isWindows = options.value.isWindows;
    // process /C:\ -> C:\ on Windows
    if (isWindows && path.length > 1 && path[0] == '/') {
      path = path.substring(1);
      if (path[path.length - 1] != '\\') {
        path = "$path\\";
      }
    }
    try {
      final fd = await fileFetcher.fetchDirectory(path, isLocal, showHidden);
      fd.format(isWindows, sort: sortBy.value);
      directory.value = fd;
      return true;
    } catch (e) {
      debugPrint("Failed to openDirectory $path: $e");
      return false;
    }
  }

  void pushHistory() {
    if (history.isNotEmpty && history.last == directory.value.path) {
      return;
    }
    history.add(directory.value.path);
  }

  void goToHomeDirectory() {
    if (isLocal) {
      openDirectory(homePath);
      return;
    }
    homePath = "";
    openDirectory(homePath);
  }

  void goBack() {
    if (history.isEmpty) return;
    final path = history.removeAt(history.length - 1);
    if (path.isEmpty) return;
    if (directory.value.path == path) {
      goBack();
      return;
    }
    unawaited(_openDirectoryPath(path, isBack: true).then<void>((_) {}));
  }

  void goToParentDirectory() {
    unawaited(_goToParentDirectory().then<void>((_) {}));
  }

  Future<bool> _goToParentDirectory({bool isBack = false}) async {
    final isWindows = options.value.isWindows;
    final dirPath = directory.value.path;
    var parent = PathUtil.dirname(dirPath, isWindows);
    // specially for C:\, D:\, goto '/'
    if (parent == dirPath && isWindows) {
      return await _openDirectoryPath('/', isBack: isBack);
    }
    return await _openDirectoryPath(parent, isBack: isBack);
  }

  // TODO deprecated this
  void initDirAndHome(SessionFileDirectoryValue value) {
    final fd = FileDirectory.fromSessionValue(value);
    fd.format(options.value.isWindows, sort: sortBy.value);
    if (fd.id > 0) {
      final jobIndex = jobController.getJob(fd.id);
      if (jobIndex != -1) {
        final job = jobController.jobTable[jobIndex];
        var totalSize = 0;
        var fileCount = fd.entries.length;
        for (var element in fd.entries) {
          totalSize += element.size;
        }
        job.totalSize = totalSize;
        job.fileCount = fileCount;
        debugPrint("update receive details: ${fd.path}");
        jobController.jobTable.refresh();
      }
    } else if (options.value.home.isEmpty) {
      options.value.home = fd.path;
      debugPrint("init remote home: ${fd.path}");
      directory.value = fd;
    }
  }

  /// sendFiles from current side (FileController.isLocal) to other side (SelectedItems).
  Future<void> sendFiles(
      SelectedItems items, DirectoryData otherSideData) async {
    /// ignore wrong items side status
    if (items.isLocal != isLocal) {
      return;
    }

    // alias
    final isRemoteToLocal = !isLocal;

    final toPath = otherSideData.directory.path;
    final isWindows = otherSideData.options.isWindows;
    final showHidden = otherSideData.options.showHidden;
    for (var from in items.items) {
      final jobID = jobController.addTransferJob(from, isRemoteToLocal);
      bind.sessionSendFiles(
          sessionId: sessionId,
          actId: jobID,
          path: from.path,
          to: PathUtil.join(toPath, from.name, isWindows),
          fileNum: 0,
          includeHidden: showHidden,
          isRemote: isRemoteToLocal,
          isDir: from.isDirectory);
      debugPrint(
          "path: ${from.path}, toPath: $toPath, to: ${PathUtil.join(toPath, from.name, isWindows)}");
    }

    if (isWeb ||
        (!isLocal &&
            versionCmp(rootState.target!.ffiModel.pi.version, '1.3.3') < 0)) {
      return;
    }

    final List<Entry> entrys = items.items.toList();
    var isRemote = isLocal == true ? true : false;

    await Future.forEach(entrys, (Entry item) async {
      if (!item.isDirectory) {
        return;
      }

      final List<String> paths = [];

      final emptyDirs =
          await fileFetcher.readEmptyDirs(item.path, isLocal, showHidden);

      if (emptyDirs.isEmpty) {
        return;
      } else {
        for (var dir in emptyDirs) {
          paths.add(dir.path);
        }
      }

      final dirs = paths.map((path) {
        return PathUtil.getOtherSidePath(directory.value.path, path,
            options.value.isWindows, toPath, isWindows);
      });

      for (var dir in dirs) {
        createDirWithRemote(dir, isRemote);
      }
    });
  }

  bool _removeCheckboxRemember = false;

  Future<void> removeAction(SelectedItems items) async {
    _removeCheckboxRemember = false;
    if (items.isLocal != isLocal) {
      debugPrint("Failed to removeFile, wrong files");
      return;
    }
    final isWindows = options.value.isWindows;
    await Future.forEach(items.items, (Entry item) async {
      final jobID = JobController.jobID.next();
      var title = "";
      var content = "";
      late final List<Entry> entries;
      if (item.isFile) {
        title = translate("Are you sure you want to delete this file?");
        content = item.name;
        entries = [item];
      } else if (item.isDirectory) {
        title = translate("Not an empty directory");
        dialogManager?.showLoading(translate("Waiting"));
        final FileDirectory fd;
        try {
          fd = await fileFetcher.fetchDirectoryRecursiveToRemove(
              jobID, item.path, items.isLocal, true);
        } catch (e) {
          dialogManager?.dismissAll();
          final dm = dialogManager;
          if (dm != null) {
            msgBox(sessionId, 'custom-error-nook-nocancel-hasclose',
                translate("Error"), e.toString(), '', dm);
          } else {
            debugPrint("removeAction error msgbox failed: $e");
          }
          return;
        }
        if (fd.path.isEmpty) {
          fd.path = item.path;
        }
        fd.format(isWindows);
        dialogManager?.dismissAll();
        if (fd.entries.isEmpty) {
          var deleteJobId = jobController.addDeleteDirJob(item, !isLocal, 0);
          final confirm = await showRemoveDialog(
              translate(
                  "Are you sure you want to delete this empty directory?"),
              item.name,
              false);
          if (confirm == true) {
            await sendRemoveEmptyDir(
              item.path,
              0,
              deleteJobId,
            );
          } else {
            jobController.updateJobStatus(deleteJobId,
                error: "cancel", state: JobState.done);
          }
          return;
        }
        entries = fd.entries;
      } else {
        entries = [];
      }
      int deleteJobId;
      if (item.isDirectory) {
        deleteJobId =
            jobController.addDeleteDirJob(item, !isLocal, entries.length);
      } else {
        deleteJobId = jobController.addDeleteFileJob(item, !isLocal);
      }

      for (var i = 0; i < entries.length; i++) {
        final dirShow = item.isDirectory
            ? "${translate("Are you sure you want to delete the file of this directory?")}\n"
            : "";
        final count = entries.length > 1 ? "${i + 1}/${entries.length}" : "";
        content = "$dirShow\n\n${entries[i].path}".trim();
        final confirm = await showRemoveDialog(
          count.isEmpty ? title : "$title ($count)",
          content,
          item.isDirectory,
        );
        try {
          if (confirm == true) {
            sendRemoveFile(entries[i].path, i, deleteJobId);
            final res = await jobController.jobResultListener.start();
            // handle remove res;
            if (item.isDirectory && res.fileNum == entries.length - 1) {
              await sendRemoveEmptyDir(item.path, i, deleteJobId);
            }
          } else {
            jobController.updateJobStatus(deleteJobId,
                file_num: i, error: "cancel");
          }
          if (_removeCheckboxRemember) {
            if (confirm == true) {
              for (var j = i + 1; j < entries.length; j++) {
                sendRemoveFile(entries[j].path, j, deleteJobId);
                final res = await jobController.jobResultListener.start();
                if (item.isDirectory && res.fileNum == entries.length - 1) {
                  await sendRemoveEmptyDir(item.path, i, deleteJobId);
                }
              }
            } else {
              jobController.updateJobStatus(deleteJobId,
                  error: "cancel",
                  file_num: entries.length,
                  state: JobState.done);
            }
            break;
          }
        } catch (e) {
          print("remove error: $e");
        }
      }
    });
    refresh();
  }

  Future<bool?> showRemoveDialog(
      String title, String content, bool showCheckbox) async {
    return await dialogManager?.show<bool>(
        (setState, Function(bool v) close, context) {
      cancel() => close(false);
      submit() => close(true);
      return CustomAlertDialog(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_rounded, color: Colors.red),
            Expanded(
              child: Text(title).paddingOnly(
                left: 10,
              ),
            ),
          ],
        ),
        contentBoxConstraints:
            BoxConstraints(minHeight: 100, minWidth: 400, maxWidth: 400),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(content),
            Text(
              translate("This is irreversible!"),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ).paddingOnly(top: 20),
            showCheckbox
                ? CheckboxListTile(
                    contentPadding: const EdgeInsets.all(0),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      translate("Do this for all conflicts"),
                    ),
                    value: _removeCheckboxRemember,
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _removeCheckboxRemember = v);
                    },
                  )
                : const SizedBox.shrink()
          ],
        ),
        actions: [
          dialogButton(
            "Cancel",
            icon: Icon(Icons.close_rounded),
            onPressed: cancel,
            isOutline: true,
          ),
          dialogButton(
            "OK",
            icon: Icon(Icons.done_rounded),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, useAnimation: false);
  }

  void sendRemoveFile(String path, int fileNum, int actId) {
    bind.sessionRemoveFile(
        sessionId: sessionId,
        actId: actId,
        path: path,
        isRemote: !isLocal,
        fileNum: fileNum);
  }

  Future<void> sendRemoveEmptyDir(String path, int fileNum, int actId) async {
    history.removeWhere((element) => element.contains(path));
    await bind.sessionRemoveAllEmptyDirs(
        sessionId: sessionId, actId: actId, path: path, isRemote: !isLocal);
  }

  Future<void> createDirWithRemote(String path, bool isRemote) async {
    bind.sessionCreateDir(
        sessionId: sessionId,
        actId: JobController.jobID.next(),
        path: path,
        isRemote: isRemote);
  }

  Future<void> createDir(String path) async {
    await createDirWithRemote(path, !isLocal);
  }

  Future<void> renameAction(Entry item, bool isLocal) async {
    final textEditingController = TextEditingController(text: item.name);
    String? errorText;
    dialogManager?.show((setState, close, context) {
      textEditingController.addListener(() {
        if (errorText != null) {
          setState(() {
            errorText = null;
          });
        }
      });
      submit() async {
        final newName = textEditingController.text;
        if (newName.isEmpty || newName == item.name) {
          close();
          return;
        }
        if (directory.value.entries.any((e) => e.name == newName)) {
          setState(() {
            errorText = translate("Already exists");
          });
          return;
        }
        if (!PathUtil.validName(newName, options.value.isWindows)) {
          setState(() {
            if (item.isDirectory) {
              errorText = translate("Invalid folder name");
            } else {
              errorText = translate("Invalid file name");
            }
          });
          return;
        }
        await bind.sessionRenameFile(
            sessionId: sessionId,
            actId: JobController.jobID.next(),
            path: item.path,
            newName: newName,
            isRemote: !isLocal);
        close();
      }

      return CustomAlertDialog(
        content: Column(
          children: [
            DialogTextField(
              title: '${translate('Rename')} ${item.name}',
              controller: textEditingController,
              errorText: errorText,
            ),
          ],
        ),
        actions: [
          dialogButton(
            "Cancel",
            icon: Icon(Icons.close_rounded),
            onPressed: close,
            isOutline: true,
          ),
          dialogButton(
            "OK",
            icon: Icon(Icons.done_rounded),
            onPressed: submit,
          ),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  }
}

const _kOneWayFileTransferError = 'one-way-file-transfer-tip';

class JobController {
  static final JobID jobID = JobID();
  final jobTable = List<JobProgress>.empty(growable: true).obs;
  final jobResultListener = JobResultListener<FileJobResultSessionEvent>();
  final GetSessionID getSessionID;
  final GetDialogManager getDialogManager;
  SessionID get sessionId => getSessionID();
  OverlayDialogManager? get alogManager => getDialogManager();
  int _lastTimeShowMsgbox = DateTime.now().millisecondsSinceEpoch;

  JobController(this.getSessionID, this.getDialogManager);

  int getJob(int id) {
    return jobTable.indexWhere((element) => element.id == id);
  }

  // return jobID
  int addTransferJob(Entry from, bool isRemoteToLocal) {
    final jobID = JobController.jobID.next();
    jobTable.add(JobProgress()
      ..type = JobType.transfer
      ..fileName = path.basename(from.path)
      ..jobName = from.path
      ..totalSize = from.size
      ..state = JobState.inProgress
      ..id = jobID
      ..isRemoteToLocal = isRemoteToLocal);
    return jobID;
  }

  int addDeleteFileJob(Entry file, bool isRemote) {
    final jobID = JobController.jobID.next();
    jobTable.add(JobProgress()
      ..type = JobType.deleteFile
      ..fileName = path.basename(file.path)
      ..jobName = file.path
      ..totalSize = file.size
      ..state = JobState.none
      ..id = jobID
      ..isRemoteToLocal = isRemote);
    return jobID;
  }

  int addDeleteDirJob(Entry file, bool isRemote, int fileCount) {
    final jobID = JobController.jobID.next();
    jobTable.add(JobProgress()
      ..type = JobType.deleteDir
      ..fileName = path.basename(file.path)
      ..jobName = file.path
      ..fileCount = fileCount
      ..totalSize = file.size
      ..state = JobState.none
      ..id = jobID
      ..isRemoteToLocal = isRemote);
    return jobID;
  }

  void updateJobProgressEvent(FileJobProgressSessionEvent event) {
    final jobIndex = getJob(event.id);
    if (jobIndex >= 0 && jobTable.length > jobIndex) {
      final job = jobTable[jobIndex];
      job.fileNum = event.fileNum;
      job.speed = event.speed;
      job.finishedSize = event.finishedSize;
      job.recvJobRes = true;
      jobTable.refresh();
    }
  }

  Future<bool> jobDoneEvent(FileJobDoneSessionEvent event) async {
    if (jobResultListener.isListening) {
      jobResultListener.complete(event);
      // return;
    }
    final jobIndex = getJob(event.id);
    if (jobIndex == -1) return true;
    final job = jobTable[jobIndex];
    job.recvJobRes = true;
    if (job.type == JobType.deleteFile) {
      job.state = JobState.done;
    } else if (job.type == JobType.deleteDir) {
      if (event.fileNum < job.fileNum) return true; // file_num can be 0 at last
      job.fileNum = event.fileNum;
      if (event.fileNum >= job.fileCount - 1) {
        job.state = JobState.done;
      }
    } else {
      job.fileNum = event.fileNum;
      job.speed = event.speed;
      job.state = JobState.done;
    }
    jobTable.refresh();
    if (job.type == JobType.deleteDir) {
      return job.state == JobState.done;
    } else {
      return true;
    }
  }

  void jobErrorEvent(FileJobErrorSessionEvent event) {
    final err = event.error;
    int jobIndex = getJob(event.id);
    if (jobIndex != -1) {
      final job = jobTable[jobIndex];
      job.state = JobState.error;
      job.err = err;
      job.recvJobRes = true;
      if (job.type == JobType.transfer) {
        job.fileNum = event.fileNum;
        if (err == "skipped") {
          job.state = JobState.done;
          job.finishedSize = job.totalSize;
        }
      } else if (job.type == JobType.deleteDir) {
        if (jobResultListener.isListening) {
          jobResultListener.complete(event);
        }
        job.fileNum = event.fileNum;
      } else if (job.type == JobType.deleteFile) {
        if (jobResultListener.isListening) {
          jobResultListener.complete(event);
        }
      }
      jobTable.refresh();
    }
    if (err == _kOneWayFileTransferError) {
      if (DateTime.now().millisecondsSinceEpoch - _lastTimeShowMsgbox > 3000) {
        final dm = alogManager;
        if (dm != null) {
          _lastTimeShowMsgbox = DateTime.now().millisecondsSinceEpoch;
          msgBox(sessionId, 'custom-nocancel', 'Error', err, '', dm);
        }
      }
    }
    debugPrint("jobError id=${event.id}, error=$err");
  }

  void updateJobStatus(int id,
      {int? file_num, String? error, JobState? state}) {
    final jobIndex = getJob(id);
    if (jobIndex < 0) return;
    final job = jobTable[jobIndex];
    job.recvJobRes = true;
    if (file_num != null) {
      job.fileNum = file_num;
    }
    if (error != null) {
      job.err = error;
      job.state = JobState.error;
    }
    if (state != null) {
      job.state = state;
    }
    if (job.type == JobType.deleteFile && error == null) {
      job.state = JobState.done;
    }
    jobTable.refresh();
  }

  Future<void> cancelJob(int id) async {
    await bind.sessionCancelJob(sessionId: sessionId, actId: id);
  }

  Future<void> loadLastJobEvent(FileResumeJobSessionEvent event) async {
    debugPrint("load last job: id=${event.id}, auto=${event.autoStart}");
    final remote = event.remotePath;
    final to = event.localPath;
    final showHidden = event.showHidden;
    final fileNum = event.fileNum;
    final isRemote = event.isRemote;
    var isAutoStart = event.autoStart;
    var currJobId = event.id ?? -1;
    if (currJobId < 0) {
      // If id is missing or invalid, disable auto-start and assign a new job id
      isAutoStart = false;
      currJobId = JobController.jobID.next();
    }

    if (!isAutoStart) {
      if (!(isDesktop || isWebDesktop)) {
        // Don't add to job table if not auto start on mobile.
        // Because mobile does not support job list view now.
        return;
      }

      // Add to job table if not auto start on desktop.
      String fileName = path.basename(isRemote ? remote : to);
      final jobProgress = JobProgress()
        ..type = JobType.transfer
        ..fileName = fileName
        ..jobName = isRemote ? remote : to
        ..id = currJobId
        ..isRemoteToLocal = isRemote
        ..fileNum = fileNum
        ..remote = remote
        ..to = to
        ..showHidden = showHidden
        ..state = JobState.paused;
      jobTable.add(jobProgress);
    }

    await bind.sessionAddJob(
      sessionId: sessionId,
      isRemote: isRemote,
      includeHidden: showHidden,
      actId: currJobId,
      path: isRemote ? remote : to,
      to: isRemote ? to : remote,
      fileNum: fileNum,
    );

    if (isAutoStart) {
      await bind.sessionResumeJob(
          sessionId: sessionId, actId: currJobId, isRemote: isRemote);
    }
  }

  void resumeJob(int jobId) {
    final jobIndex = getJob(jobId);
    if (jobIndex != -1) {
      final job = jobTable[jobIndex];
      bind.sessionResumeJob(
          sessionId: sessionId, actId: job.id, isRemote: job.isRemoteToLocal);
      job.state = JobState.inProgress;
      jobTable.refresh();
    } else {
      debugPrint("jobId $jobId is not exists");
    }
  }

  void updateFolderStatsEvent(FileFolderStatsSessionEvent event) {
    final jobIndex = getJob(event.id);
    if (jobIndex != -1) {
      final job = jobTable[jobIndex];
      job.fileCount = event.entryCount;
      job.totalSize = event.totalSize.toInt();
      jobTable.refresh();
    }
    debugPrint(
        "update folder files: id=${event.id}, entries=${event.entryCount}, size=${event.totalSize}");
  }

  void clear() {
    jobTable.clear();
    jobResultListener.clear();
  }
}

class JobResultListener<T> {
  Completer<T>? _completer;
  Timer? _timer;
  final int _timeoutSecond = 5;

  bool get isListening => _completer != null;

  clear() {
    if (_completer != null) {
      _timer?.cancel();
      _timer = null;
      _completer!.completeError("Cancel manually");
      _completer = null;
      return;
    }
  }

  Future<T> start() {
    if (_completer != null) return Future.error("Already start listen");
    _completer = Completer();
    _timer = Timer(Duration(seconds: _timeoutSecond), () {
      if (!_completer!.isCompleted) {
        _completer!.completeError("Time out");
      }
      _completer = null;
    });
    return _completer!.future;
  }

  complete(T res) {
    if (_completer != null) {
      _timer?.cancel();
      _timer = null;
      _completer!.complete(res);
      _completer = null;
      return;
    }
  }
}

class FileFetcher {
  // Map<String,Completer<FileDirectory>> localTasks = {}; // now we only use read local dir sync
  Map<String, Completer<FileDirectory>> remoteTasks = {};
  Map<String, Completer<List<FileDirectory>>> remoteEmptyDirsTasks = {};
  Map<int, Completer<FileDirectory>> readRecursiveTasks = {};

  final GetSessionID getSessionID;
  SessionID get sessionId => getSessionID();

  FileFetcher(this.getSessionID);

  Future<List<FileDirectory>> registerReadEmptyDirsTask(
      bool isLocal, String path) {
    // final jobs = isLocal?localJobs:remoteJobs; // maybe we will use read local dir async later
    final tasks = remoteEmptyDirsTasks; // bypass now
    if (tasks.containsKey(path)) {
      throw "Failed to registerReadEmptyDirsTask, already have same read job";
    }
    final c = Completer<List<FileDirectory>>();
    tasks[path] = c;

    Timer(Duration(seconds: 2), () {
      tasks.remove(path);
      if (c.isCompleted) return;
      c.completeError("Failed to read empty dirs, timeout");
    });
    return c.future;
  }

  Future<FileDirectory> registerReadTask(bool isLocal, String path) {
    // final jobs = isLocal?localJobs:remoteJobs; // maybe we will use read local dir async later
    final tasks = remoteTasks; // bypass now
    if (tasks.containsKey(path)) {
      throw "Failed to registerReadTask, already have same read job";
    }
    final c = Completer<FileDirectory>();
    tasks[path] = c;

    Timer(Duration(seconds: 2), () {
      tasks.remove(path);
      if (c.isCompleted) return;
      c.completeError("Failed to read dir, timeout");
    });
    return c.future;
  }

  Future<FileDirectory> registerReadRecursiveTask(int actID) {
    final tasks = readRecursiveTasks;
    if (tasks.containsKey(actID)) {
      throw "Failed to registerRemoveTask, already have same ReadRecursive job";
    }
    final c = Completer<FileDirectory>();
    tasks[actID] = c;

    Timer(Duration(seconds: 2), () {
      tasks.remove(actID);
      if (c.isCompleted) return;
      c.completeError("Failed to read dir, timeout");
    });
    return c.future;
  }

  void completeEmptyDirectories(EmptyDirectoriesSessionEvent event) {
    final directories = [
      for (final value in event.directories)
        FileDirectory.fromSessionValue(value),
    ];
    final completer = remoteEmptyDirsTasks.remove(event.path);
    completer?.complete(directories);
  }

  void completeDirectory(SessionFileDirectoryValue value) {
    late final Map<Object, Completer<FileDirectory>> tasks;
    final fd = FileDirectory.fromSessionValue(value);
    if (fd.id > 0) {
      // fd.id > 0 is result for read recursive
      // to-do later,will be better if every fetch use ID,so that there will only one task map for read and recursive read
      tasks = readRecursiveTasks;
      final completer = tasks.remove(fd.id);
      completer?.complete(fd);
    } else if (fd.path.isNotEmpty) {
      // result for normal read dir
      // Local reads are synchronous; asynchronous tasks are remote-only for now.
      tasks = remoteTasks; // bypass now
      final completer = tasks.remove(fd.path);
      completer?.complete(fd);
    }
  }

  // Complete a pending recursive read task with an error.
  // See FileModel.handleJobErrorEvent() for why this is necessary.
  void tryCompleteRecursiveTaskWithError(int id, String error) {
    final completer = readRecursiveTasks.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  Future<List<FileDirectory>> readEmptyDirs(
      String path, bool isLocal, bool showHidden) async {
    try {
      if (isLocal) {
        final res = await bind.sessionReadLocalEmptyDirsRecursiveSync(
            sessionId: sessionId, path: path, includeHidden: showHidden);

        final List<dynamic> fdJsons = jsonDecode(res);

        final List<FileDirectory> fds =
            fdJsons.map((fdJson) => FileDirectory.fromJson(fdJson)).toList();
        return fds;
      } else {
        await bind.sessionReadRemoteEmptyDirsRecursiveSync(
            sessionId: sessionId, path: path, includeHidden: showHidden);
        return registerReadEmptyDirsTask(isLocal, path);
      }
    } catch (e) {
      return Future.error(e);
    }
  }

  Future<FileDirectory> fetchDirectory(
      String path, bool isLocal, bool showHidden) async {
    try {
      if (isLocal) {
        final res = await bind.sessionReadLocalDirSync(
            sessionId: sessionId, path: path, showHidden: showHidden);
        final fd = FileDirectory.fromJson(jsonDecode(res));
        return fd;
      } else {
        await bind.sessionReadRemoteDir(
            sessionId: sessionId, path: path, includeHidden: showHidden);
        return registerReadTask(isLocal, path);
      }
    } catch (e) {
      return Future.error(e);
    }
  }

  Future<FileDirectory> fetchDirectoryRecursiveToRemove(
      int actID, String path, bool isLocal, bool showHidden) async {
    // TODO test Recursive is show hidden default?
    try {
      await bind.sessionReadDirToRemoveRecursive(
          sessionId: sessionId,
          actId: actID,
          path: path,
          isRemote: !isLocal,
          showHidden: showHidden);
      return registerReadRecursiveTask(actID);
    } catch (e) {
      return Future.error(e);
    }
  }
}

class FileDirectory {
  List<Entry> entries = [];
  int id = 0;
  String path = "";

  FileDirectory();

  FileDirectory.fromSessionValue(SessionFileDirectoryValue value) {
    id = value.id;
    path = value.path;
    entries = [
      for (final entry in value.entries) Entry.fromSessionValue(entry),
    ];
  }

  FileDirectory.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    path = json['path'];
    json['entries'].forEach((v) {
      entries.add(Entry.fromJson(v));
    });
  }

  // generate full path for every entry , init sort style if need.
  format(bool isWindows, {SortBy? sort}) {
    for (var entry in entries) {
      entry.path = PathUtil.join(path, entry.name, isWindows);
    }
    if (sort != null) {
      changeSortStyle(sort);
    }
  }

  changeSortStyle(SortBy sort, {bool ascending = true}) {
    entries = _sortList(entries, sort, ascending);
  }

  clear() {
    entries = [];
    id = 0;
    path = "";
  }
}

class Entry {
  int entryType = 4;
  int modifiedTime = 0;
  String name = "";
  String path = "";
  int size = 0;

  Entry();

  Entry.fromSessionValue(SessionFileEntryValue value) {
    entryType = value.entryType;
    modifiedTime = value.modifiedTime;
    name = value.name;
    size = value.size;
  }

  Entry.fromJson(Map<String, dynamic> json) {
    entryType = json['entry_type'];
    modifiedTime = json['modified_time'];
    name = json['name'];
    size = json['size'];
  }

  bool get isFile => entryType > 3;

  bool get isDirectory => entryType < 3;

  bool get isDrive => entryType == 3;

  DateTime lastModified() {
    return DateTime.fromMillisecondsSinceEpoch(modifiedTime * 1000);
  }
}

enum JobState { none, inProgress, done, error, paused }

extension JobStateDisplay on JobState {
  String display() {
    switch (this) {
      case JobState.none:
        return translate("Waiting");
      case JobState.inProgress:
        return translate("Transfer file");
      case JobState.done:
        return translate("Finished");
      case JobState.error:
        return translate("Error");
      default:
        return "";
    }
  }
}

enum JobType { none, transfer, deleteFile, deleteDir }

class JobProgress {
  JobType type = JobType.none;
  JobState state = JobState.none;
  var recvJobRes = false;
  var id = 0;
  var fileNum = 0;
  var speed = 0.0;
  var finishedSize = 0;
  var totalSize = 0;
  var fileCount = 0;
  // [isRemote == true] means [remote -> local]
  // var isRemote = false;
  // to-do use enum
  var isRemoteToLocal = false;
  var jobName = "";
  var fileName = "";
  var remote = "";
  var to = "";
  var showHidden = false;
  var err = "";
  int lastTransferredSize = 0;

  double get percent =>
      totalSize > 0 ? (finishedSize.toDouble() / totalSize) : 0.0;
  String get percentText => '${(percent * 100).toStringAsFixed(0)}%';

  clear() {
    type = JobType.none;
    state = JobState.none;
    recvJobRes = false;
    id = 0;
    fileNum = 0;
    speed = 0;
    finishedSize = 0;
    jobName = "";
    fileName = "";
    fileCount = 0;
    remote = "";
    to = "";
    err = "";
  }

  String display() {
    if (type == JobType.transfer) {
      if (state == JobState.done && err == "skipped") {
        return translate("Skipped");
      }
    } else if (type == JobType.deleteFile) {
      if (err == "cancel") {
        return translate("Cancel");
      }
    }

    return state.display();
  }

  String getStatus() {
    int handledFileCount = recvJobRes ? fileNum + 1 : fileNum;
    if (handledFileCount >= fileCount) {
      handledFileCount = fileCount;
    }
    if (state == JobState.done) {
      handledFileCount = fileCount;
      finishedSize = totalSize;
    }
    final filesStr = "$handledFileCount/$fileCount files";
    final sizeStr = totalSize > 0 ? readableFileSize(totalSize.toDouble()) : "";
    final sizePercentStr = totalSize > 0 && finishedSize > 0
        ? "${readableFileSize(finishedSize.toDouble())} / ${readableFileSize(totalSize.toDouble())}"
        : "";
    if (type == JobType.deleteFile) {
      return display();
    } else if (type == JobType.deleteDir) {
      var res = '';
      if (state == JobState.done || state == JobState.error) {
        res = display();
      }
      if (filesStr.isNotEmpty) {
        if (res.isNotEmpty) {
          res += " ";
        }
        res += filesStr;
      }

      if (sizeStr.isNotEmpty) {
        if (res.isNotEmpty) {
          res += ", ";
        }
        res += sizeStr;
      }
      return res;
    } else if (type == JobType.transfer) {
      var res = "";
      if (state != JobState.inProgress && state != JobState.none) {
        res += display();
      }
      if (filesStr.isNotEmpty) {
        if (res.isNotEmpty) {
          res += ", ";
        }
        res += filesStr;
      }
      if (sizeStr.isNotEmpty && state != JobState.inProgress) {
        if (res.isNotEmpty) {
          res += ", ";
        }
        res += sizeStr;
      }
      if (sizePercentStr.isNotEmpty && state == JobState.inProgress) {
        if (res.isNotEmpty) {
          res += ", ";
        }
        res += sizePercentStr;
      }
      return res;
    }
    return '';
  }
}

class _PathStat {
  final String path;
  final DateTime dateTime;

  _PathStat(this.path, this.dateTime);
}

class PathUtil {
  static final windowsContext = path.Context(style: path.Style.windows);
  static final posixContext = path.Context(style: path.Style.posix);

  static String getOtherSidePath(String mainRootPath, String mainPath,
      bool isMainWindows, String otherRootPath, bool isOtherWindows) {
    final mainPathUtil = isMainWindows ? windowsContext : posixContext;
    final relativePath = mainPathUtil.relative(mainPath, from: mainRootPath);

    final names = mainPathUtil.split(relativePath);

    final otherPathUtil = isOtherWindows ? windowsContext : posixContext;

    String path = otherRootPath;

    for (var name in names) {
      path = otherPathUtil.join(path, name);
    }

    return path;
  }

  static String join(String path1, String path2, bool isWindows) {
    final pathUtil = isWindows ? windowsContext : posixContext;
    return pathUtil.join(path1, path2);
  }

  static List<String> split(String path, bool isWindows) {
    final pathUtil = isWindows ? windowsContext : posixContext;
    return pathUtil.split(path);
  }

  static String convert(String path, bool isMainWindows, bool isOtherWindows) {
    final mainPathUtil = isMainWindows ? windowsContext : posixContext;
    final otherPathUtil = isOtherWindows ? windowsContext : posixContext;
    return otherPathUtil.joinAll(mainPathUtil.split(path));
  }

  static String dirname(String path, bool isWindows) {
    final pathUtil = isWindows ? windowsContext : posixContext;
    return pathUtil.dirname(path);
  }

  static bool validName(String name, bool isWindows) {
    final unixFileNamePattern = RegExp(r'^[^/\0]+$');
    final windowsFileNamePattern = RegExp(r'^[^<>:"/\\|?*]+$');
    final reg = isWindows ? windowsFileNamePattern : unixFileNamePattern;
    return reg.hasMatch(name);
  }
}

class DirectoryOptions {
  String home;
  bool showHidden;
  bool isWindows;

  DirectoryOptions(
      {this.home = "", this.showHidden = false, this.isWindows = false});

  clear() {
    home = "";
    showHidden = false;
    isWindows = false;
  }
}

class SelectedItems {
  final bool isLocal;
  final items = RxList<Entry>.empty(growable: true);

  SelectedItems({required this.isLocal});

  void add(Entry e) {
    if (e.isDrive) return;
    if (!items.contains(e)) {
      items.add(e);
    }
  }

  void remove(Entry e) {
    items.remove(e);
  }

  void clear() {
    items.clear();
  }

  void selectAll(List<Entry> entries) {
    items.clear();
    items.addAll(entries);
  }

  static bool valid(RxList<Entry> items) {
    if (items.isNotEmpty) {
      // exclude DirDrive type
      return items.any((item) => !item.isDrive);
    }
    return false;
  }
}

// edited from [https://github.com/DevsOnFlutter/file_manager/blob/c1bf7f0225b15bcb86eba602c60acd5c4da90dd8/lib/file_manager.dart#L22]
List<Entry> _sortList(List<Entry> list, SortBy sortType, bool ascending) {
  if (sortType == SortBy.name) {
    // making list of only folders.
    final dirs = list
        .where((element) => element.isDirectory || element.isDrive)
        .toList();
    // sorting folder list by name.
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // making list of only flies.
    final files = list.where((element) => element.isFile).toList();
    // sorting files list by name.
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // first folders will go to list (if available) then files will go to list.
    return ascending
        ? [...dirs, ...files]
        : [...dirs.reversed.toList(), ...files.reversed.toList()];
  } else if (sortType == SortBy.modified) {
    // making the list of Path & DateTime
    List<_PathStat> pathStat = [];
    for (Entry e in list) {
      pathStat.add(_PathStat(e.name, e.lastModified()));
    }

    // sort _pathStat according to date
    pathStat.sort((b, a) => a.dateTime.compareTo(b.dateTime));

    // sorting [list] according to [_pathStat]
    list.sort((a, b) => pathStat
        .indexWhere((element) => element.path == a.name)
        .compareTo(pathStat.indexWhere((element) => element.path == b.name)));
    return ascending ? list : list.reversed.toList();
  } else if (sortType == SortBy.type) {
    // making list of only folders.
    final dirs = list.where((element) => element.isDirectory).toList();

    // sorting folders by name.
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // making the list of files
    final files = list.where((element) => element.isFile).toList();

    // sorting files list by extension.
    files.sort((a, b) => a.name
        .toLowerCase()
        .split('.')
        .last
        .compareTo(b.name.toLowerCase().split('.').last));
    return ascending
        ? [...dirs, ...files]
        : [...dirs.reversed.toList(), ...files.reversed.toList()];
  } else if (sortType == SortBy.size) {
    // create list of path and size
    Map<String, int> sizeMap = {};
    for (Entry e in list) {
      sizeMap[e.name] = e.size;
    }

    // making list of only folders.
    final dirs = list.where((element) => element.isDirectory).toList();
    // sorting folder list by name.
    dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    // making list of only flies.
    final files = list.where((element) => element.isFile).toList();

    // creating sorted list of [_sizeMapList] by size.
    final List<MapEntry<String, int>> sizeMapList = sizeMap.entries.toList();
    sizeMapList.sort((b, a) => a.value.compareTo(b.value));

    // sort [list] according to [_sizeMapList]
    files.sort((a, b) => sizeMapList
        .indexWhere((element) => element.key == a.name)
        .compareTo(sizeMapList.indexWhere((element) => element.key == b.name)));
    return ascending
        ? [...dirs, ...files]
        : [...dirs.reversed.toList(), ...files.reversed.toList()];
  }
  return [];
}

/// Define a general queue which can accepts different dialog type.
///
/// [Visibility]
/// The `_FileDialogType` and `_DialogEvent` are invisible for other models.
enum FileDialogType { overwrite, unknown }

class _FileDialogEvent
    extends BaseEvent<FileDialogType, FileOverrideConfirmSessionEvent> {
  WeakReference<FileModel> fileModel;
  bool? _overrideConfirm;
  bool _skip = false;

  _FileDialogEvent(this.fileModel, super.type, super.data);

  void setOverrideConfirm(bool? confirm) {
    _overrideConfirm = confirm;
  }

  void setSkip(bool skip) {
    _skip = skip;
  }

  @override
  EventCallback<FileOverrideConfirmSessionEvent>? findCallback(
      FileDialogType type) {
    final model = fileModel.target;
    if (model == null) {
      return null;
    }
    switch (type) {
      case FileDialogType.overwrite:
        return (data) async {
          return await model.overrideFileConfirmEvent(data,
              overrideConfirm: _overrideConfirm, skip: _skip);
        };
      default:
        debugPrint("Unknown event type: $type with $data");
        return null;
    }
  }
}

class FileDialogEventLoop
    extends BaseEventLoop<FileDialogType, FileOverrideConfirmSessionEvent> {
  bool? _overrideConfirm;
  bool _skip = false;

  @override
  Future<void> onPreConsume(
      BaseEvent<FileDialogType, FileOverrideConfirmSessionEvent> evt) async {
    var event = evt as _FileDialogEvent;
    event.setOverrideConfirm(_overrideConfirm);
    event.setSkip(_skip);
    debugPrint(
        "FileDialogEventLoop: consuming<jobId: ${evt.data.id} overrideConfirm: $_overrideConfirm, skip: $_skip>");
  }

  @override
  Future<void> onEventsClear() {
    _overrideConfirm = null;
    _skip = false;
    return super.onEventsClear();
  }

  void setOverrideConfirm(bool? confirm) {
    _overrideConfirm = confirm;
  }

  void setSkip(bool skip) {
    _skip = skip;
  }
}
