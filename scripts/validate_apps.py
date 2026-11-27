#!/usr/bin/env python3
import sys
from pathlib import Path, PurePosixPath

import yaml

APP_KEYS = frozenset({"name", "data", "env", "expose"})
EXPOSE_KEYS = frozenset({"hostname", "service", "access"})
ACCESS_VALUES = ("private", "public")
TUNNEL_NETWORK = "tunnel"
ZONE = "kimanlab.online"
BIND_IP = "${BIND_IP}"


def load_yaml(path: Path) -> object:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def is_string_list(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) and item for item in value)


def is_inside_app_directory(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return bool(parts) and not PurePosixPath(path).is_absolute() and ".." not in parts


def is_pinned(image: str) -> bool:
    if "@sha256:" in image:
        return True
    _, separator, tag = image.rsplit("/", 1)[-1].partition(":")
    return bool(separator) and tag not in ("", "latest")


def is_bound_to_bind_ip(port: object) -> bool:
    if isinstance(port, dict):
        return port.get("host_ip") == BIND_IP
    return str(port).startswith(f"{BIND_IP}:")


def validate_service(app: str, name: str, service: dict) -> list:
    errors = []
    image = service.get("image", "")
    if not is_pinned(image):
        errors.append(f"{app}: service {name} image '{image}' must be pinned to a version")
    for port in service.get("ports", []):
        if not is_bound_to_bind_ip(port):
            errors.append(f"{app}: service {name} port '{port}' must bind to {BIND_IP}")
    return errors


def validate_expose(app: str, expose: object, services: dict) -> list:
    if not isinstance(expose, dict):
        return [f"{app}: expose must be a mapping"]
    errors = [f"{app}: unknown expose key '{key}'" for key in sorted(set(expose) - EXPOSE_KEYS, key=str)]
    if "access" in expose and expose["access"] not in ACCESS_VALUES:
        errors.append(f"{app}: access must be one of {', '.join(ACCESS_VALUES)}, got {expose['access']!r}")
    hostname = expose.get("hostname")
    if not isinstance(hostname, str) or not (hostname == ZONE or hostname.endswith(f".{ZONE}")):
        errors.append(f"{app}: hostname must belong to {ZONE}, got {hostname!r}")
    target = str(expose.get("service", "")).partition(":")[0]
    if target not in services:
        errors.append(f"{app}: expose service '{target}' is not defined in its compose file")
    elif TUNNEL_NETWORK not in services[target].get("networks", []):
        errors.append(f"{app}: service {target} must join network '{TUNNEL_NETWORK}'")
    return errors


def validate_app(root: Path, app: dict) -> list:
    name = app.get("name")
    if not isinstance(name, str) or not name:
        return [f"every app needs a name, got {app!r}"]
    errors = [f"{name}: unknown key '{key}'" for key in sorted(set(app) - APP_KEYS, key=str)]
    for key in ("data", "env"):
        if not is_string_list(app.get(key, [])):
            errors.append(f"{name}: {key} must be a list of strings")
        elif key == "data":
            errors += [
                f"{name}: data path '{path}' must stay inside the app directory"
                for path in app.get(key, [])
                if not is_inside_app_directory(path)
            ]
    compose_path = root / "apps" / name / "compose.yaml"
    if not compose_path.is_file():
        return errors + [f"{name}: missing {compose_path.relative_to(root)}"]
    services = load_yaml(compose_path).get("services", {})
    for service_name, service in services.items():
        errors += validate_service(name, service_name, service)
    if "expose" in app:
        errors += validate_expose(name, app["expose"], services)
    return errors


def find_duplicates(values: list, label: str) -> list:
    return [f"duplicate {label} '{value}'" for value in sorted(set(values)) if values.count(value) > 1]


def validate(root: Path) -> list:
    try:
        document = load_yaml(root / "apps.yaml")
    except (OSError, yaml.YAMLError) as error:
        return [f"apps.yaml cannot be read: {error}"]
    apps = document.get("apps") if isinstance(document, dict) else None
    if not isinstance(apps, list) or not apps or not all(isinstance(app, dict) for app in apps):
        return ["apps.yaml must contain a non-empty 'apps' list of mappings"]
    errors = [error for app in apps for error in validate_app(root, app)]
    errors += find_duplicates([str(app.get("name")) for app in apps], "app name")
    hostnames = [
        str(app["expose"].get("hostname")) for app in apps if isinstance(app.get("expose"), dict)
    ]
    return errors + find_duplicates(hostnames, "hostname")


def main() -> int:
    errors = validate(Path(__file__).resolve().parents[1])
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
