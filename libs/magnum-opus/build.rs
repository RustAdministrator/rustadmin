use std::{
    env,
    path::{Path, PathBuf},
};

#[cfg(target_os = "linux")]
const LOCAL_CODEC_ROOT_ENV: &str = "RUSTDESK_LINUX_CODEC_ROOT";
#[cfg(target_os = "windows")]
const LOCAL_CODEC_ROOT_ENV: &str = "RUSTDESK_WINDOWS_CODEC_ROOT";
#[cfg(target_os = "windows")]
const CMAKE_PREFIX_PATH_ENV: &str = "CMAKE_PREFIX_PATH";

#[cfg(target_os = "linux")]
fn local_codec_root() -> Option<PathBuf> {
    println!("cargo:rerun-if-env-changed={LOCAL_CODEC_ROOT_ENV}");
    if let Some(path) = env::var_os(LOCAL_CODEC_ROOT_ENV) {
        return Some(PathBuf::from(path));
    }

    let manifest_dir = env::var_os("CARGO_MANIFEST_DIR")?;
    let manifest_dir = Path::new(&manifest_dir);
    let repo_root = manifest_dir.ancestors().nth(2)?;
    let repo_local_root = repo_root.join(".local").join("linux-codecs");
    println!("cargo:rerun-if-changed={}", repo_local_root.display());
    repo_local_root.exists().then_some(repo_local_root)
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

#[cfg(target_os = "linux")]
fn push_unique(include_paths: &mut Vec<PathBuf>, path: PathBuf) {
    if include_paths.iter().all(|existing| existing != &path) {
        include_paths.push(path);
    }
}

#[cfg(target_os = "linux")]
fn normalize_include_paths(mut include_paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut extra_paths = Vec::new();
    for include_path in &include_paths {
        if include_path.file_name().and_then(|name| name.to_str()) == Some("opus") {
            if let Some(parent) = include_path.parent() {
                if parent.join("opus").join("opus_multistream.h").exists() {
                    push_unique(&mut extra_paths, parent.to_path_buf());
                }
            }
        }
    }
    include_paths.extend(extra_paths);
    include_paths
}

#[cfg(target_os = "linux")]
fn link_local_codec_root(name: &str) -> Option<Vec<PathBuf>> {
    let root = local_codec_root()?;
    let include_dir = root.join("include");
    let header = include_dir.join("opus").join("opus_multistream.h");
    if !header.exists() {
        return None;
    }

    let lib_dir = root.join("lib");
    let static_lib = lib_dir.join(format!("lib{name}.a"));
    let shared_lib = lib_dir.join(format!("lib{name}.so"));
    if !static_lib.exists() && !shared_lib.exists() {
        return None;
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    if static_lib.exists() {
        println!("cargo:rustc-link-lib=static={name}");
    } else {
        println!("cargo:rustc-link-lib={name}");
    }
    println!("cargo:include={}", include_dir.display());
    Some(vec![include_dir])
}

#[cfg(target_os = "windows")]
fn link_local_codec_root(name: &str) -> Option<Vec<PathBuf>> {
    let candidates = if name == "opus" {
        &["opus", "libopus"][..]
    } else {
        &[""][..]
    };

    for root in local_codec_roots() {
        let include_dir = root.join("include");
        let header = include_dir.join("opus").join("opus_multistream.h");
        if !header.exists() {
            continue;
        }

        for lib_dir in [root.join("lib"), root.join("lib64")] {
            for stem in candidates {
                let lib_name = if stem.is_empty() { name } else { stem };
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
fn link_pkg_config(name: &str) -> Vec<PathBuf> {
    if let Ok(lib) = pkg_config::probe_library(name) {
        return normalize_include_paths(lib.include_paths);
    }
    if let Some(include_paths) = link_local_codec_root(name) {
        return include_paths;
    }

    panic!(
        "unable to find '{}' development headers with pkg-config (feature linux-pkg-config is enabled).
        try installing '{}-dev' from your system package manager, or set {} to a local codec prefix.",
        name,
        name,
        LOCAL_CODEC_ROOT_ENV
    );
}

#[cfg(not(all(target_os = "linux", feature = "linux-pkg-config")))]
fn link_vcpkg(mut path: PathBuf, name: &str) -> PathBuf {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    }
    let mut target = if target_os == "macos" && target_arch == "x64" {
        "x64-osx".to_owned()
    } else if target_os == "macos" && target_arch == "arm64" {
        "arm64-osx".to_owned()
    } else if target_os == "windows" {
        "x64-windows-static".to_owned()
    } else {
        format!("{}-{}", target_arch, target_os)
    };
    if target_arch == "x86" {
        target = target.replace("x64", "x86");
    }
    println!("cargo:info={}", target);
    path.push("installed");
    path.push(target);
    println!(
        "{}",
        format!(
            "cargo:rustc-link-lib=static={}",
            name.trim_start_matches("lib")
        )
    );
    println!(
        "{}",
        format!(
            "cargo:rustc-link-search={}",
            path.join("lib").to_str().unwrap()
        )
    );
    let include = path.join("include");
    println!("{}", format!("cargo:include={}", include.to_str().unwrap()));
    include
}

#[cfg(not(all(target_os = "linux", feature = "linux-pkg-config")))]
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
        "{}",
        format!(
            "cargo:rustc-link-lib=static={}",
            name.trim_start_matches("lib")
        )
    );
    // Add the library path.
    println!(
        "{}",
        format!(
            "cargo:rustc-link-search={}",
            path.join("lib").to_str().unwrap()
        )
    );
    // Add the include path.
    let include = path.join("include");
    println!("{}", format!("cargo:include={}", include.to_str().unwrap()));
    include
}

#[cfg(all(target_os = "linux", feature = "linux-pkg-config"))]
fn find_package(name: &str) -> Vec<PathBuf> {
    link_pkg_config(name)
}

#[cfg(not(all(target_os = "linux", feature = "linux-pkg-config")))]
fn find_package(name: &str) -> Vec<PathBuf> {
    #[cfg(target_os = "windows")]
    if let Some(include_paths) = link_local_codec_root(name) {
        return include_paths;
    }

    if let Ok(vcpkg_root) = std::env::var("VCPKG_ROOT") {
        vec![link_vcpkg(vcpkg_root.into(), name)]
    } else {
        #[cfg(target_os = "linux")]
        if let Some(include_paths) = link_local_codec_root(name) {
            return normalize_include_paths(include_paths);
        }

        #[cfg(target_os = "linux")]
        panic!(
            "Couldn't find VCPKG_ROOT and no local codec root for '{}' was found. Set {} to a codec prefix or create .local/linux-codecs in the repository.",
            name,
            LOCAL_CODEC_ROOT_ENV
        );

        #[cfg(target_os = "windows")]
        panic!(
            "Couldn't find VCPKG_ROOT and no Windows codec root for '{}' was found. Set {} or CMAKE_PREFIX_PATH to a codec prefix, or create .local/windows-codecs in the repository.",
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

fn generate_bindings(ffi_header: &Path, include_paths: &[PathBuf], ffi_rs: &Path) {
    #[derive(Debug)]
    struct ParseCallbacks;
    impl bindgen::callbacks::ParseCallbacks for ParseCallbacks {
        fn int_macro(&self, name: &str, _value: i64) -> Option<bindgen::callbacks::IntKind> {
            if name.starts_with("OPUS") {
                Some(bindgen::callbacks::IntKind::Int)
            } else {
                None
            }
        }
    }
    let mut b = bindgen::Builder::default()
        .header(ffi_header.to_str().unwrap())
        .parse_callbacks(Box::new(ParseCallbacks))
        .layout_tests(false)
        .generate_comments(false);

    for dir in include_paths {
        b = b.clang_arg(format!("-I{}", dir.display()));
    }

    b.generate().unwrap().write_to_file(ffi_rs).unwrap();
}

fn gen_opus() {
    let includes = find_package("opus");
    let src_dir = env::var_os("CARGO_MANIFEST_DIR").unwrap();
    let src_dir = Path::new(&src_dir);
    let out_dir = env::var_os("OUT_DIR").unwrap();
    let out_dir = Path::new(&out_dir);

    let ffi_header = src_dir.join("opus_ffi.h");
    println!("rerun-if-changed={}", ffi_header.display());
    for dir in &includes {
        println!("rerun-if-changed={}", dir.display());
    }

    let ffi_rs = out_dir.join("opus_ffi.rs");
    generate_bindings(&ffi_header, &includes, &ffi_rs);
}

fn main() {
    gen_opus()
}
