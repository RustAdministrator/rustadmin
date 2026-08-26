use hbb_common::{
    anyhow::{bail, Context},
    config::{Config, APP_DIR},
    regex::{escape, Regex},
    ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use zip::{write::FileOptions, CompressionMethod, ZipArchive, ZipWriter};

const MAX_DIAGNOSTIC_FILES: usize = 160;
const MAX_DIAGNOSTIC_FILES_PER_ROOT: usize = 32;
const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_TOTAL_SOURCE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_DIRECTORY_DEPTH: usize = 4;
const DIAGNOSTIC_SUMMARY_ENTRY: &str = "summary.json";

#[derive(Debug, Serialize)]
pub struct DiagnosticExportReport {
    pub path: String,
    pub files: usize,
    pub source_bytes: u64,
    pub archive_bytes: u64,
    pub truncated_files: usize,
}

#[derive(Debug, Deserialize, Serialize)]
struct DiagnosticArchiveSummary {
    files: usize,
    source_bytes: u64,
    truncated_files: usize,
}

#[derive(Debug)]
struct DiagnosticFile {
    path: PathBuf,
    entry_name: String,
    modified: SystemTime,
}

struct DiagnosticRedactor {
    identities: Vec<Regex>,
    secrets: Regex,
    bearer: Regex,
    url_query: Regex,
    peer_id: Regex,
    email: Regex,
    mac: Regex,
}

impl DiagnosticRedactor {
    fn new() -> ResultType<Self> {
        let mut identity_values = Vec::new();
        for key in [
            "USERPROFILE",
            "HOME",
            "USERNAME",
            "USER",
            "COMPUTERNAME",
            "HOSTNAME",
        ] {
            if let Ok(value) = std::env::var(key) {
                let value = value.trim();
                if value.len() >= 3 && !identity_values.iter().any(|existing| existing == value) {
                    identity_values.push(value.to_owned());
                }
            }
        }
        let mut identities = Vec::new();
        for value in identity_values {
            identities.push(Regex::new(&format!("(?i){}", escape(&value)))?);
            if value.contains('\\') {
                identities.push(Regex::new(&format!(
                    "(?i){}",
                    escape(&value.replace('\\', "/"))
                ))?);
            }
        }
        Ok(Self {
            identities,
            secrets: Regex::new(
                r#"(?i)\b(password|passwd|token|secret|authorization|private[_ -]?key|access[_ -]?key|unlock[_ -]?pin)\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            )?,
            bearer: Regex::new(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")?,
            url_query: Regex::new(r"(?i)(https?://[^\s?]+)\?[^\s]+")?,
            peer_id: Regex::new(r"(?i)\b(peer(?:_id)?|remote_id|fingerprint)\s*[:=]\s*[^\s,;]+")?,
            email: Regex::new(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")?,
            mac: Regex::new(r"(?i)\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b")?,
        })
    }

    fn redact(&self, input: &str) -> String {
        let mut output = input.to_owned();
        for identity in &self.identities {
            output = identity.replace_all(&output, "<identity>").into_owned();
        }
        output = self
            .secrets
            .replace_all(&output, "$1=<redacted>")
            .into_owned();
        output = self
            .bearer
            .replace_all(&output, "Bearer <redacted>")
            .into_owned();
        output = self
            .url_query
            .replace_all(&output, "$1?<redacted>")
            .into_owned();
        output = self
            .peer_id
            .replace_all(&output, "$1=<redacted>")
            .into_owned();
        output = self.email.replace_all(&output, "<email>").into_owned();
        self.mac.replace_all(&output, "<mac>").into_owned()
    }
}

pub fn export(destination: &Path) -> ResultType<DiagnosticExportReport> {
    #[cfg(windows)]
    {
        if !windows_diagnostic_export_is_elevated() && windows_service_logs_present() {
            return export_with_windows_elevation(destination);
        }
    }
    export_direct(destination)
}

fn export_direct(destination: &Path) -> ResultType<DiagnosticExportReport> {
    let roots = diagnostic_roots();
    export_from_roots(destination, &roots)
}

#[cfg(windows)]
pub fn export_elevated_worker(destination: &Path) -> ResultType<DiagnosticExportReport> {
    if !windows_diagnostic_export_is_elevated() {
        bail!("elevated diagnostic worker requires an administrator token");
    }
    export_direct(destination)
}

#[cfg(windows)]
fn windows_diagnostic_export_is_elevated() -> bool {
    crate::platform::is_root() || crate::platform::is_elevated(None).unwrap_or(false)
}

#[cfg(windows)]
fn export_with_windows_elevation(destination: &Path) -> ResultType<DiagnosticExportReport> {
    validate_destination(destination)?;
    let executable = std::env::current_exe().context("failed to locate RustAdmin executable")?;
    let status = runas::Command::new(executable)
        .arg("--export-diagnostics-elevated")
        .arg(destination)
        .show(false)
        .force_prompt(true)
        .status()
        .context("failed to start elevated diagnostic exporter")?;
    if !status.success() {
        bail!(
            "elevated diagnostic exporter was cancelled or failed with status {}",
            status
        );
    }
    report_from_archive(destination)
}

#[cfg(windows)]
fn windows_service_logs_present() -> bool {
    crate::platform::is_installed()
        || windows_service_roots()
            .iter()
            .any(|(_, root)| root.is_dir())
}

fn diagnostic_roots() -> Vec<(String, PathBuf)> {
    let mut roots = vec![("logs".to_owned(), Config::log_path())];
    let app_dir = APP_DIR.read().unwrap().clone();
    if !app_dir.is_empty() {
        roots.push((
            "flutter".to_owned(),
            PathBuf::from(app_dir).join("diagnostics"),
        ));
    }
    #[cfg(windows)]
    {
        roots.extend(windows_service_roots());
    }
    roots
}

#[cfg(windows)]
fn windows_service_roots() -> Vec<(String, PathBuf)> {
    let mut roots = Vec::new();
    let system_root = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    roots.push((
        "service-localservice".to_owned(),
        system_root.join("ServiceProfiles/LocalService/AppData/Roaming/RustAdmin/log"),
    ));
    roots.push((
        "service-systemprofile".to_owned(),
        system_root.join("System32/config/systemprofile/AppData/Roaming/RustAdmin/log"),
    ));
    let program_data = std::env::var_os("ProgramData")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
    roots.push((
        "service-programdata".to_owned(),
        program_data.join("RustAdmin/log"),
    ));
    roots
}

fn export_from_roots(
    destination: &Path,
    roots: &[(String, PathBuf)],
) -> ResultType<DiagnosticExportReport> {
    validate_destination(destination)?;
    let redactor = DiagnosticRedactor::new()?;
    let mut files = Vec::new();
    for (label, root) in roots {
        let mut root_files = Vec::new();
        collect_files(root, root, label, 0, &mut root_files);
        root_files.sort_by(|left, right| right.modified.cmp(&left.modified));
        root_files.truncate(MAX_DIAGNOSTIC_FILES_PER_ROOT);
        #[cfg(windows)]
        if label == "service-localservice"
            && crate::platform::is_installed()
            && root_files.is_empty()
        {
            bail!("installed service logs are present but unavailable to diagnostic export");
        }
        files.extend(root_files);
    }
    files.sort_by(|left, right| right.modified.cmp(&left.modified));
    files.truncate(MAX_DIAGNOSTIC_FILES);

    let temporary = temporary_archive_path(destination);
    let write_result = write_archive(&temporary, &files, &redactor);
    let (included_files, source_bytes, truncated_files) = match write_result {
        Ok(summary) => summary,
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }
    };

    if destination.exists() {
        fs::remove_file(destination).with_context(|| {
            format!(
                "failed to replace existing diagnostic archive {}",
                destination.display()
            )
        })?;
    }
    fs::rename(&temporary, destination).with_context(|| {
        format!(
            "failed to publish diagnostic archive {}",
            destination.display()
        )
    })?;
    let archive_bytes = fs::metadata(destination)
        .map(|metadata| metadata.len())
        .unwrap_or_default();
    Ok(DiagnosticExportReport {
        path: destination.display().to_string(),
        files: included_files,
        source_bytes,
        archive_bytes,
        truncated_files,
    })
}

fn validate_destination(destination: &Path) -> ResultType<()> {
    if destination
        .extension()
        .and_then(|extension| extension.to_str())
        .is_none_or(|extension| !extension.eq_ignore_ascii_case("zip"))
    {
        bail!("diagnostic archive must use the .zip extension");
    }
    let Some(parent) = destination.parent() else {
        bail!("diagnostic archive has no parent directory");
    };
    if !parent.is_dir() {
        bail!("diagnostic archive parent directory does not exist");
    }
    if fs::symlink_metadata(destination)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        bail!("diagnostic archive destination must not be a symbolic link");
    }
    Ok(())
}

fn collect_files(
    root: &Path,
    directory: &Path,
    label: &str,
    depth: usize,
    output: &mut Vec<DiagnosticFile>,
) {
    if depth > MAX_DIRECTORY_DEPTH || output.len() >= MAX_DIAGNOSTIC_FILES * 4 {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            collect_files(root, &path, label, depth + 1, output);
            continue;
        }
        if !metadata.is_file() || !is_diagnostic_file(&path) {
            continue;
        }
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        let Some(entry_name) = archive_entry_name(label, relative) else {
            continue;
        };
        output.push(DiagnosticFile {
            path,
            entry_name,
            modified: metadata.modified().unwrap_or(UNIX_EPOCH),
        });
        if output.len() >= MAX_DIAGNOSTIC_FILES * 4 {
            return;
        }
    }
}

fn is_diagnostic_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "log" | "txt" | "json"
            )
        })
}

