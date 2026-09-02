import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:get/get.dart';
import 'file_model.dart';

class CmFileModel {
  final WeakReference<FFI> parent;
  final currentJobTable = RxList<CmFileLog>();
  final _jobTables = HashMap<int, RxList<CmFileLog>>.fromEntries([]);
  Stopwatch stopwatch = Stopwatch();
  int _lastElapsed = 0;

  CmFileModel(this.parent);

  void updateCurrentClientId(int id) {
    if (_jobTables[id] == null) {
      _jobTables[id] = RxList<CmFileLog>();
    }
    Future.delayed(Duration.zero, () {
      currentJobTable.value = _jobTables[id]!;
    });
  }

  void handleTransferEvent(CmTransferLogSessionEvent event) {
    if (!stopwatch.isRunning) stopwatch.start();
    final calcSpeed = stopwatch.elapsedMilliseconds - _lastElapsed >= 1000;
    if (calcSpeed) {
      _lastElapsed = stopwatch.elapsedMilliseconds;
    }
    for (final job in event.jobs) {
      _dealOneJob(job, calcSpeed);
    }
    currentJobTable.refresh();
  }

  void _dealOneJob(SessionCmTransferJobValue data, bool calcSpeed) {
    var jobTable = _jobTables[data.connectionId];
    if (jobTable == null) {
      debugPrint("jobTable should not be null");
      return;
    }
    CmFileLog? job = jobTable.firstWhereOrNull((e) => e.id == data.id);
    if (job == null) {
      job = CmFileLog();
      jobTable.add(job);
      _addUnread(data.connectionId);
    }
    job.id = data.id;
    job.action =
        data.isRemote ? CmFileAction.remoteToLocal : CmFileAction.localToRemote;
    job.fileName = data.path;
    job.totalSize = data.totalSize;
    job.finishedSize = data.finishedSize;
    if (job.finishedSize > data.totalSize) {
      job.finishedSize = data.totalSize;
    }

    if (job.finishedSize > 0) {
      if (job.finishedSize < job.totalSize) {
        job.state = JobState.inProgress;
      } else {
        job.state = JobState.done;
      }
    }
    if (data.done) {
      job.state = JobState.done;
    } else if (data.cancel || data.error == 'skipped') {
      job.state = JobState.done;
      job.err = 'skipped';
    } else if (data.error.isNotEmpty) {
      job.state = JobState.error;
      job.err = data.error;
    }
    if (calcSpeed) {
      job.speed = (data.transferred - job.lastTransferredSize) * 1.0;
      job.lastTransferredSize = data.transferred;
    }
    jobTable.refresh();
  }

  void handleFileActionEvent(CmFileActionSessionEvent event) {
    switch (event.kind) {
      case CmFileActionKind.remove:
        _onFileRemove(event);
      case CmFileActionKind.createDirectory:
        _onDirCreate(event);
    }
  }

  void _onFileRemove(CmFileActionSessionEvent data) {
    Client? client = gFFI.serverModel.clients
        .firstWhereOrNull((e) => e.id == data.connectionId);
    var jobTable = _jobTables[data.connectionId];
    if (jobTable == null) {
      debugPrint("jobTable should not be null");
      return;
    }
    int removeUnreadCount = 0;
    if (data.directory) {
      bool isChild(String parent, String child) {
        if (child.startsWith(parent) && child.length > parent.length) {
          final suffix = child.substring(parent.length);
          return suffix.startsWith('/') || suffix.startsWith('\\');
        }
        return false;
      }

      removeUnreadCount = jobTable
          .where((e) =>
              e.action == CmFileAction.remove &&
              isChild(data.path, e.fileName))
          .length;
      jobTable.removeWhere((e) =>
          e.action == CmFileAction.remove && isChild(data.path, e.fileName));
    }
    jobTable.add(CmFileLog()
      ..id = data.id
      ..fileName = data.path
      ..action = CmFileAction.remove
      ..state = JobState.done);
    final currentSelectedTab =
        gFFI.serverModel.tabController.state.value.selectedTabInfo;
    if (!(gFFI.chatModel.isShowCMSidePage &&
        currentSelectedTab.key == data.connectionId.toString())) {
      // Wrong number if unreadCount changes during deletion, which rarely happens
      RxInt? rx = client?.unreadChatMessageCount;
      if (rx != null) {
        if (rx.value >= removeUnreadCount) {
          rx.value -= removeUnreadCount;
        }
        rx.value += 1;
      }
    }
    jobTable.refresh();
  }

  void _onDirCreate(CmFileActionSessionEvent data) {
    var jobTable = _jobTables[data.connectionId];
    if (jobTable == null) {
      debugPrint("jobTable should not be null");
      return;
    }
    jobTable.add(CmFileLog()
      ..id = data.id
      ..fileName = data.path
      ..action = CmFileAction.createDir
      ..state = JobState.done);
    _addUnread(data.connectionId);
    jobTable.refresh();
  }

  void handleRenameEvent(CmFileRenameSessionEvent data) {
    var jobTable = _jobTables[data.connectionId];
    if (jobTable == null) {
      debugPrint("jobTable should not be null");
      return;
    }
    final fileName = '${data.path} -> ${data.newName}';
    jobTable.add(CmFileLog()
      ..id = 0
      ..fileName = fileName
      ..action = CmFileAction.rename
      ..state = JobState.done);
    _addUnread(data.connectionId);
    jobTable.refresh();
  }

  _addUnread(int connId) {
    Client? client =
        gFFI.serverModel.clients.firstWhereOrNull((e) => e.id == connId);
    final currentSelectedTab =
        gFFI.serverModel.tabController.state.value.selectedTabInfo;
    if (!(gFFI.chatModel.isShowCMSidePage &&
        currentSelectedTab.key == connId.toString())) {
      client?.unreadChatMessageCount.value += 1;
    }
  }
}

enum CmFileAction {
  none,
  remoteToLocal,
  localToRemote,
  remove,
  createDir,
  rename,
}

class CmFileLog {
  JobState state = JobState.none;
  var id = 0;
  var speed = 0.0;
  var finishedSize = 0;
  var totalSize = 0;
  CmFileAction action = CmFileAction.none;
  var fileName = "";
  var err = "";
  int lastTransferredSize = 0;

  String display() {
    if (state == JobState.done && err == "skipped") {
      return translate("Skipped");
    }
    return state.display();
  }

  bool isTransfer() {
    return action == CmFileAction.remoteToLocal ||
        action == CmFileAction.localToRemote;
  }
}
