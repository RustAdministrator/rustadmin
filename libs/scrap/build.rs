use std::{
    env, fs,
    path::{Path, PathBuf},
    println,
};

#[cfg(target_os = "linux")]
const LOCAL_CODEC_ROOT_ENV: &str = "RUSTDESK_LINUX_CODEC_ROOT";
#[cfg(target_os = "macos")]
const LOCAL_CODEC_ROOT_ENV: &str = "RUSTDESK_MACOS_CODEC_ROOT";
#[cfg(target_os = "windows")]
const LOCAL_CODEC_ROOT_ENV: &str = "RUSTDESK_WINDOWS_CODEC_ROOT";
const CMAKE_PREFIX_PATH_ENV: &str = "CMAKE_PREFIX_PATH";
const IOS_CODEC_ROOT_ENV: &str = "RUSTDESK_IOS_CODEC_ROOT";

#[cfg(all(target_os = "linux", feature = "linux-pkg-config"))]
fn pkg_config_name(name: &str) -> &str {
    match name {
        "libvpx" => "vpx",
        _ => name,
    }
}

fn push_unique_path(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if paths.iter().all(|existing| existing != &path) {
        paths.push(path);
    }
}

fn push_prefix_candidate(paths: &mut Vec<PathBuf>, path: PathBuf) {
    push_unique_path(paths, path.clone());

    if let Some(parent) = path.parent() {
        if path.file_name().and_then(|name| name.to_str()) == Some("include")
            || path.file_name().and_then(|name| name.to_str()) == Some("lib")
        {
            push_unique_path(paths, parent.to_path_buf());
        }
    }

    for ancestor in path.ancestors() {
        if ancestor.join("include").is_dir() && ancestor.join("lib").is_dir() {
            push_unique_path(paths, ancestor.to_path_buf());
            break;
        }
    }
}

