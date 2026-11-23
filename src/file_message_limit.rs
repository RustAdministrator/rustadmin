//! File messages that grow with the user's data, and streams that cannot carry them.
//!
//! A directory listing and the file list of a transfer are single messages. A QUIC file channel
//! carries at most 1 MiB per message (`Stream::file_message_limit`), which a folder with tens of
//! thousands of entries exceeds. Such a message must not be sent: the sender answers with an
//! error that the other side can show, and the session goes on.

use hbb_common::{
    message_proto::{file_action, message, Message},
    protobuf::Message as _,
};

#[cfg(any(not(target_os = "ios"), test))]
use hbb_common::{fs, message_proto::file_response};

fn kib(bytes: usize) -> usize {
    bytes.div_ceil(1024)
}

#[cfg(any(not(target_os = "ios"), test))]
fn listing_too_large(entries: usize, size: usize, limit: usize) -> String {
    format!(
        "This folder has too many entries to list over this connection ({} entries, {} KiB, \
         at most {} KiB). Open a subfolder, or transfer its subfolders one at a time.",
        entries,
        kib(size),
        kib(limit)
    )
}

/// The error to send in place of `message` when it is a directory listing that the stream
/// cannot carry. `limit` is `Stream::file_message_limit()`.
#[cfg(any(not(target_os = "ios"), test))]
pub(crate) fn oversize_listing_reply(message: &Message, limit: Option<usize>) -> Option<Message> {
    let limit = limit?;
    let Some(message::Union::FileResponse(response)) = &message.union else {
        return None;
    };
    let Some(file_response::Union::Dir(directory)) = &response.union else {
        return None;
    };
    let size = message.compute_size() as usize;
    if size <= limit {
        return None;
    }
    Some(fs::new_error(
        directory.id,
        listing_too_large(directory.entries.len(), size, limit),
        -1,
    ))
}

/// The same for a message that is already serialized.
#[cfg(any(not(target_os = "ios"), test))]
pub(crate) fn oversize_listing_reply_for_bytes(
    bytes: &[u8],
    limit: Option<usize>,
) -> Option<Message> {
    if bytes.len() <= limit? {
        return None;
    }
    let message = Message::parse_from_bytes(bytes).ok()?;
    oversize_listing_reply(&message, limit)
}

/// Why the file list of an upload cannot be sent over this stream, if it cannot.
pub(crate) fn upload_list_error(message: &Message, limit: Option<usize>) -> Option<String> {
    let limit = limit?;
    let Some(message::Union::FileAction(action)) = &message.union else {
        return None;
    };
    let Some(file_action::Union::Receive(receive)) = &action.union else {
        return None;
    };
    let size = message.compute_size() as usize;
    if size <= limit {
        return None;
    }
    Some(format!(
        "Too many files for one transfer over this connection ({} files, {} KiB, at most {} \
         KiB). Transfer the subfolders one at a time.",
        receive.files.len(),
        kib(size),
        kib(limit)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::message_proto::{FileAction, FileEntry, FileResponse, FileTransferBlock};

    const LIMIT: usize = 1024 * 1024;

    fn entries(count: usize) -> Vec<FileEntry> {
        (0..count)
            .map(|index| FileEntry {
                name: format!("entry-{:020}", index),
                ..Default::default()
            })
            .collect()
    }

    /// Entries whose listing is the largest that still fits, or the smallest that does not.
    fn entries_around_the_limit(fits: bool) -> Vec<FileEntry> {
        let size = |count: usize| fs::new_dir(7, "/".to_owned(), entries(count)).compute_size();
        // The largest count whose listing fits, by bisection.
        let (mut low, mut high) = (1usize, LIMIT / 8);
        while low + 1 < high {
            let middle = (low + high) / 2;
            if size(middle) as usize <= LIMIT {
                low = middle;
            } else {
                high = middle;
            }
        }
        entries(if fits { low } else { low + 1 })
    }

    fn error_of(message: &Message) -> (i32, String) {
        let error = message.file_response().error();
        (error.id, error.error.clone())
    }

    #[test]
    fn listing_above_the_limit_becomes_an_error_for_the_same_request() {
        let listing = fs::new_dir(7, "/".to_owned(), entries_around_the_limit(false));
        let reply = oversize_listing_reply(&listing, Some(LIMIT)).expect("an error reply");
        let (id, text) = error_of(&reply);
        assert_eq!(id, 7);
        assert!(text.contains("too many entries"), "{}", text);
        assert!((reply.compute_size() as usize) < 1024);

        let bytes = listing.write_to_bytes().unwrap();
        let reply = oversize_listing_reply_for_bytes(&bytes, Some(LIMIT)).expect("an error reply");
        assert_eq!(error_of(&reply).0, 7);
    }

    #[test]
    fn listing_that_fits_is_sent_as_it_is() {
        let listing = fs::new_dir(7, "/".to_owned(), entries_around_the_limit(true));
        assert!(listing.compute_size() as usize <= LIMIT);
        assert!(oversize_listing_reply(&listing, Some(LIMIT)).is_none());
        let bytes = listing.write_to_bytes().unwrap();
        assert!(oversize_listing_reply_for_bytes(&bytes, Some(LIMIT)).is_none());
    }

    #[test]
    fn stream_without_a_limit_carries_any_listing() {
        let listing = fs::new_dir(7, "/".to_owned(), entries_around_the_limit(false));
        assert!(oversize_listing_reply(&listing, None).is_none());
        let bytes = listing.write_to_bytes().unwrap();
        assert!(oversize_listing_reply_for_bytes(&bytes, None).is_none());
    }

    #[test]
    fn other_messages_are_never_replaced() {
        let mut response = FileResponse::new();
        response.set_block(FileTransferBlock {
            id: 7,
            data: vec![0u8; 64].into(),
            ..Default::default()
        });
        let mut block = Message::new();
        block.set_file_response(response);
        assert!(oversize_listing_reply(&block, Some(16)).is_none());
        assert!(oversize_listing_reply(&Message::new(), Some(0)).is_none());
        assert!(oversize_listing_reply_for_bytes(&[0xff; 64], Some(16)).is_none());
    }

    #[test]
    fn upload_file_list_is_checked_before_it_is_sent() {
        let fits = fs::new_receive(3, "/to".to_owned(), 0, entries(100), 0);
        assert!(upload_list_error(&fits, Some(LIMIT)).is_none());

        let large = fs::new_receive(3, "/to".to_owned(), 0, entries_around_the_limit(false), 0);
        assert!(large.compute_size() as usize > LIMIT);
        let text = upload_list_error(&large, Some(LIMIT)).expect("an error");
        assert!(text.contains("Too many files"), "{}", text);
        assert!(upload_list_error(&large, None).is_none());

        let mut other = Message::new();
        other.set_file_action(FileAction::new());
        assert!(upload_list_error(&other, Some(0)).is_none());
    }
}
