pub(crate) fn diagnostic_build_identity() -> String {
    format!(
        "nativeVersion={}\nnativeRevision={}\nnativeBuildDate={}\n",
        crate::FULL_VERSION,
        crate::RUSTADMIN_REVISION,
        crate::BUILD_DATE,
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn metadata_comes_from_the_loaded_native_build() {
        let value = super::diagnostic_build_identity();
        assert!(value.contains(&format!("nativeVersion={}\n", crate::FULL_VERSION)));
        assert!(value.contains(&format!("nativeRevision={}\n", crate::RUSTADMIN_REVISION)));
        assert!(value.contains(&format!("nativeBuildDate={}\n", crate::BUILD_DATE)));
    }
}
