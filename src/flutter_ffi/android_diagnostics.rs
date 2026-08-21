use android_logger::{AndroidLogger, Config};
use hbb_common::log::{self, Level, LevelFilter, Log, Metadata, Record};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, OnceLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};

const LOG_FILE_MAX_BYTES: u64 = 1024 * 1024;
const LOG_LINE_MAX_BYTES: usize = 4 * 1024;

static LOGGER: OnceLock<AndroidDiagnosticLogger> = OnceLock::new();
pub const OPTION_ENABLE_ANDROID_DIAGNOSTIC_LOGGING: &str = "enable-android-diagnostic-logging";

struct LogFile {
    path: PathBuf,
    file: Option<File>,
    bytes: u64,
}

impl LogFile {
    fn new(app_dir: &str, enabled: bool) -> Self {
        let path = PathBuf::from(app_dir)
            .join("diagnostics")
            .join("rustadmin.log");
        let bytes = fs::metadata(&path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let mut state = Self {
            path,
            file: None,
            bytes,
        };
        if enabled {
            state.open();
        }
        state
    }

    fn open(&mut self) {
        if self.file.is_some() {
            return;
        }
        if let Some(directory) = self.path.parent() {
            let _ = fs::create_dir_all(directory);
        }
        let previous = self.path.with_extension("log.1");
        if fs::metadata(&previous)
            .map(|metadata| metadata.len() > LOG_FILE_MAX_BYTES)
            .unwrap_or(false)
        {
            let _ = fs::remove_file(&previous);
        }
        self.bytes = fs::metadata(&self.path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        if self.bytes >= LOG_FILE_MAX_BYTES {
            self.rotate();
            return;
        }
        self.file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .ok();
    }

    fn close(&mut self) {
        if let Some(mut file) = self.file.take() {
            let _ = file.flush();
        }
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
        if self.bytes > LOG_FILE_MAX_BYTES {
            if Self::copy_tail(&self.path, &previous).is_ok() {
                let _ = fs::remove_file(&self.path);
            } else {
                let _ = fs::rename(&self.path, previous);
            }
        } else {
            let _ = fs::rename(&self.path, previous);
        }
        self.file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)
            .ok();
        self.bytes = 0;
    }

    fn copy_tail(source: &PathBuf, destination: &PathBuf) -> std::io::Result<()> {
        let mut input = File::open(source)?;
        let file_len = input.metadata()?.len();
        let tail_len = file_len.min(LOG_FILE_MAX_BYTES);
        input.seek(SeekFrom::Start(file_len.saturating_sub(tail_len)))?;
        let mut tail = Vec::with_capacity(tail_len as usize);
        input.read_to_end(&mut tail)?;
        let start = tail
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index.saturating_add(1))
            .unwrap_or(0);
        fs::write(destination, &tail[start..])
    }
}

struct AndroidDiagnosticLogger {
    logcat: AndroidLogger,
    file: Mutex<LogFile>,
    enabled: AtomicBool,
}

impl AndroidDiagnosticLogger {
    fn new(app_dir: &str, enabled: bool) -> Self {
        Self {
            logcat: AndroidLogger::new(
                Config::default()
                    .with_max_level(LevelFilter::Debug)
                    .with_tag("RustAdmin"),
            ),
            file: Mutex::new(LogFile::new(app_dir, enabled)),
            enabled: AtomicBool::new(enabled),
        }
    }

    fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
        if let Ok(mut file) = self.file.lock() {
            if enabled {
                file.open();
            } else {
                file.close();
            }
        }
    }
}

impl Log for AndroidDiagnosticLogger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        self.enabled.load(Ordering::Relaxed)
            && !(metadata.level() == Level::Debug && metadata.target().starts_with("quinn"))
            && self.logcat.enabled(metadata)
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

pub fn init(app_dir: &str, enabled: bool) {
    let logger = LOGGER.get_or_init(|| AndroidDiagnosticLogger::new(app_dir, enabled));
    logger.set_enabled(enabled);
    if log::set_logger(logger).is_ok() {
        log::set_max_level(LevelFilter::Debug);
    }
}

pub fn set_enabled(enabled: bool) {
    if let Some(logger) = LOGGER.get() {
        logger.set_enabled(enabled);
    }
}