fn archive_entry_name(label: &str, relative: &Path) -> Option<String> {
    let mut components = vec![label.to_owned()];
    for component in relative.components() {
        let Component::Normal(component) = component else {
            return None;
        };
        let value = component.to_string_lossy();
        if value.is_empty() || value == "." || value == ".." {
            return None;
        }
        components.push(value.replace(['/', '\\'], "_"));
    }
    Some(components.join("/"))
}

fn write_archive(
    temporary: &Path,
    files: &[DiagnosticFile],
    redactor: &DiagnosticRedactor,
) -> ResultType<(usize, u64, usize)> {
    let output = File::create(temporary)
        .with_context(|| format!("failed to create {}", temporary.display()))?;
    let mut zip = ZipWriter::new(output);
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .unix_permissions(0o600);
    let mut included_files = 0;
    let mut source_bytes = 0u64;
    let mut truncated_files = 0;

    let manifest = format!(
        "app=RustAdmin\nversion={} rev {}\nbuild_date={}\nos={}\narch={}\ntimestamp_ms={}\nredaction=credentials, identity, URL queries, peer identifiers, email, MAC\nlimits=files:{}, per_file_bytes:{}, total_source_bytes:{}\n",
        crate::VERSION,
        crate::RUSTADMIN_REVISION,
        crate::BUILD_DATE,
        std::env::consts::OS,
        std::env::consts::ARCH,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default(),
        MAX_DIAGNOSTIC_FILES,
        MAX_FILE_BYTES,
        MAX_TOTAL_SOURCE_BYTES,
    );
    zip.start_file("manifest.txt", options)?;
    zip.write_all(manifest.as_bytes())?;

    for candidate in files {
        if source_bytes >= MAX_TOTAL_SOURCE_BYTES {
            break;
        }
        let remaining = MAX_TOTAL_SOURCE_BYTES - source_bytes;
        let file_limit = MAX_FILE_BYTES.min(remaining);
        let Ok((bytes, truncated)) = read_tail(&candidate.path, file_limit) else {
            continue;
        };
        let text = String::from_utf8_lossy(&bytes);
        let redacted = redactor.redact(&text);
        zip.start_file(&candidate.entry_name, options)?;
        zip.write_all(redacted.as_bytes())?;
        source_bytes = source_bytes.saturating_add(bytes.len() as u64);
        included_files += 1;
        if truncated {
            truncated_files += 1;
        }
    }
    let summary = DiagnosticArchiveSummary {
        files: included_files,
        source_bytes,
        truncated_files,
    };
    zip.start_file(DIAGNOSTIC_SUMMARY_ENTRY, options)?;
    zip.write_all(serde_json::to_string(&summary)?.as_bytes())?;
    zip.finish()?;
    Ok((included_files, source_bytes, truncated_files))
}

