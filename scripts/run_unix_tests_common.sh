#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run_linux_tests.sh [options]
       scripts/run_macos_tests.sh [options]

Options:
  --flutter-root PATH       Flutter SDK root. Also read from RUSTDESK_FLUTTER_ROOT.
  --pub-cache PATH          Dart package cache. Also read from PUB_CACHE.
  --cargo-target-dir PATH   Cargo output directory. Also read from CARGO_TARGET_DIR.
  --codec-root PATH         Native dependency prefix for macOS. Also read from
                            RUSTDESK_MACOS_CODEC_ROOT or CMAKE_PREFIX_PATH.
  --features LIST           Cargo features. Default: flutter,use_dasp.
  --skip-full-client        Skip the full serial rustdesk-client cargo test step.
  --skip-hbb-common         Skip hbb_common test steps.
  --skip-flutter            Skip Flutter pub get and Flutter tests.
  --stop-on-failure         Stop after the first failed step.
  -h, --help                Show this help.

Logs:
  target/<platform>-test-logs/<platform>-tests-YYYYMMDD-HHMMSS.log
  target/<platform>-test-logs/<platform>-tests-YYYYMMDD-HHMMSS-steps/*.log
USAGE
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

platform="$1"
shift

case "$platform" in
  linux)
    platform_name="Linux"
    ;;
  macos)
    platform_name="macOS"
    ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
client_root="$(cd "$script_dir/.." && pwd -P)"
workspace_root="$(cd "$client_root/.." && pwd -P)"
workspace_parent="$(cd "$workspace_root/.." && pwd -P)"
hbb_common_root="$workspace_root/hbb_common"
flutter_dir="$client_root/flutter"

flutter_root=""
pub_cache=""
cargo_target_dir=""
codec_root=""
features="${RUSTDESK_TEST_FEATURES:-flutter,use_dasp}"
skip_full_client=0
skip_hbb_common=0
skip_flutter=0
stop_on_failure=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flutter-root)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --flutter-root" >&2
        exit 2
      fi
      flutter_root="$2"
      shift
      ;;
    --flutter-root=*)
      flutter_root="${1#*=}"
      ;;
    --pub-cache)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pub-cache" >&2
        exit 2
      fi
      pub_cache="$2"
      shift
      ;;
    --pub-cache=*)
      pub_cache="${1#*=}"
      ;;
    --cargo-target-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --cargo-target-dir" >&2
        exit 2
      fi
      cargo_target_dir="$2"
      shift
      ;;
    --cargo-target-dir=*)
      cargo_target_dir="${1#*=}"
      ;;
    --codec-root)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --codec-root" >&2
        exit 2
      fi
      codec_root="$2"
      shift
      ;;
    --codec-root=*)
      codec_root="${1#*=}"
      ;;
    --features)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --features" >&2
        exit 2
      fi
      features="$2"
      shift
      ;;
    --features=*)
      features="${1#*=}"
      ;;
    --skip-full-client)
      skip_full_client=1
      ;;
    --skip-hbb-common)
      skip_hbb_common=1
      ;;
    --skip-flutter)
      skip_flutter=1
      ;;
    --stop-on-failure)
      stop_on_failure=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$features" ]]; then
  echo "--features must not be empty" >&2
  exit 2
fi

if [[ ! -d "$hbb_common_root" ]]; then
  echo "hbb_common repo was not found at '$hbb_common_root'." >&2
  exit 1
fi
if [[ ! -d "$flutter_dir" ]]; then
  echo "Flutter project directory was not found at '$flutter_dir'." >&2
  exit 1
fi

if [[ -z "$pub_cache" ]]; then
  if [[ -n "${PUB_CACHE:-}" ]]; then
    pub_cache="$PUB_CACHE"
  elif [[ "$platform" == "linux" ]]; then
    pub_cache="$workspace_parent/flutter-pub-cache-linux"
  else
    pub_cache="$HOME/.pub-cache-rustdesk-macos"
  fi
fi

if [[ -z "$cargo_target_dir" ]]; then
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    cargo_target_dir="$CARGO_TARGET_DIR"
  else
    cargo_target_dir="$workspace_parent/rustdesk-target-$platform"
  fi
fi

export PUB_CACHE="$pub_cache"
export CARGO_TARGET_DIR="$cargo_target_dir"

if [[ "$platform" == "macos" ]]; then
  default_codec_root="$client_root/.local/macos-codecs"
  if [[ -z "$codec_root" ]]; then
    if [[ -n "${RUSTDESK_MACOS_CODEC_ROOT:-}" ]]; then
      codec_root="$RUSTDESK_MACOS_CODEC_ROOT"
    elif [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
      codec_root="${CMAKE_PREFIX_PATH%%:*}"
    elif [[ -d "$default_codec_root" ]]; then
      codec_root="$default_codec_root"
    fi
  fi

  if [[ -n "$codec_root" ]]; then
    export RUSTDESK_MACOS_CODEC_ROOT="$codec_root"
    export CMAKE_PREFIX_PATH="$codec_root:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$codec_root/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  fi
fi

if [[ "$platform" == "linux" && -z "${LIBCLANG_PATH:-}" && -d /usr/lib/llvm-18/lib ]]; then
  export LIBCLANG_PATH=/usr/lib/llvm-18/lib
fi

mkdir -p "$PUB_CACHE" "$CARGO_TARGET_DIR"

resolve_flutter_command() {
  local default_flutter_root="$workspace_parent/flutter"

  if [[ -z "$flutter_root" && -n "${RUSTDESK_FLUTTER_ROOT:-}" ]]; then
    flutter_root="$RUSTDESK_FLUTTER_ROOT"
  fi
  if [[ -z "$flutter_root" && -x "$default_flutter_root/bin/flutter" ]]; then
    flutter_root="$default_flutter_root"
  fi

  if [[ -n "$flutter_root" ]]; then
    local flutter_cmd="$flutter_root/bin/flutter"
    if [[ ! -x "$flutter_cmd" ]]; then
      echo "Flutter was not found at '$flutter_cmd'. Pass --flutter-root or set RUSTDESK_FLUTTER_ROOT." >&2
      exit 1
    fi
    export PATH="$flutter_root/bin:$PATH"
    printf '%s\n' "$flutter_cmd"
    return
  fi

  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return
  fi

  echo "Flutter was not found on PATH. Pass --flutter-root or set RUSTDESK_FLUTTER_ROOT." >&2
  exit 1
}

safe_step_name() {
  local name="$1"
  local safe
  safe="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-' | tr '[:upper:]' '[:lower:]')"
  safe="${safe#-}"
  safe="${safe%-}"
  if [[ -z "$safe" ]]; then
    safe="step"
  fi
  printf '%s\n' "$safe"
}

shell_quote() {
  local quoted=""
  local arg
  local escaped
  for arg in "$@"; do
    if [[ -n "$quoted" ]]; then
      quoted+=" "
    fi
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=,+@%-]+$ ]]; then
      quoted+="$arg"
    else
      escaped="${arg//\'/\'\\\'\'}"
      quoted+="'$escaped'"
    fi
  done
  printf '%s\n' "$quoted"
}

declare -a result_steps=()
declare -a result_statuses=()
declare -a result_exit_codes=()
declare -a result_seconds=()
declare -a result_logs=()

print_summary() {
  local failed_count=0
  local i

  printf '\n%s validation summary\n' "$platform_name"
  printf '\n%-40s %-6s %8s %8s\n' "Step" "Status" "ExitCode" "Seconds"
  printf '%-40s %-6s %8s %8s\n' "----" "------" "--------" "-------"
  for ((i = 0; i < ${#result_steps[@]}; i++)); do
    printf '%-40s %-6s %8s %8s\n' \
      "${result_steps[$i]}" \
      "${result_statuses[$i]}" \
      "${result_exit_codes[$i]}" \
      "${result_seconds[$i]}"
    if [[ "${result_statuses[$i]}" != "PASS" ]]; then
      failed_count=$((failed_count + 1))
    fi
  done

  if [[ "$failed_count" -gt 0 ]]; then
    printf '\nFailed step logs:\n'
    for ((i = 0; i < ${#result_steps[@]}; i++)); do
      if [[ "${result_statuses[$i]}" != "PASS" ]]; then
        printf ' - %s: %s\n' "${result_steps[$i]}" "${result_logs[$i]}"
      fi
    done
  fi

  printf '\nLog: %s\n' "$run_log"
  printf 'Step logs: %s\n' "$step_log_dir"
}

run_step() {
  local name="$1"
  local working_dir="$2"
  shift 2

  local step_number=$(( ${#result_steps[@]} + 1 ))
  local step_log_name
  local step_log_path
  step_log_name="$(printf '%02d-%s.log' "$step_number" "$(safe_step_name "$name")")"
  step_log_path="$step_log_dir/$step_log_name"

  printf '\n==> %s\n' "$name"
  printf '    %s\n' "$(shell_quote "$@")"
  printf '    Step log: %s\n' "$step_log_path"

  local start
  local end
  local elapsed
  local exit_code
  start="$(date +%s)"
  set +e
  (
    cd "$working_dir"
    "$@"
  ) >"$step_log_path" 2>&1
  exit_code=$?
  set -e
  end="$(date +%s)"
  elapsed=$((end - start))

  local status="PASS"
  if [[ "$exit_code" -ne 0 ]]; then
    status="FAIL"
  fi

  result_steps+=("$name")
  result_statuses+=("$status")
  result_exit_codes+=("$exit_code")
  result_seconds+=("$elapsed")
  result_logs+=("$step_log_path")

  if [[ "$exit_code" -ne 0 ]]; then
    printf '    Failed step log tail:\n'
    tail -n 80 "$step_log_path" | sed 's/^/    /'
    if [[ "$stop_on_failure" -eq 1 ]]; then
      print_summary
      exit "$exit_code"
    fi
  fi
}

log_dir="$client_root/target/$platform-test-logs"
run_stamp="$(date '+%Y%m%d-%H%M%S')"
run_log="$log_dir/$platform-tests-$run_stamp.log"
step_log_dir="$log_dir/$platform-tests-$run_stamp-steps"
mkdir -p "$step_log_dir"

exec > >(tee "$run_log") 2>&1

printf 'RustAdmin %s validation\n' "$platform_name"
printf 'Client:      %s\n' "$client_root"
printf 'hbb_common:  %s\n' "$hbb_common_root"
printf 'Flutter dir: %s\n' "$flutter_dir"
printf 'Features:    %s\n' "$features"
printf 'Pub cache:   %s\n' "$PUB_CACHE"
printf 'Target dir:  %s\n' "$CARGO_TARGET_DIR"
if [[ "$platform" == "macos" && -n "${RUSTDESK_MACOS_CODEC_ROOT:-}" ]]; then
  printf 'Codec root:  %s\n' "$RUSTDESK_MACOS_CODEC_ROOT"
fi
if [[ -n "${LIBCLANG_PATH:-}" ]]; then
  printf 'LIBCLANG:    %s\n' "$LIBCLANG_PATH"
fi

run_step "rustdesk-client cargo check" "$client_root" \
  cargo check --no-default-features --features "$features"
run_step "privacy mode policy tests" "$client_root" \
  cargo test --no-default-features --features "$features" privacy_mode_policy
run_step "RustAdmin GUI block policy tests" "$client_root" \
  cargo test --no-default-features --features "$features" rustadmin_gui_block_policy
run_step "low-permission support policy tests" "$client_root" \
  cargo test --no-default-features --features "$features" low_permission
run_step "elevation permission policy tests" "$client_root" \
  cargo test --no-default-features --features "$features" elevation_policy_requires_unattended_access
run_step "IPC enum size contract" "$client_root" \
  cargo test --no-default-features --features "$features" ipc::test::verify_ffi_enum_data_size

if [[ "$skip_full_client" -eq 0 ]]; then
  run_step "rustdesk-client full serial tests" "$client_root" \
    cargo test --no-default-features --features "$features" -- --test-threads=1
fi

if [[ "$skip_hbb_common" -eq 0 ]]; then
  run_step "hbb_common permanent password tests" "$hbb_common_root" \
    cargo test permanent_password
  run_step "hbb_common full tests" "$hbb_common_root" \
    cargo test
fi

if [[ "$skip_flutter" -eq 0 ]]; then
  flutter_command="$(resolve_flutter_command)"
  run_step "Flutter pub get" "$flutter_dir" "$flutter_command" pub get
  run_step "Flutter tests" "$flutter_dir" "$flutter_command" test -r expanded
fi

print_summary

for ((i = 0; i < ${#result_statuses[@]}; i++)); do
  if [[ "${result_statuses[$i]}" != "PASS" ]]; then
    exit 1
  fi
done
exit 0
