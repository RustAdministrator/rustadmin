use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

const ANDROID_NATIVE_ROOT_ENV: &str = "RUSTADMIN_ANDROID_NATIVE_ROOT";
const CMAKE_PREFIX_PATH_ENV: &str = "CMAKE_PREFIX_PATH";

#[cfg(windows)]
fn build_windows() {
    let file = "src/platform/windows.cc";
    let file2 = "src/platform/windows_delete_test_cert.cc";
    cc::Build::new().file(file).file(file2).compile("windows");
    println!("cargo:rustc-link-lib=WtsApi32");
    println!("cargo:rerun-if-changed={}", file);
    println!("cargo:rerun-if-changed={}", file2);
}

#[cfg(target_os = "macos")]
fn build_mac() {
    let file = "src/platform/macos.mm";
    let mut b = cc::Build::new();
    if let Ok(os_version::OsVersion::MacOS(v)) = os_version::detect() {
        let v = v.version;
        if v.contains("10.14") {
            b.flag("-DNO_InputMonitoringAuthStatus=1");
        }
    }
    b.flag("-std=c++17").file(file).compile("macos");
    println!("cargo:rerun-if-changed={}", file);
}

#[cfg(all(windows, feature = "inline"))]
fn build_manifest() {
    use std::io::Write;
    if std::env::var("PROFILE").unwrap() == "release" {
        let mut res = winres::WindowsResource::new();
        res.set_icon("res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}

fn android_abi(target_arch: &str) -> Result<&'static str, String> {
    match target_arch {
        "aarch64" => Ok("arm64-v8a"),
        "arm" => Ok("armeabi-v7a"),
        "x86_64" => Ok("x86_64"),
        "x86" => Ok("x86"),
        _ => Err(format!(
            "unsupported Android target architecture: {target_arch}"
        )),
    }
}

fn push_android_prefix(candidates: &mut Vec<PathBuf>, root: PathBuf, abi: &str) {
    candidates.push(root.clone());
    if root.file_name().and_then(|name| name.to_str()) != Some(abi) {
        candidates.push(root.join(abi));
    }
}

fn has_android_library(lib_dir: &Path, name: &str) -> bool {
    lib_dir.join(format!("lib{name}.a")).is_file()
        || lib_dir.join(format!("lib{name}.so")).is_file()
}

fn explicit_android_prefix(abi: &str) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(root) = std::env::var_os(ANDROID_NATIVE_ROOT_ENV) {
        push_android_prefix(&mut candidates, PathBuf::from(root), abi);
    }
    if let Some(paths) = std::env::var_os(CMAKE_PREFIX_PATH_ENV) {
        for root in std::env::split_paths(&paths) {
            push_android_prefix(&mut candidates, root, abi);
        }
    }

    candidates.into_iter().find(|prefix| {
        let lib_dir = prefix.join("lib");
        has_android_library(&lib_dir, "ndk_compat")
    })
}

fn legacy_android_vcpkg_prefix(target_arch: &str) -> Option<PathBuf> {
    let triplet = match target_arch {
        "aarch64" => "arm64-android",
        "arm" => "arm-android",
        "x86_64" => "x64-android",
        "x86" => "x86-android",
        _ => return None,
    };

    if let Some(installed_root) = std::env::var_os("VCPKG_INSTALLED_ROOT") {
        return Some(PathBuf::from(installed_root).join(triplet));
    }
    std::env::var_os("VCPKG_ROOT")
        .map(PathBuf::from)
        .map(|root| root.join("installed").join(triplet))
}

fn install_android_deps(target_os: &str) -> Result<(), String> {
    if target_os != "android" {
        return Ok(());
    }

    println!("cargo:rerun-if-env-changed={ANDROID_NATIVE_ROOT_ENV}");
    println!("cargo:rerun-if-env-changed={CMAKE_PREFIX_PATH_ENV}");
    println!("cargo:rerun-if-env-changed=VCPKG_ROOT");
    println!("cargo:rerun-if-env-changed=VCPKG_INSTALLED_ROOT");

    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH")
        .map_err(|error| format!("CARGO_CFG_TARGET_ARCH is unavailable: {error}"))?;
    let abi = android_abi(&target_arch)?;
    let prefix = explicit_android_prefix(abi)
        .or_else(|| legacy_android_vcpkg_prefix(&target_arch))
        .ok_or_else(|| {
            format!(
                "Android native dependencies for {abi} were not found. Set {ANDROID_NATIVE_ROOT_ENV} or {CMAKE_PREFIX_PATH_ENV} to the dedicated ABI prefix containing include/ and lib/."
            )
        })?;
    let lib_dir = prefix.join("lib");
    if !has_android_library(&lib_dir, "ndk_compat") {
        return Err(format!(
            "Android native prefix {} must contain libndk_compat in lib/",
            prefix.display()
        ));
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=ndk_compat");
    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rustc-link-lib=OpenSLES");
    Ok(())
}

fn read_revision_file<P: AsRef<Path>>(path: P) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn build_rustadmin_revision() -> String {
    read_revision_file("rustadmin_revision.txt")
        .or_else(|| read_revision_file("../hbb_common/rustadmin_revision.txt"))
        .unwrap_or_default()
}

fn create_version_file() -> File {
    match File::create("./src/version.rs") {
        Ok(file) => file,
        Err(error) => panic!("failed to create src/version.rs: {error}"),
    }
}

fn open_cargo_toml() -> File {
    match File::open("Cargo.toml") {
        Ok(file) => file,
        Err(error) => panic!("failed to open Cargo.toml: {error}"),
    }
}

fn write_version_file(file: &mut File, contents: &str) {
    if let Err(error) = file.write_all(contents.as_bytes()) {
        panic!("failed to write src/version.rs: {error}");
    }
}

fn gen_version() {
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=../hbb_common/rustadmin_revision.txt");
    println!("cargo:rerun-if-changed=rustadmin_revision.txt");

    let mut file = create_version_file();
    let revision = build_rustadmin_revision();
    for line in BufReader::new(open_cargo_toml())
        .lines()
        .map_while(Result::ok)
    {
        let ab: Vec<&str> = line.split('=').map(str::trim).collect();
        if ab.len() == 2 && ab[0] == "version" {
            let version = ab[1].trim_matches('"');
            let contents = format!(
                "#[allow(dead_code)]\npub const VERSION: &str = {};\n#[allow(dead_code)]\npub const RUSTADMIN_REVISION: &str = \"{revision}\";\n#[allow(dead_code)]\npub const FULL_VERSION: &str = \"{version} rev {revision}\";\n",
                ab[1]
            );
            write_version_file(&mut file, &contents);
            break;
        }
    }

    let build_date = chrono::Local::now().format("%Y-%m-%d %H:%M");
    write_version_file(
        &mut file,
        &format!("#[allow(dead_code)]\npub const BUILD_DATE: &str = \"{build_date}\";\n"),
    );
    if let Err(error) = file.sync_all() {
        panic!("failed to sync src/version.rs: {error}");
    }
}

fn main() -> Result<(), String> {
    gen_version();
    let target_os = std::env::var("CARGO_CFG_TARGET_OS")
        .map_err(|error| format!("CARGO_CFG_TARGET_OS is unavailable: {error}"))?;
    install_android_deps(&target_os)?;
    #[cfg(all(windows, feature = "inline"))]
    build_manifest();
    #[cfg(windows)]
    build_windows();
    if target_os == "macos" {
        #[cfg(target_os = "macos")]
        build_mac();
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
    }
    println!("cargo:rerun-if-changed=build.rs");
    Ok(())
}