fn report_from_archive(destination: &Path) -> ResultType<DiagnosticExportReport> {
    let archive_bytes = fs::metadata(destination)
        .with_context(|| format!("failed to inspect {}", destination.display()))?
        .len();
    let mut archive = ZipArchive::new(
        File::open(destination)
            .with_context(|| format!("failed to open {}", destination.display()))?,
    )?;
    let mut summary_json = String::new();
    archive
        .by_name(DIAGNOSTIC_SUMMARY_ENTRY)
        .context("elevated diagnostic archive has no summary")?
        .read_to_string(&mut summary_json)?;
    let summary: DiagnosticArchiveSummary = serde_json::from_str(&summary_json)
        .context("elevated diagnostic archive summary is invalid")?;
    Ok(DiagnosticExportReport {
        path: destination.display().to_string(),
        files: summary.files,
        source_bytes: summary.source_bytes,
        archive_bytes,
        truncated_files: summary.truncated_files,
    })
}

fn read_tail(path: &Path, limit: u64) -> ResultType<(Vec<u8>, bool)> {
    if limit == 0 {
        return Ok((Vec::new(), true));
    }
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    let truncated = length > limit;
    if truncated {
        file.seek(SeekFrom::Start(length - limit))?;
    }
    let mut bytes = Vec::with_capacity(length.min(limit) as usize);
    file.take(limit).read_to_end(&mut bytes)?;
    if truncated {
        if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
            bytes.drain(..=newline);
        }
    }
    Ok((bytes, truncated))
}

