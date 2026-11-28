# Checks the Flutter SDK of a build against the newest release of a Flutter channel, as Flutter
# publishes it for its installers. Sourced by build_linux.sh.
#
# The newest release is looked up at every build, not pinned: builders that drift apart
# (Flutter 3.44.7 here, 3.50.1 there) resolve pubspec.lock differently and build different
# apps from the same commit.

flutter_release_list_url() {
  printf 'https://storage.googleapis.com/flutter_infra_release/releases/releases_%s.json\n' "$1"
}

# Prints "<version> <hash> <release date>" of the newest release of a channel.
latest_flutter_release() {
  local platform="$1" channel="$2" list
  command -v python3 >/dev/null 2>&1 || { echo "python3 is not available" >&2; return 1; }
  if command -v curl >/dev/null 2>&1; then
    list="$(curl -fsS --max-time 20 "$(flutter_release_list_url "$platform")")" || return 1
  elif command -v wget >/dev/null 2>&1; then
    list="$(wget -q -T 20 -O - "$(flutter_release_list_url "$platform")")" || return 1
  else
    echo "neither curl nor wget is available" >&2
    return 1
  fi
  printf '%s' "$list" | python3 -I -c '
import json, sys
channel = sys.argv[1]
data = json.load(sys.stdin)
current = data["current_release"].get(channel)
for release in data["releases"]:
    if release["hash"] == current and release["channel"] == channel:
        print(release["version"], release["hash"], release["release_date"][:10])
        break
else:
    sys.exit("the release list names no current %s release" % channel)
' "$channel"
}

installed_flutter_version() {
  local flutter_root="$1"
  local version_file="$flutter_root/bin/cache/flutter.version.json"
  if [[ -f "$version_file" ]]; then
    python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["frameworkVersion"])' \
      "$version_file" && return
  fi
  "$flutter_root/bin/flutter" --version --machine 2>/dev/null |
    python3 -I -c 'import json, sys; t = sys.stdin.read(); print(json.loads(t[t.index("{"):t.rindex("}") + 1])["frameworkVersion"])'
}

update_flutter_sdk() {
  local flutter_root="$1" version="$2" hash="$3" commit
  if [[ ! -d "$flutter_root/.git" ]]; then
    echo "'$flutter_root' is not a git checkout of Flutter; install Flutter $version there by hand." >&2
    return 1
  fi
  if [[ -n "$(git -C "$flutter_root" status --porcelain --untracked-files=no)" ]]; then
    echo "'$flutter_root' has local changes; not switching it to $version." >&2
    return 1
  fi
  git -C "$flutter_root" fetch origin "refs/tags/$version:refs/tags/$version" || return 1
  # The tag must be the commit that the release list names.
  commit="$(git -C "$flutter_root" rev-parse "$version^{commit}")" || return 1
  if [[ "$commit" != "$hash" ]]; then
    echo "Flutter tag $version is $commit, but the release list names $hash." >&2
    return 1
  fi
  git -C "$flutter_root" -c advice.detachedHead=false checkout --detach "$version" || return 1
  # Downloads the Dart SDK and the engine of the new version.
  "$flutter_root/bin/flutter" --version
}

# check_flutter_release <flutter root> <platform> <channel> <update 0|1> <allow outdated 0|1>
check_flutter_release() {
  local flutter_root="$1" platform="$2" channel="$3" update="$4" allow_outdated="$5"
  local latest version hash date installed message after
  if ! latest="$(latest_flutter_release "$platform" "$channel")"; then
    echo "Warning: could not look up the latest Flutter $channel release; building with the installed Flutter." >&2
    return 0
  fi
  read -r version hash date <<<"$latest"
  installed="$(installed_flutter_version "$flutter_root")" || {
    echo "Could not read the Flutter version at '$flutter_root'." >&2
    return 1
  }
  if [[ "$installed" == "$version" ]]; then
    echo "Flutter $installed is the latest $channel release."
    return 0
  fi
  message="Flutter $installed is installed at '$flutter_root'; the latest $channel release is $version (released $date)."
  if [[ "$update" == "1" ]]; then
    echo "$message Updating the SDK..."
    update_flutter_sdk "$flutter_root" "$version" "$hash" || return 1
    after="$(installed_flutter_version "$flutter_root")"
    if [[ "$after" != "$version" ]]; then
      echo "After the update Flutter reports $after, not $version." >&2
      return 1
    fi
    echo "Flutter is now $after."
    return 0
  fi
  if [[ "$allow_outdated" == "1" ]]; then
    echo "Warning: $message Building with $installed (--allow-outdated-flutter)." >&2
    return 0
  fi
  echo "$message Run with --update-flutter to switch the SDK to $version, or with --allow-outdated-flutter to build with $installed." >&2
  return 1
}