fn push_prefix_path_list(paths: &mut Vec<PathBuf>, value: &std::ffi::OsStr) {
    for raw_path in value.to_string_lossy().split([':', ';']) {
        if !raw_path.is_empty() {
            push_prefix_candidate(paths, PathBuf::from(raw_path));
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn local_codec_roots() -> Vec<PathBuf> {
    println!("cargo:rerun-if-env-changed={LOCAL_CODEC_ROOT_ENV}");
    let mut roots = Vec::new();

    if let Some(path) = env::var_os(LOCAL_CODEC_ROOT_ENV) {
        push_prefix_candidate(&mut roots, PathBuf::from(path));
    }

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rerun-if-env-changed={CMAKE_PREFIX_PATH_ENV}");
        if let Some(paths) = env::var_os(CMAKE_PREFIX_PATH_ENV) {
            push_prefix_path_list(&mut roots, &paths);
        }
    }

    if let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") {
        let manifest_dir = Path::new(&manifest_dir);
        if let Some(repo_root) = manifest_dir.ancestors().nth(2) {
            #[cfg(target_os = "linux")]
            let repo_local_root = repo_root.join(".local").join("linux-codecs");
            #[cfg(target_os = "macos")]
            let repo_local_root = repo_root.join(".local").join("macos-codecs");
            println!("cargo:rerun-if-changed={}", repo_local_root.display());
            if repo_local_root.exists() {
                push_prefix_candidate(&mut roots, repo_local_root);
            }
        }
    }

    roots
}

#[cfg(target_os = "windows")]
fn local_codec_roots() -> Vec<PathBuf> {
    fn push_unique(paths: &mut Vec<PathBuf>, path: PathBuf) {
        if paths.iter().all(|existing| existing != &path) {
            paths.push(path);
        }
    }

    println!("cargo:rerun-if-env-changed={LOCAL_CODEC_ROOT_ENV}");
    println!("cargo:rerun-if-env-changed={CMAKE_PREFIX_PATH_ENV}");

    let mut roots = Vec::new();
    if let Some(path) = env::var_os(LOCAL_CODEC_ROOT_ENV) {
        push_unique(&mut roots, PathBuf::from(path));
    }
    if let Some(paths) = env::var_os(CMAKE_PREFIX_PATH_ENV) {
        for path in env::split_paths(&paths) {
            push_unique(&mut roots, path);
        }
    }

    if let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") {
        let manifest_dir = Path::new(&manifest_dir);
        if let Some(repo_root) = manifest_dir.ancestors().nth(2) {
            let repo_local_root = repo_root.join(".local").join("windows-codecs");
            println!("cargo:rerun-if-changed={}", repo_local_root.display());
            if repo_local_root.exists() {
                push_unique(&mut roots, repo_local_root);
            }
        }
    }

    roots
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn local_codec_lib_name(name: &str) -> &str {
    match name {
        "libyuv" => "yuv",
        _ => name.trim_start_matches("lib"),
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn local_codec_header(include_dir: &Path, name: &str) -> PathBuf {
    match name {
        "libyuv" => include_dir.join("libyuv").join("convert.h"),
        "libvpx" => include_dir.join("vpx").join("vpx_encoder.h"),
        "aom" => include_dir.join("aom").join("aom.h"),
        _ => PathBuf::new(),
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn local_codec_shared_lib_ext() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "so"
    }
    #[cfg(target_os = "macos")]
    {
        "dylib"
    }
}

#[cfg(target_os = "windows")]
fn local_codec_header(include_dir: &Path, name: &str) -> PathBuf {
    match name {
        "libyuv" => include_dir.join("libyuv").join("convert.h"),
        "libvpx" => include_dir.join("vpx").join("vpx_encoder.h"),
        "aom" => include_dir.join("aom").join("aom.h"),
        _ => PathBuf::new(),
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn link_local_codec_root(name: &str) -> Option<Vec<PathBuf>> {
    for root in local_codec_roots() {
        let include_dir = root.join("include");
        let header = local_codec_header(&include_dir, name);
        if !header.exists() {
            continue;
        }

        let lib_dir = root.join("lib");
        let lib_name = local_codec_lib_name(name);
        let static_lib = lib_dir.join(format!("lib{lib_name}.a"));
        let shared_lib = lib_dir.join(format!("lib{lib_name}.{}", local_codec_shared_lib_ext()));
        if !static_lib.exists() && !shared_lib.exists() {
            continue;
        }

        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        if static_lib.exists() {
            println!("cargo:rustc-link-lib=static={lib_name}");
        } else {
            println!("cargo:rustc-link-lib={lib_name}");
        }
        println!("cargo:include={}", include_dir.display());
        return Some(vec![include_dir]);
    }

    None
}

fn ios_codec_roots() -> Vec<PathBuf> {
    println!("cargo:rerun-if-env-changed={IOS_CODEC_ROOT_ENV}");
    let mut roots = Vec::new();

    if let Some(path) = env::var_os(IOS_CODEC_ROOT_ENV) {
        push_prefix_candidate(&mut roots, PathBuf::from(path));
    }

    println!("cargo:rerun-if-env-changed={CMAKE_PREFIX_PATH_ENV}");
    if let Some(paths) = env::var_os(CMAKE_PREFIX_PATH_ENV) {
        push_prefix_path_list(&mut roots, &paths);
    }

    if let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") {
        let manifest_dir = Path::new(&manifest_dir);
        if let Some(repo_root) = manifest_dir.ancestors().nth(2) {
            let repo_local_root = repo_root.join(".local").join("ios-codecs");
            println!("cargo:rerun-if-changed={}", repo_local_root.display());
            if repo_local_root.exists() {
                push_prefix_candidate(&mut roots, repo_local_root);
            }
        }
    }

    roots
}

fn link_ios_codec_root(name: &str) -> Option<Vec<PathBuf>> {
    for root in ios_codec_roots() {
        let include_dir = root.join("include");
        let header = local_codec_header(&include_dir, name);
        if !header.exists() {
            continue;
        }

        let lib_dir = root.join("lib");
        let lib_name = local_codec_lib_name(name);
        let static_lib = lib_dir.join(format!("lib{lib_name}.a"));
        if !static_lib.exists() {
            continue;
        }

        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        println!("cargo:rustc-link-lib=static={lib_name}");
        println!("cargo:include={}", include_dir.display());
        return Some(vec![include_dir]);
    }

    None
}

#[cfg(target_os = "windows")]
fn local_codec_lib_names(name: &str) -> &'static [&'static str] {
    match name {
        "libyuv" => &["yuv", "libyuv"],
        "libvpx" => &["vpx", "libvpx"],
        "aom" => &["aom", "libaom"],
        _ => &[],
    }
}

#[cfg(target_os = "windows")]
fn link_local_codec_root(name: &str) -> Option<Vec<PathBuf>> {
    for root in local_codec_roots() {
        let include_dir = root.join("include");
        let header = local_codec_header(&include_dir, name);
        if !header.exists() {
            continue;
        }

        for lib_dir in [root.join("lib"), root.join("lib64")] {
            for lib_name in local_codec_lib_names(name) {
                let import_lib = lib_dir.join(format!("{lib_name}.lib"));
                let static_lib = lib_dir.join(format!("{lib_name}.a"));
                if !import_lib.exists() && !static_lib.exists() {
                    continue;
                }

                println!("cargo:rustc-link-search=native={}", lib_dir.display());
                println!("cargo:rustc-link-lib={lib_name}");
                println!("cargo:include={}", include_dir.display());
                return Some(vec![include_dir]);
            }
        }
    }

    None
}

#[cfg(all(target_os = "linux", feature = "linux-pkg-config"))]
fn try_link_pkg_config(name: &str) -> Option<Vec<PathBuf>> {
    let pc_name = pkg_config_name(name);
    pkg_config::probe_library(pc_name)
        .map(|lib| lib.include_paths)
        .ok()
}

#[cfg(all(target_os = "linux", feature = "linux-pkg-config"))]
fn link_pkg_config(name: &str) -> Vec<PathBuf> {
    // sometimes an override is needed
    let pc_name = pkg_config_name(name);
    if let Some(include_paths) = try_link_pkg_config(name) {
        return include_paths;
    }
    if let Some(include_paths) = link_local_codec_root(name) {
        return include_paths;
    }

    panic!(
        "unable to find '{}' development headers with pkg-config (feature linux-pkg-config is enabled).
        try installing '{}-dev' from your system package manager, or set {} to a local codec prefix.",
        pc_name,
        pc_name,
        LOCAL_CODEC_ROOT_ENV
    );
}
#[cfg(not(all(target_os = "linux", feature = "linux-pkg-config")))]
fn link_pkg_config(_name: &str) -> Vec<PathBuf> {
    unimplemented!()
}

/// Link vcpkg package.
fn link_vcpkg(mut path: PathBuf, name: &str) -> PathBuf {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "x86" {
        target_arch = "x86".to_owned();
    } else if target_arch == "loongarch64" {
        target_arch = "loongarch64".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    } else {
        target_arch = "arm".to_owned();
    }
    let mut target = if target_os == "macos" {
        if target_arch == "x64" {
            "x64-osx".to_owned()
        } else if target_arch == "arm64" {
            "arm64-osx".to_owned()
        } else {
            format!("{}-{}", target_arch, target_os)
        }
    } else if target_os == "windows" {
        "x64-windows-static".to_owned()
    } else {
        format!("{}-{}", target_arch, target_os)
    };
    if target_arch == "x86" {
        target = target.replace("x64", "x86");
    }
    println!("cargo:info={}", target);
    if let Ok(vcpkg_root) = std::env::var("VCPKG_INSTALLED_ROOT") {
        path = vcpkg_root.into();
    } else {
        path.push("installed");
    }
    path.push(target);
    println!(
        "cargo:rustc-link-lib=static={}",
        name.trim_start_matches("lib")
    );
    println!(
        "cargo:rustc-link-search={}",
        path.join("lib").to_str().unwrap()
    );
    let include = path.join("include");
    println!("cargo:include={}", include.to_str().unwrap());
    include
}

/// Link homebrew package(for Mac M1).
#[cfg(not(target_os = "linux"))]
fn link_homebrew_m1(name: &str) -> PathBuf {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_os != "macos" || target_arch != "aarch64" {
        panic!("Couldn't find VCPKG_ROOT, also can't fallback to homebrew because it's only for macos aarch64.");
    }
    let mut path = PathBuf::from("/opt/homebrew/Cellar");
    path.push(name);
    let entries = if let Ok(dir) = std::fs::read_dir(&path) {
        dir
    } else {
        panic!("Could not find package in {}. Make sure your homebrew and package {} are all installed.", path.to_str().unwrap(),&name);
    };
    let mut directories = entries
        .into_iter()
        .filter(|x| x.is_ok())
        .map(|x| x.unwrap().path())
        .filter(|x| x.is_dir())
        .collect::<Vec<_>>();
    // Find the newest version.
    directories.sort_unstable();
    if directories.is_empty() {
        panic!(
            "There's no installed version of {} in /opt/homebrew/Cellar",
            name
        );
    }
    path.push(directories.pop().unwrap());
    // Link the library.
    println!(
        "cargo:rustc-link-lib=static={}",
        name.trim_start_matches("lib")
    );
    // Add the library path.
    println!(
        "cargo:rustc-link-search={}",
        path.join("lib").to_str().unwrap()
    );
    // Add the include path.
    let include = path.join("include");
    println!("cargo:include={}", include.to_str().unwrap());
    include
}

/// Find package. By default, it will try to find vcpkg first, then homebrew(currently only for Mac M1).
/// If building for linux and feature "linux-pkg-config" is enabled, will try to use pkg-config
/// unless check fails (e.g. NO_PKG_CONFIG_libyuv=1)
fn find_package(name: &str) -> Vec<PathBuf> {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os == "ios" {
        if let Some(include_paths) = link_ios_codec_root(name) {
            return include_paths;
        }
        panic!(
            "Couldn't find iOS codec root for '{}'. Set {} or {} to an iOS codec prefix, or create .local/ios-codecs in the repository.",
            name,
            IOS_CODEC_ROOT_ENV,
            CMAKE_PREFIX_PATH_ENV
        );
    }

    let no_pkg_config_var_name = format!("NO_PKG_CONFIG_{name}");
    println!("cargo:rerun-if-env-changed={no_pkg_config_var_name}");
    if cfg!(all(target_os = "linux", feature = "linux-pkg-config")) {
        if std::env::var(&no_pkg_config_var_name).as_deref() != Ok("1") {
            return link_pkg_config(name);
        }
        #[cfg(all(target_os = "linux", feature = "linux-pkg-config"))]
        if let Some(include_paths) = link_local_codec_root(name) {
            return include_paths;
        }
        panic!(
            "pkg-config lookup for '{}' was disabled via {}=1, but no local codec was found in RUSTDESK_LINUX_CODEC_ROOT.",
            name,
            no_pkg_config_var_name
        );
    }

    #[cfg(target_os = "windows")]
    if let Some(include_paths) = link_local_codec_root(name) {
        return include_paths;
    }

    #[cfg(target_os = "macos")]
    if let Some(include_paths) = link_local_codec_root(name) {
        return include_paths;
    }

    if let Ok(vcpkg_root) = std::env::var("VCPKG_ROOT") {
        vec![link_vcpkg(vcpkg_root.into(), name)]
    } else {
        #[cfg(target_os = "linux")]
        if let Some(include_paths) = link_local_codec_root(name) {
            return include_paths;
        }

        #[cfg(target_os = "linux")]
        panic!(
            "Couldn't find VCPKG_ROOT and no local codec root for '{}' was found. Set {} to a codec prefix or create .local/linux-codecs in the repository.",
            name,
            LOCAL_CODEC_ROOT_ENV
        );

        #[cfg(target_os = "windows")]
        panic!(
            "Couldn't find VCPKG_ROOT and no Windows codec root for '{}' was found. Set {} or CMAKE_PREFIX_PATH to codec prefixes, or create .local/windows-codecs in the repository.",
            name,
            LOCAL_CODEC_ROOT_ENV
        );

        #[cfg(all(not(target_os = "linux"), not(target_os = "windows")))]
        {
            // Try using homebrew
            vec![link_homebrew_m1(name)]
        }
    }
}

fn generate_bindings(
    ffi_header: &Path,
    include_paths: &[PathBuf],
    ffi_rs: &Path,
    exact_file: &Path,
    regex: &str,
) {
    let mut b = bindgen::builder()
        .header(ffi_header.to_str().unwrap())
        .allowlist_type(regex)
        .allowlist_var(regex)
        .allowlist_function(regex)
        .rustified_enum(regex)
        .trust_clang_mangling(false)
        .layout_tests(false) // breaks 32/64-bit compat
        .generate_comments(false); // comments have prefix /*!\

    for dir in include_paths {
        b = b.clang_arg(format!("-I{}", dir.display()));
    }

    b.generate().unwrap().write_to_file(ffi_rs).unwrap();
    fs::copy(ffi_rs, exact_file).ok(); // ignore failure
}

fn gen_vcpkg_package(package: &str, ffi_header: &str, generated: &str, regex: &str) {
    let includes = find_package(package);
    let src_dir = env::var_os("CARGO_MANIFEST_DIR").unwrap();
    let src_dir = Path::new(&src_dir);
    let out_dir = env::var_os("OUT_DIR").unwrap();
    let out_dir = Path::new(&out_dir);

    let ffi_header = src_dir.join("src").join("bindings").join(ffi_header);
    println!("rerun-if-changed={}", ffi_header.display());
    for dir in &includes {
        println!("rerun-if-changed={}", dir.display());
    }

    let ffi_rs = out_dir.join(generated);
    let exact_file = src_dir.join("generated").join(generated);
    generate_bindings(&ffi_header, &includes, &ffi_rs, &exact_file, regex);
}

// If you have problems installing ffmpeg, you can download $VCPKG_ROOT/installed from ci
// Linux require link in hwcodec
/*
fn ffmpeg() {
    // ffmpeg
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let static_libs = vec!["avcodec", "avutil", "avformat"];
    static_libs.iter().for_each(|lib| {
        find_package(lib);
    });
    if target_os == "windows" {
        println!("cargo:rustc-link-lib=static=libmfx");
    }

    // os
    let dyn_libs: Vec<&str> = if target_os == "windows" {
        ["User32", "bcrypt", "ole32", "advapi32"].to_vec()
    } else if target_os == "linux" {
        let mut v = ["va", "va-drm", "va-x11", "vdpau", "X11", "stdc++"].to_vec();
        if target_arch == "x86_64" {
            v.push("z");
        }
        v
    } else if target_os == "macos" || target_os == "ios" {
        ["c++", "m"].to_vec()
    } else if target_os == "android" {
        ["z", "m", "android", "atomic"].to_vec()
    } else {
        panic!("unsupported os");
    };
    dyn_libs
        .iter()
        .map(|lib| println!("cargo:rustc-link-lib={}", lib))
        .count();

    if target_os == "macos" || target_os == "ios" {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=CoreVideo");
        println!("cargo:rustc-link-lib=framework=CoreMedia");
        println!("cargo:rustc-link-lib=framework=VideoToolbox");
        println!("cargo:rustc-link-lib=framework=AVFoundation");
    }
}
*/

fn main() {
    // in this crate, these are also valid configurations
    println!("cargo:rustc-check-cfg=cfg(dxgi,quartz,x11)");

    // there is problem with cfg(target_os) in build.rs, so use our workaround
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();

    // note: all link symbol names in x86 (32-bit) are prefixed wth "_".
    // run "rustup show" to show current default toolchain, if it is stable-x86-pc-windows-msvc,
    // please install x64 toolchain by "rustup toolchain install stable-x86_64-pc-windows-msvc",
    // then set x64 to default by "rustup default stable-x86_64-pc-windows-msvc"
    let target = target_build_utils::TargetInfo::new();
    if target.unwrap().target_pointer_width() != "64" {
        // panic!("Only support 64bit system");
    }
    env::remove_var("CARGO_CFG_TARGET_FEATURE");
    env::set_var("CARGO_CFG_TARGET_FEATURE", "crt-static");

    find_package("libyuv");
    gen_vcpkg_package("libvpx", "vpx_ffi.h", "vpx_ffi.rs", "^[vV].*");
    gen_vcpkg_package("aom", "aom_ffi.h", "aom_ffi.rs", "^(aom|AOM|OBU|AV1).*");
    gen_vcpkg_package("libyuv", "yuv_ffi.h", "yuv_ffi.rs", ".*");
    // ffmpeg();

    if target_os == "ios" {
        // nothing
    } else if target_os == "android" {
        println!("cargo:rustc-cfg=android");
    } else if cfg!(windows) {
        // The first choice is Windows because DXGI is amazing.
        println!("cargo:rustc-cfg=dxgi");
    } else if cfg!(target_os = "macos") {
        // Quartz is second because macOS is the (annoying) exception.
        println!("cargo:rustc-cfg=quartz");
    } else if cfg!(unix) {
        // On UNIX we pray that X11 (with XCB) is available.
        println!("cargo:rustc-cfg=x11");
    }
}
