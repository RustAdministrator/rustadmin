use hbb_common::{
    compress::{decompress_limited, DEFAULT_DECOMPRESS_MAX_LEN},
    message_proto::{Clipboard, ClipboardFormat},
};

fn decode_utf8_content(entry: &Clipboard) -> Option<String> {
    let content = if entry.compress {
        decompress_limited(&entry.content, DEFAULT_DECOMPRESS_MAX_LEN).ok()?
    } else {
        if entry.content.len() > DEFAULT_DECOMPRESS_MAX_LEN {
            return None;
        }
        entry.content.to_vec()
    };
    String::from_utf8(content).ok()
}

#[cfg(any(target_os = "ios", test))]
pub(crate) fn first_text_clipboard(entries: &[Clipboard]) -> Option<String> {
    entries.iter().find_map(|entry| {
        (entry.format.enum_value() == Ok(ClipboardFormat::Text))
            .then(|| decode_utf8_content(entry))
            .flatten()
    })
}

#[cfg(any(target_os = "android", test))]
pub(crate) fn android_text_clipboards(entries: Vec<Clipboard>) -> Vec<Clipboard> {
    entries
        .into_iter()
        .filter_map(|mut entry| {
            if !matches!(
                entry.format.enum_value(),
                Ok(ClipboardFormat::Text | ClipboardFormat::Html)
            ) {
                return None;
            }
            let text = decode_utf8_content(&entry)?;
            entry.content = text.into_bytes().into();
            entry.compress = false;
            Some(entry)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_entry(content: &[u8]) -> Clipboard {
        Clipboard {
            content: content.to_vec().into(),
            format: ClipboardFormat::Text.into(),
            ..Default::default()
        }
    }

    fn compressed_text_entry(content: &[u8]) -> Clipboard {
        Clipboard {
            compress: true,
            content: hbb_common::compress::compress(content).into(),
            format: ClipboardFormat::Text.into(),
            ..Default::default()
        }
    }

    #[test]
    fn decodes_compressed_and_uncompressed_unicode_and_url() {
        let unicode = "日本語のクリップボード";
        let url = "https://example.com/path?q=1";

        assert_eq!(
            first_text_clipboard(&[text_entry(unicode.as_bytes())]),
            Some(unicode.to_owned())
        );
        assert_eq!(
            first_text_clipboard(&[text_entry(url.as_bytes())]),
            Some(url.to_owned())
        );
        assert_eq!(
            first_text_clipboard(&[compressed_text_entry(unicode.as_bytes())]),
            Some(unicode.to_owned())
        );
        assert_eq!(
            first_text_clipboard(&[compressed_text_entry(url.as_bytes())]),
            Some(url.to_owned())
        );
    }

    #[test]
    fn skips_mixed_formats_and_unknown_entries_until_text() {
        let entries = vec![
            Clipboard {
                content: b"<b>rich</b>".to_vec().into(),
                format: ClipboardFormat::Html.into(),
                ..Default::default()
            },
            Clipboard {
                content: vec![0, 1, 2].into(),
                format: ClipboardFormat::ImagePng.into(),
                ..Default::default()
            },
            Clipboard {
                content: vec![3, 4, 5].into(),
                format: hbb_common::protobuf::EnumOrUnknown::from_i32(777),
                ..Default::default()
            },
            text_entry(b"text after non-text entries"),
        ];

        assert_eq!(
            first_text_clipboard(&entries),
            Some("text after non-text entries".to_owned())
        );
    }

    #[test]
    fn skips_invalid_utf8_and_compressed_entries_until_valid_text() {
        let entries = vec![
            text_entry(&[0xff, 0xfe]),
            Clipboard {
                compress: true,
                content: vec![0, 1, 2, 3].into(),
                format: ClipboardFormat::Text.into(),
                ..Default::default()
            },
            compressed_text_entry("fallback ✅".as_bytes()),
        ];

        assert_eq!(
            first_text_clipboard(&entries),
            Some("fallback ✅".to_owned())
        );
    }

    #[test]
    fn returns_none_when_entries_have_no_valid_text() {
        let entries = vec![
            Clipboard {
                content: b"rtf".to_vec().into(),
                format: ClipboardFormat::Rtf.into(),
                ..Default::default()
            },
            Clipboard {
                content: b"special".to_vec().into(),
                format: ClipboardFormat::Special.into(),
                ..Default::default()
            },
            Clipboard {
                content: b"unknown".to_vec().into(),
                format: hbb_common::protobuf::EnumOrUnknown::from_i32(778),
                ..Default::default()
            },
        ];

        assert_eq!(first_text_clipboard(&entries), None);
    }

    #[test]
    fn rejects_oversized_raw_and_decompressed_text() {
        let oversized_raw = vec![b'a'; DEFAULT_DECOMPRESS_MAX_LEN + 1];
        let oversized_compressed = compressed_text_entry(&oversized_raw);

        assert_eq!(
            first_text_clipboard(&[
                text_entry(&oversized_raw),
                oversized_compressed,
                text_entry(b"bounded fallback"),
            ]),
            Some("bounded fallback".to_owned())
        );
    }

    #[test]
    fn android_prepares_text_and_html_together_and_clears_compression_flag() {
        let mut html = compressed_text_entry(b"<b>link</b>");
        html.format = ClipboardFormat::Html.into();
        let data = android_text_clipboards(vec![compressed_text_entry(b"link"), html]);
        assert_eq!(data.len(), 2);
        assert!(!data[0].compress && !data[1].compress);
        assert_eq!(data[0].content.as_ref(), b"link");
        assert_eq!(data[1].content.as_ref(), b"<b>link</b>");
    }

    #[test]
    fn android_drops_bad_text_instead_of_clearing_clipboard_with_empty_content() {
        let bad = Clipboard {
            compress: true,
            content: vec![0, 1, 2].into(),
            ..Default::default()
        };
        assert!(android_text_clipboards(vec![bad, text_entry(&[0xff])]).is_empty());
        let image = Clipboard {
            format: ClipboardFormat::ImagePng.into(),
            content: b"not text".to_vec().into(),
            ..Default::default()
        };
        assert!(android_text_clipboards(vec![image]).is_empty());
    }
}
