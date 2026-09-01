use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

use hbb_common::{
    anyhow::{anyhow, Context},
    config::{self, Config, PeerConfig},
    ResultType,
};

const JOURNAL_VERSION: u32 = 1;
const MAX_MUTATION_IDS: usize = 4_096;
const MAX_MUTATION_ID_BYTES: usize = 1_024;
const JOURNAL_FILE: &str = "peer-security-mutation.toml";

lazy_static::lazy_static! {
    static ref MUTATION_LOCK: Mutex<()> = Mutex::new(());
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum PeerSecurityMutationKind {
    ResetPairing,
    RemovePeer,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
struct PeerSecurityMutationJournal {
    version: u32,
    committed: bool,
    operation: PeerSecurityMutationKind,
    peer_config_id: String,
    config_ids: Vec<String>,
    quic_peer_ids: Vec<String>,
}

impl PeerSecurityMutationJournal {
    fn prepare(peer_config_id: &str, operation: PeerSecurityMutationKind) -> ResultType<Self> {
        let quic_peer_ids = planned_quic_peer_ids(peer_config_id)?;
        let config_ids = super::peer_security_config_ids(peer_config_id, &quic_peer_ids);
        let journal = Self {
            version: JOURNAL_VERSION,
            committed: false,
            operation,
            peer_config_id: peer_config_id.to_owned(),
            config_ids,
            quic_peer_ids,
        };
        journal.validate()?;
        Ok(journal)
    }

    fn validate(&self) -> ResultType<()> {
        if self.version != JOURNAL_VERSION {
            return Err(anyhow!("unsupported peer-security journal version"));
        }
        validate_ids(&self.config_ids)?;
        validate_ids(&self.quic_peer_ids)?;
        if self.peer_config_id.is_empty()
            || self.peer_config_id.len() > MAX_MUTATION_ID_BYTES
            || self.peer_config_id.contains('\0')
            || !self.config_ids.contains(&self.peer_config_id)
        {
            return Err(anyhow!("invalid peer-security journal peer id"));
        }
        Ok(())
    }
}

fn validate_ids(ids: &[String]) -> ResultType<()> {
    if ids.len() > MAX_MUTATION_IDS {
        return Err(anyhow!("peer-security journal contains too many ids"));
    }
    let mut unique = HashSet::with_capacity(ids.len());
    for id in ids {
        if id.is_empty()
            || id.len() > MAX_MUTATION_ID_BYTES
            || id.contains('\0')
            || !unique.insert(id)
        {
            return Err(anyhow!("peer-security journal contains an invalid id"));
        }
    }
    Ok(())
}

#[cfg(feature = "quic-transport")]
fn planned_quic_peer_ids(peer_id: &str) -> ResultType<Vec<String>> {
    let records = crate::quic_transport::paired_peers()?;
    let Some(target) = records.iter().find(|record| record.peer_id == peer_id) else {
        return Ok(Vec::new());
    };
    let mut ids = records
        .iter()
        .filter(|record| {
            record.identity_key == target.identity_key
                && record.certificate_pin == target.certificate_pin
        })
        .map(|record| record.peer_id.clone())
        .collect::<Vec<_>>();
    ids.sort();
    ids.dedup();
    Ok(ids)
}

#[cfg(not(feature = "quic-transport"))]
fn planned_quic_peer_ids(_peer_id: &str) -> ResultType<Vec<String>> {
    Ok(Vec::new())
}

fn journal_path() -> PathBuf {
    Config::path(JOURNAL_FILE)
}

fn load_journal(path: &Path) -> ResultType<Option<PeerSecurityMutationJournal>> {
    let encoded = match fs::read_to_string(path) {
        Ok(encoded) => encoded,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let journal = hbb_common::toml::from_str::<PeerSecurityMutationJournal>(&encoded)
        .context("invalid peer-security mutation journal")?;
    journal.validate()?;
    Ok(Some(journal))
}

fn persist_journal(path: &Path, journal: &PeerSecurityMutationJournal) -> ResultType<()> {
    config::store_path(path.to_path_buf(), journal)
        .context("failed to persist peer-security mutation journal")
}

fn cleanup_journal(path: &Path) {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => hbb_common::log::warn!(
            "Failed to remove committed peer-security mutation journal: {error}"
        ),
    }
}

trait PeerSecurityMutationBackend {
    fn remove_quic_ids(&mut self, ids: &[String]) -> ResultType<Vec<String>>;
    fn clear_pairing(&mut self, peer_config_id: &str) -> ResultType<bool>;
    fn remove_peer_config(&mut self, peer_config_id: &str) -> ResultType<bool>;
}

struct SystemPeerSecurityMutationBackend;

impl PeerSecurityMutationBackend for SystemPeerSecurityMutationBackend {
    fn remove_quic_ids(&mut self, ids: &[String]) -> ResultType<Vec<String>> {
        #[cfg(feature = "quic-transport")]
        return crate::quic_transport::forget_paired_peer_ids(ids);
        #[cfg(not(feature = "quic-transport"))]
        {
            let _ = ids;
            Ok(Vec::new())
        }
    }

    fn clear_pairing(&mut self, peer_config_id: &str) -> ResultType<bool> {
        let mut config = PeerConfig::load(peer_config_id);
        let changed = super::clear_peer_pairing_options(&mut config);
        if changed {
            config.store_result(peer_config_id)?;
            hbb_common::log::info!("Cleared paired trust state for {peer_config_id}");
        }
        Ok(changed)
    }

    fn remove_peer_config(&mut self, peer_config_id: &str) -> ResultType<bool> {
        PeerConfig::remove_result(peer_config_id)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PeerSecurityMutationResult {
    pub cleared_peer_config_ids: Vec<String>,
    pub removed_quic_peer_ids: Vec<String>,
    pub removed_peer_config: bool,
}

fn apply_journal<B: PeerSecurityMutationBackend>(
    journal: &PeerSecurityMutationJournal,
    backend: &mut B,
) -> ResultType<PeerSecurityMutationResult> {
    let mut result = PeerSecurityMutationResult {
        removed_quic_peer_ids: backend.remove_quic_ids(&journal.quic_peer_ids)?,
        ..Default::default()
    };
    for id in &journal.config_ids {
        if backend.clear_pairing(id)? {
            result.cleared_peer_config_ids.push(id.clone());
        }
    }
    if journal.operation == PeerSecurityMutationKind::RemovePeer {
        result.removed_peer_config = backend.remove_peer_config(&journal.peer_config_id)?;
    }
    Ok(result)
}

fn complete_journal<B: PeerSecurityMutationBackend>(
    path: &Path,
    mut journal: PeerSecurityMutationJournal,
    backend: &mut B,
) -> ResultType<PeerSecurityMutationResult> {
    if journal.committed {
        cleanup_journal(path);
        return Ok(PeerSecurityMutationResult::default());
    }
    let result = apply_journal(&journal, backend)?;
    journal.committed = true;
    persist_journal(path, &journal)?;
    cleanup_journal(path);
    Ok(result)
}

fn recover_pending_with<B: PeerSecurityMutationBackend>(
    path: &Path,
    backend: &mut B,
) -> ResultType<PeerSecurityMutationResult> {
    match load_journal(path)? {
        Some(journal) => complete_journal(path, journal, backend),
        None => Ok(PeerSecurityMutationResult::default()),
    }
}

pub struct PeerSecurityRepository;

impl PeerSecurityRepository {
    pub fn recover_pending() -> ResultType<PeerSecurityMutationResult> {
        let _lock = MUTATION_LOCK.lock().unwrap();
        recover_pending_with(&journal_path(), &mut SystemPeerSecurityMutationBackend)
    }

    pub fn list() -> ResultType<Vec<super::PeerSecurityEntry>> {
        let _lock = MUTATION_LOCK.lock().unwrap();
        recover_pending_with(&journal_path(), &mut SystemPeerSecurityMutationBackend)?;
        super::peer_security_entries_impl()
    }

    pub fn reset_pairing(peer_config_id: &str) -> ResultType<PeerSecurityMutationResult> {
        Self::mutate(peer_config_id, PeerSecurityMutationKind::ResetPairing)
    }

    pub fn remove(peer_config_id: &str) -> ResultType<PeerSecurityMutationResult> {
        Self::mutate(peer_config_id, PeerSecurityMutationKind::RemovePeer)
    }

    fn mutate(
        peer_config_id: &str,
        operation: PeerSecurityMutationKind,
    ) -> ResultType<PeerSecurityMutationResult> {
        let _lock = MUTATION_LOCK.lock().unwrap();
        let path = journal_path();
        let mut backend = SystemPeerSecurityMutationBackend;
        recover_pending_with(&path, &mut backend)?;
        let journal = PeerSecurityMutationJournal::prepare(peer_config_id, operation)?;
        persist_journal(&path, &journal)?;
        complete_journal(&path, journal, &mut backend)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        quic_ids: HashSet<String>,
        paired_configs: HashSet<String>,
        peer_configs: HashSet<String>,
        fail_once_for: Option<String>,
    }

    impl PeerSecurityMutationBackend for FakeBackend {
        fn remove_quic_ids(&mut self, ids: &[String]) -> ResultType<Vec<String>> {
            Ok(ids
                .iter()
                .filter(|id| self.quic_ids.remove(*id))
                .cloned()
                .collect())
        }

        fn clear_pairing(&mut self, peer_config_id: &str) -> ResultType<bool> {
            if self.fail_once_for.as_deref() == Some(peer_config_id) {
                self.fail_once_for = None;
                return Err(anyhow!("injected pairing persistence failure"));
            }
            Ok(self.paired_configs.remove(peer_config_id))
        }

        fn remove_peer_config(&mut self, peer_config_id: &str) -> ResultType<bool> {
            Ok(self.peer_configs.remove(peer_config_id))
        }
    }

    fn test_journal(operation: PeerSecurityMutationKind) -> PeerSecurityMutationJournal {
        PeerSecurityMutationJournal {
            version: JOURNAL_VERSION,
            committed: false,
            operation,
            peer_config_id: "peer".to_owned(),
            config_ids: vec!["alias".to_owned(), "peer".to_owned()],
            quic_peer_ids: vec!["alias".to_owned(), "peer".to_owned()],
        }
    }

    fn test_journal_path(name: &str) -> PathBuf {
        static NEXT_PATH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        std::env::temp_dir()
            .join(format!(
                "rustadmin-peer-security-{}-{}-{name}",
                std::process::id(),
                NEXT_PATH.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ))
            .join("journal.toml")
    }

    #[test]
    fn journal_application_is_idempotent() {
        let journal = test_journal(PeerSecurityMutationKind::RemovePeer);
        let mut backend = FakeBackend {
            quic_ids: HashSet::from(["alias".to_owned(), "peer".to_owned()]),
            paired_configs: HashSet::from(["alias".to_owned(), "peer".to_owned()]),
            peer_configs: HashSet::from(["peer".to_owned()]),
            ..Default::default()
        };

        let first = apply_journal(&journal, &mut backend).unwrap();
        let second = apply_journal(&journal, &mut backend).unwrap();

        assert_eq!(first.removed_quic_peer_ids.len(), 2);
        assert_eq!(first.cleared_peer_config_ids.len(), 2);
        assert!(first.removed_peer_config);
        assert_eq!(second, PeerSecurityMutationResult::default());
    }

    #[test]
    fn prepared_journal_recovers_after_partial_failure() {
        let path = test_journal_path("recovery");
        let root = path.parent().unwrap().to_path_buf();
        let journal = test_journal(PeerSecurityMutationKind::ResetPairing);
        persist_journal(&path, &journal).unwrap();
        let mut backend = FakeBackend {
            quic_ids: HashSet::from(["alias".to_owned(), "peer".to_owned()]),
            paired_configs: HashSet::from(["alias".to_owned(), "peer".to_owned()]),
            fail_once_for: Some("alias".to_owned()),
            ..Default::default()
        };

        assert!(recover_pending_with(&path, &mut backend).is_err());
        assert!(path.exists());
        let recovered = recover_pending_with(&path, &mut backend).unwrap();

        assert_eq!(recovered.cleared_peer_config_ids.len(), 2);
        assert!(backend.quic_ids.is_empty());
        assert!(backend.paired_configs.is_empty());
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn committed_journal_never_replays_mutation() {
        let path = test_journal_path("committed");
        let root = path.parent().unwrap().to_path_buf();
        let mut journal = test_journal(PeerSecurityMutationKind::RemovePeer);
        journal.committed = true;
        persist_journal(&path, &journal).unwrap();
        let mut backend = FakeBackend {
            peer_configs: HashSet::from(["peer".to_owned()]),
            ..Default::default()
        };

        let result = recover_pending_with(&path, &mut backend).unwrap();

        assert_eq!(result, PeerSecurityMutationResult::default());
        assert!(backend.peer_configs.contains("peer"));
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