fn temporary_archive_path(destination: &Path) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("RustAdmin-diagnostics.zip");
    destination.with_file_name(format!(
        ".{file_name}.{}.{}.tmp",
        std::process::id(),
        suffix
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn test_dir(name: &str) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("test clock")
            .as_nanos();
        std::env::temp_dir().join(format!("rustadmin-diagnostics-{name}-{suffix}"))
    }

    #[test]
    fn redactor_removes_credentials_and_identity() {
        let redactor = DiagnosticRedactor::new().expect("redactor");
        let input = "password=hunter2 token:abc Bearer xyz peer_id=123 email=a@example.com mac=00:11:22:33:44:55 https://example.test/path?token=abc";
        let output = redactor.redact(input);
        assert!(!output.contains("hunter2"));
        assert!(!output.contains("Bearer xyz"));
        assert!(!output.contains("peer_id=123"));
        assert!(!output.contains("a@example.com"));
        assert!(!output.contains("00:11:22:33:44:55"));
        assert!(!output.contains("?token=abc"));
    }

    #[test]
    fn read_tail_is_bounded_and_starts_after_partial_line() {
        let directory = test_dir("tail");
        fs::create_dir_all(&directory).expect("create test directory");
        let path = directory.join("test.log");
        fs::write(&path, b"old-line\nnew-line\n").expect("write test log");

        let (bytes, truncated) = read_tail(&path, 12).expect("read tail");
        assert!(truncated);
        assert_eq!(String::from_utf8(bytes).expect("utf8"), "new-line\n");
        fs::remove_dir_all(directory).expect("remove test directory");
    }

    #[test]
    fn export_is_bounded_redacted_and_uses_safe_entries() {
        let directory = test_dir("archive");
        let logs = directory.join("logs/role");
        fs::create_dir_all(&logs).expect("create log directory");
        fs::write(
            logs.join("current.log"),
            b"token=private-value\nmessage=ok\n",
        )
        .expect("write log");
        let output = directory.join("diagnostics.zip");

        let report = export_from_roots(&output, &[("logs".to_owned(), directory.join("logs"))])
            .expect("export diagnostics");
        assert_eq!(report.files, 1);
        let inspected = report_from_archive(&output).expect("inspect diagnostic archive");
        assert_eq!(inspected.files, report.files);
        assert_eq!(inspected.source_bytes, report.source_bytes);
        assert_eq!(inspected.truncated_files, report.truncated_files);
        assert_eq!(inspected.archive_bytes, report.archive_bytes);
        let mut archive =
            ZipArchive::new(File::open(&output).expect("open archive")).expect("read archive");
        let mut log = String::new();
        archive
            .by_name("logs/role/current.log")
            .expect("log entry")
            .read_to_string(&mut log)
            .expect("read log entry");
        assert!(!log.contains("private-value"));
        assert!(log.contains("message=ok"));
        fs::remove_dir_all(directory).expect("remove test directory");
    }

    #[test]
    fn export_reserves_a_bounded_quota_for_each_log_root() {
        let directory = test_dir("root-quota");
        let interactive = directory.join("interactive");
        let service = directory.join("service");
        fs::create_dir_all(&interactive).expect("create interactive logs");
        fs::create_dir_all(&service).expect("create service logs");
        for index in 0..40 {
            fs::write(
                interactive.join(format!("interactive-{index}.log")),
                b"interactive\n",
            )
            .expect("write interactive log");
            fs::write(service.join(format!("service-{index}.log")), b"service\n")
                .expect("write service log");
        }
        let output = directory.join("diagnostics.zip");

        let report = export_from_roots(
            &output,
            &[
                ("logs".to_owned(), interactive),
                ("service-localservice".to_owned(), service),
            ],
        )
        .expect("export diagnostics");
        assert_eq!(report.files, MAX_DIAGNOSTIC_FILES_PER_ROOT * 2);

        let mut archive =
            ZipArchive::new(File::open(&output).expect("open archive")).expect("read archive");
        let mut interactive_files = 0;
        let mut service_files = 0;
        for index in 0..archive.len() {
            let name = archive
                .by_index(index)
                .expect("archive entry")
                .name()
                .to_owned();
            interactive_files += usize::from(name.starts_with("logs/"));
            service_files += usize::from(name.starts_with("service-localservice/"));
        }
        assert_eq!(interactive_files, MAX_DIAGNOSTIC_FILES_PER_ROOT);
        assert_eq!(service_files, MAX_DIAGNOSTIC_FILES_PER_ROOT);
        fs::remove_dir_all(directory).expect("remove test directory");
    }
}
