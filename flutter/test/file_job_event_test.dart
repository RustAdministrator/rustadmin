import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  JobController controller() => JobController(
    () => throw StateError('session not used by this test'),
    () => null,
  );

  test('typed progress and completion update the matching job', () async {
    final jobs = controller();
    final job = JobProgress()
      ..id = 7
      ..type = JobType.transfer
      ..state = JobState.inProgress
      ..totalSize = 1000;
    jobs.jobTable.add(job);

    jobs.updateJobProgressEvent(
      const FileJobProgressSessionEvent(
        id: 7,
        fileNum: 3,
        speed: 512.5,
        finishedSize: 750,
      ),
    );
    expect(job.fileNum, 3);
    expect(job.speed, 512.5);
    expect(job.finishedSize, 750);
    expect(job.recvJobRes, isTrue);

    final resultFuture = jobs.jobResultListener.start();
    const done = FileJobDoneSessionEvent(id: 7, fileNum: 4, speed: 256);
    expect(await jobs.jobDoneEvent(done), isTrue);
    expect(await resultFuture, same(done));
    expect(job.state, JobState.done);
    expect(job.fileNum, 4);
  });

  test('typed error completes a delete result and marks the job', () async {
    final jobs = controller();
    final job = JobProgress()
      ..id = 8
      ..type = JobType.deleteFile
      ..state = JobState.inProgress;
    jobs.jobTable.add(job);

    final resultFuture = jobs.jobResultListener.start();
    const error = FileJobErrorSessionEvent(id: 8, fileNum: 2, error: 'denied');
    jobs.jobErrorEvent(error);

    expect(await resultFuture, same(error));
    expect(job.state, JobState.error);
    expect(job.err, 'denied');
  });
}
