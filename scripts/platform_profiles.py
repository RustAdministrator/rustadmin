#!/usr/bin/env python3
import argparse
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    print("error: platform profile validation requires Python 3.11 or newer", file=sys.stderr)
    raise SystemExit(2)


ROOT = pathlib.Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "scripts" / "platform_profiles.toml"
CARGO_PATH = ROOT / "Cargo.toml"
ALLOWED_ROLES = {"controller", "controlled-host", "service"}
ALLOWED_GATES = {"config", "compile", "unit", "artifact", "device"}
REQUIRED_GATES = {"config", "compile", "artifact", "device"}
REQUIRED_PROFILE_KEYS = {
    "id",
    "platform",
    "rust_targets",
    "artifact",
    "roles",
    "default_features",
    "required_features",
    "optional_features",
    "forbidden_features",
    "native_components",
    "conditional_native_components",
    "native_marker",
    "minimum_os",
    "packaging",
    "wrappers",
    "gates",
}


class ProfileError(ValueError):
    pass


def load_toml(path):
    with path.open("rb") as source:
        return tomllib.load(source)


def normalized_features(value):
    return {item for item in value.replace(",", " ").split() if item}


def profile_map(matrix):
    return {profile["id"]: profile for profile in matrix.get("profiles", [])}


def validate_matrix(matrix):
    errors = []
    if matrix.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    cargo_feature_table = load_toml(CARGO_PATH).get("features", {})
    cargo_features = set(cargo_feature_table)
    declared_defaults = matrix.get("cargo_default_features", [])
    if declared_defaults != cargo_feature_table.get("default", []):
        errors.append(
            "cargo_default_features does not match Cargo.toml: "
            f"matrix={declared_defaults}, cargo={cargo_feature_table.get('default', [])}"
        )
    profiles = matrix.get("profiles", [])
    ids = set()
    wrappers = {}
    for index, profile in enumerate(profiles):
        label = profile.get("id", f"profiles[{index}]")
        missing = REQUIRED_PROFILE_KEYS - set(profile)
        if missing:
            errors.append(f"{label}: missing keys {sorted(missing)}")
            continue
        if label in ids:
            errors.append(f"{label}: duplicate profile id")
        ids.add(label)
        if not profile["rust_targets"]:
            errors.append(f"{label}: rust_targets must not be empty")
        if len(profile["rust_targets"]) != len(set(profile["rust_targets"])):
            errors.append(f"{label}: duplicate rust target")
        if not set(profile["roles"]) <= ALLOWED_ROLES:
            errors.append(f"{label}: unsupported role")
        if not isinstance(profile["default_features"], bool):
            errors.append(f"{label}: default_features must be boolean")
        gates = set(profile["gates"])
        if not gates <= ALLOWED_GATES or not REQUIRED_GATES <= gates:
            errors.append(f"{label}: incomplete or unsupported gates {sorted(gates)}")
        required = set(profile["required_features"])
        optional = set(profile["optional_features"])
        forbidden = set(profile["forbidden_features"])
        if required & optional or required & forbidden or optional & forbidden:
            errors.append(f"{label}: feature sets overlap")
        declared = required | optional | forbidden
        unknown = declared - cargo_features
        if unknown:
            errors.append(f"{label}: unknown Cargo features {sorted(unknown)}")
        for feature, dependencies in profile.get("feature_requires", {}).items():
            if feature not in required | optional:
                errors.append(f"{label}: constraint source {feature} is not allowed")
            unknown_dependencies = set(dependencies) - (required | optional)
            if unknown_dependencies:
                errors.append(
                    f"{label}: constraint {feature} has unavailable dependencies "
                    f"{sorted(unknown_dependencies)}"
                )
        for component in profile["conditional_native_components"]:
            feature, separator, name = component.partition(":")
            if not separator or not name or feature not in required | optional:
                errors.append(f"{label}: invalid conditional native component {component}")
        for key in ("native_marker", "minimum_os", "packaging"):
            if not profile[key].strip():
                errors.append(f"{label}: {key} must not be empty")
        for wrapper in profile["wrappers"]:
            wrapper_path = pathlib.PurePosixPath(wrapper)
            if wrapper_path.is_absolute() or ".." in wrapper_path.parts:
                errors.append(f"{label}: unsafe wrapper path {wrapper}")
                continue
            if not (ROOT / wrapper).is_file():
                errors.append(f"{label}: wrapper does not exist: {wrapper}")
            previous = wrappers.get(wrapper)
            if previous is not None:
                errors.append(f"{wrapper}: assigned to both {previous} and {label}")
            wrappers[wrapper] = label
    shipping = set(matrix.get("shipping_wrappers", []))
    assigned = set(wrappers)
    if shipping != assigned:
        errors.append(
            "shipping wrapper ownership mismatch: "
            f"missing={sorted(shipping - assigned)}, extra={sorted(assigned - shipping)}"
        )
    if errors:
        raise ProfileError("\n".join(errors))


def check_profile(profile, args):
    errors = []
    if args.wrapper not in profile["wrappers"]:
        errors.append(f"wrapper {args.wrapper} is not owned by profile {profile['id']}")
    if args.target not in profile["rust_targets"]:
        errors.append(
            f"target {args.target} is not supported by profile {profile['id']}; "
            f"expected one of {profile['rust_targets']}"
        )
    expected_abi = profile.get("abi")
    if expected_abi and not args.abi:
        errors.append(f"profile {profile['id']} requires ABI {expected_abi}")
    elif args.abi and args.abi != (expected_abi or ""):
        errors.append(
            f"ABI {args.abi} does not match profile {profile['id']} "
            f"({profile.get('abi', 'none')})"
        )
    features = normalized_features(args.features)
    required = set(profile["required_features"])
    optional = set(profile["optional_features"])
    forbidden = set(profile["forbidden_features"])
    if missing := required - features:
        errors.append(f"missing required features {sorted(missing)}")
    if unsupported := features - required - optional - forbidden:
        errors.append(f"unsupported features {sorted(unsupported)}")
    if blocked := features & forbidden:
        errors.append(f"forbidden features {sorted(blocked)}")
    for feature, dependencies in profile.get("feature_requires", {}).items():
        if feature in features and (missing := set(dependencies) - features):
            errors.append(f"feature {feature} requires {sorted(missing)}")
    if errors:
        raise ProfileError(f"{profile['id']}: " + "; ".join(errors))


def parse_args():
    parser = argparse.ArgumentParser(description="Validate RustAdmin shipping build profiles")
    parser.add_argument("--matrix", type=pathlib.Path, default=MATRIX_PATH)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    subparsers.add_parser("list")
    check = subparsers.add_parser("check")
    check.add_argument("--profile", required=True)
    check.add_argument("--wrapper", required=True)
    check.add_argument("--target", required=True)
    check.add_argument("--abi")
    check.add_argument("--features", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    matrix = load_toml(args.matrix)
    validate_matrix(matrix)
    profiles = profile_map(matrix)
    if args.command == "validate":
        print(f"Validated {len(profiles)} shipping platform profiles.")
        return 0
    if args.command == "list":
        print("\n".join(profiles))
        return 0
    profile = profiles.get(args.profile)
    if profile is None:
        raise ProfileError(f"unknown platform profile {args.profile}")
    check_profile(profile, args)
    print(f"Validated platform profile {args.profile}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, tomllib.TOMLDecodeError, ProfileError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
