use android_logger::{AndroidLogger, Config};
use hbb_common::log::{self, LevelFilter, Log, Metadata, Record};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

const LOG_FILE_MAX_BYTES: u64 = 4 * 1024 * 1024;
const LOG_LINE_MAX_BYTES: usize = 16 * 1024;

static LOGGER: OnceLock<AndroidDiagnosticLogger> = OnceLock::new();

struct LogFile {
    path: PathBuf,
    file: Option<File>,
    bytes: u64,
}

impl LogFile {
    fn new(app_dir: &str) -> Self {
        let directory = PathBuf::from(app_dir).join("diagnostics");
        let _ = fs::create_dir_all(&directory);
        let path = directory.join("rustadmin.log");
        let bytes = fs::metadata(&path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok();
        Self { path, file, bytes }
    }

    fn write(&mut self, line: &[u8]) {
        if self.bytes.saturating_add(line.len() as u64) > LOG_FILE_MAX_BYTES {
            self.rotate();
        }
        if let Some(file) = self.file.as_mut() {
            if file.write_all(line).is_ok() {
                self.bytes = self.bytes.saturating_add(line.len() as u64);
            }
        }
    }

    fn rotate(&mut self) {
        self.file.take();
        let previous = self.path.with_extension("log.1");
        let _ = fs::remove_file(&previous);
        let _ = fs::rename(&self.path, previous);
        self.file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)
            .ok();
        self.bytes = 0;
    }
}

struct AndroidDiagnosticLogger {
    logcat: AndroidLogger,
    file: Mutex<LogFile>,
}

impl AndroidDiagnosticLogger {
    fn new(app_dir: &str) -> Self {
        Self {
            logcat: AndroidLogger::new(
                Config::default()
                    .with_max_level(LevelFilter::Debug)
                    .with_tag("RustAdmin"),
            ),
            file: Mutex::new(LogFile::new(app_dir)),
        }
    }
}

impl Log for AndroidDiagnosticLogger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        self.logcat.enabled(metadata)
    }

    fn log(&self, record: &Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        self.logcat.log(record);

        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        let mut line = format!(
            "{timestamp_ms} {:<5} [{}] {}\n",
            record.level(),
            record.target(),
            record.args()
        );
        if line.len() > LOG_LINE_MAX_BYTES {
            let mut boundary = LOG_LINE_MAX_BYTES;
            while !line.is_char_boundary(boundary) {
                boundary -= 1;
            }
            line.truncate(boundary);
            line.push('\n');
        }
        if let Ok(mut file) = self.file.lock() {
            file.write(line.as_bytes());
        }
    }

    fn flush(&self) {
        if let Ok(mut state) = self.file.lock() {
            if let Some(file) = state.file.as_mut() {
                let _ = file.flush();
            }
        }
    }
}

pub fn init(app_dir: &str) {
    let logger = LOGGER.get_or_init(|| AndroidDiagnosticLogger::new(app_dir));
    if log::set_logger(logger).is_ok() {
        log::set_max_level(LevelFilter::Debug);
    }
}
