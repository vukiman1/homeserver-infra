import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from validate_apps import validate  # noqa: E402

BOUND_PORT = "${BIND_IP}:8080:8080"


def app_entry(root, name="blog", expose=None, networks=("tunnel",), ports=(), image="traefik/whoami:v1.11.0"):
    compose = {
        "services": {name: {"image": image, "networks": list(networks), "ports": list(ports)}},
        "networks": {"tunnel": {"external": True}},
    }
    app_dir = root / "apps" / name
    app_dir.mkdir(parents=True)
    (app_dir / "compose.yaml").write_text(yaml.safe_dump(compose))
    entry = {"name": name}
    if expose is not None:
        entry["expose"] = {"hostname": f"{name}.kimanlab.online", "service": f"{name}:80", **expose}
    return entry


def write_apps(root, *entries):
    (root / "apps.yaml").write_text(yaml.safe_dump({"apps": list(entries)}))
    return root


def tree(root, **options):
    return write_apps(root, app_entry(root, **options))


def test_valid_repository_has_no_errors():
    assert validate(REPO_ROOT) == []


def test_minimal_exposed_app_is_accepted(tmp_path):
    assert validate(tree(tmp_path, expose={})) == []


def test_unknown_key_is_rejected(tmp_path):
    assert "acces" in " ".join(validate(tree(tmp_path, expose={"acces": "public"})))


@pytest.mark.parametrize("access", ["Public", "", None, True])
def test_access_value_must_be_exact(tmp_path, access):
    assert validate(tree(tmp_path, expose={"access": access}))


def test_unknown_app_key_is_rejected(tmp_path):
    entry = {**app_entry(tmp_path), "exposed": {}}
    assert "exposed" in " ".join(validate(write_apps(tmp_path, entry)))


def test_exposed_app_must_join_tunnel_network(tmp_path):
    assert "blog" in validate(tree(tmp_path, expose={}, networks=()))[0]


def test_exposed_service_must_exist_in_compose(tmp_path):
    assert validate(tree(tmp_path, expose={"service": "missing:80"}))


@pytest.mark.parametrize(
    "port",
    ["8080:8080", "0.0.0.0:8080:8080", {"target": 80, "published": 8080}],
)
def test_port_without_bind_ip_is_rejected(tmp_path, port):
    assert validate(tree(tmp_path, ports=[port]))


def test_port_bound_to_bind_ip_is_accepted(tmp_path):
    assert validate(tree(tmp_path, ports=[BOUND_PORT])) == []


@pytest.mark.parametrize(
    "image",
    ["traefik/whoami:latest", "traefik/whoami", "registry.local:5000/whoami"],
)
def test_unpinned_image_is_rejected(tmp_path, image):
    assert validate(tree(tmp_path, image=image))


def test_duplicate_hostname_is_rejected(tmp_path):
    shared = {"hostname": "same.kimanlab.online"}
    entries = [app_entry(tmp_path, name=name, expose=shared) for name in ("one", "two")]
    assert "same.kimanlab.online" in " ".join(validate(write_apps(tmp_path, *entries)))


def test_hostname_outside_zone_is_rejected(tmp_path):
    assert validate(tree(tmp_path, expose={"hostname": "blog.example.com"}))


def test_missing_compose_file_is_rejected(tmp_path):
    assert "ghost" in " ".join(validate(write_apps(tmp_path, {"name": "ghost"})))


@pytest.mark.parametrize("path", ["/etc", "../other"])
def test_data_path_outside_app_directory_is_rejected(tmp_path, path):
    entry = {**app_entry(tmp_path), "data": [path]}
    assert validate(write_apps(tmp_path, entry))


@pytest.mark.parametrize("content", ["", "apps:\n", "apps: {}\n", "- name: blog\n", "apps:\n  - blog\n", "apps: ["])
def test_malformed_apps_file_is_reported_not_raised(tmp_path, content):
    (tmp_path / "apps.yaml").write_text(content)
    assert validate(tmp_path)
