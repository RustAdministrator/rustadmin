use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

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

fn install_android_deps() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os != "android" {
        return;
    }
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "x86" {
        target_arch = "x86".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    } else {
        target_arch = "arm".to_owned();
    }
    let target = format!("{}-android", target_arch);
    let vcpkg_root = std::env::var("VCPKG_ROOT").unwrap();
    let mut path: std::path::PathBuf = vcpkg_root.into();
    if let Ok(vcpkg_root) = std::env::var("VCPKG_INSTALLED_ROOT") {
        path = vcpkg_root.into();
    } else {
        path.push("installed");
    }
    path.push(target);
    println!(
        "cargo:rustc-link-search={}",
        path.join("lib").to_str().unwrap()
    );
    println!("cargo:rustc-link-lib=ndk_compat");
    println!("cargo:rustc-link-lib=oboe");
    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rustc-link-lib=OpenSLES");
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
    for line in BufReader::new(open_cargo_toml()).lines().map_while(Result::ok) {
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

fn main() {
    gen_version();
    install_android_deps();
    #[cfg(all(windows, feature = "inline"))]
    build_manifest();
    #[cfg(windows)]
    build_windows();
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if target_os == "macos" {
        #[cfg(target_os = "macos")]
        build_mac();
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
    }
    println!("cargo:rerun-if-changed=build.rs");
}
