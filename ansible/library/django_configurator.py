#!/usr/bin/python
# -*- coding: utf-8 -*-

# Copyright: (c) 2026, Andrew
# GNU General Public License v3.0+ (see https://www.gnu.org/licenses/gpl-3.0.txt)

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: django_configurator
short_description: Generate Django local settings with database and environment configuration
description:
  - Generates C(<project_path>/<settings_package>/local_settings.py) with C(DEBUG),
    C(ALLOWED_HOSTS), C(DATABASES) and any additional settings.
  - The project's C(settings.py) must import C(local_settings) at its end, so the
    generated values override the defaults. The module refuses to run otherwise,
    because the generated file would be silently ignored.
  - C(settings.py) itself is never modified - it comes from git, and editing it
    would conflict with the next code update.
  - Idempotent. The file is rewritten only when the rendered content differs.
options:
  project_path:
    description: Django project root, the directory that contains C(manage.py).
    required: true
    type: path
  settings_package:
    description: Python package that contains C(settings.py).
    type: str
    default: hc
  environment:
    description: Deployment environment. C(production) sets C(DEBUG = False).
    required: true
    type: str
    choices: [development, production]
  db_host:
    description: PostgreSQL server host.
    required: true
    type: str
  db_port:
    description: PostgreSQL server port.
    type: int
    default: 5432
  db_name:
    description: Database name.
    required: true
    type: str
  db_user:
    description: Database user.
    required: true
    type: str
  db_password:
    description: Database password.
    required: true
    type: str
  allowed_hosts:
    description:
      - Values for C(ALLOWED_HOSTS).
      - Required when O(environment=production). Defaults to C(["*"]) for development.
    type: list
    elements: str
    default: []
  additional_settings:
    description:
      - Any other Django settings.
      - Keys must be upper-case Python identifiers - Django ignores lower-case settings.
      - Values must be literals - strings, numbers, booleans, null, lists and dictionaries.
      - C(DEBUG), C(ALLOWED_HOSTS) and C(DATABASES) are managed by dedicated options
        and cannot be set here.
    type: dict
    default: {}
  mode:
    description:
      - Permissions of the generated file. The file contains the database password,
        so it defaults to C(0600) instead of the umask-based default.
    type: raw
  owner:
    description: Owner of the generated file.
    type: str
  group:
    description: Group of the generated file.
    type: str
notes:
  - Supports C(check_mode) and C(diff_mode). The database password is masked in the diff.
author:
  - Andrew
"""

EXAMPLES = r"""
- name: Configure Django Application Settings
  django_configurator:
    project_path: /opt/django-sample-app/src
    environment: production
    db_host: 10.60.11.63
    db_name: hc
    db_user: hc
    db_password: "{{ db_password }}"
    allowed_hosts:
      - app.example.com
      - "{{ ansible_default_ipv4.address }}"
    additional_settings:
      SITE_NAME: Week 4 Healthchecks
      REGISTRATION_OPEN: false
    owner: root
    group: django
    mode: "0640"
  register: config_result

- name: Output Configuration Result
  ansible.builtin.debug:
    msg: "{{ config_result.message }}"
"""

RETURN = r"""
message:
  description: Human-readable result.
  returned: always
  type: str
  sample: "Django settings applied to /opt/django-sample-app/src/hc/local_settings.py (added: ALLOWED_HOSTS, DATABASES, DEBUG)"
path:
  description: Path of the generated file.
  returned: always
  type: str
  sample: /opt/django-sample-app/src/hc/local_settings.py
settings:
  description: Names of all settings in the generated file.
  returned: always
  type: list
  elements: str
  sample: [ALLOWED_HOSTS, DATABASES, DEBUG, SITE_NAME]
changes:
  description: Detailed report of changed settings. Names only, values are never returned.
  returned: always
  type: dict
  sample: {added: [SITE_NAME], removed: [], modified: [DATABASES]}
"""

import ast
import math
import os
import re
import tempfile

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.common.text.converters import to_native

HEADER = (
    "# Managed by Ansible module django_configurator.\n"
    "# Manual changes will be overwritten on the next deploy.\n"
)
MANAGED_KEYS = ("ALLOWED_HOSTS", "DATABASES", "DEBUG")
SETTING_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
DEFAULT_MODE = "0600"


def literal_error(value, path):
    """Return an error message if value cannot be written as a Python literal, else None."""
    if value is None or isinstance(value, (bool, int, str)):
        return None
    if isinstance(value, float):
        return (
            None
            if math.isfinite(value)
            else f"{path}: non-finite float is not a literal"
        )
    if isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            error = literal_error(item, f"{path}[{index}]")
            if error:
                return error
        return None
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                return f"{path}: dictionary keys must be strings"
            error = literal_error(item, f"{path}[{key!r}]")
            if error:
                return error
        return None
    return f"{path}: unsupported type {type(value).__name__}"


def validate(params):
    """Return a list of human-readable validation errors."""
    errors = []
    for name in ("db_host", "db_name", "db_user", "db_password"):
        if not params[name].strip():
            errors.append(f"{name} must not be empty")
    if not 1 <= params["db_port"] <= 65535:
        errors.append("db_port must be between 1 and 65535")
    if params["environment"] == "production" and not params["allowed_hosts"]:
        errors.append("allowed_hosts is required for production")
    for key, value in params["additional_settings"].items():
        if not SETTING_NAME.match(key):
            errors.append(
                f"additional_settings: {key!r} is not an upper-case setting name"
            )
        elif key in MANAGED_KEYS:
            errors.append(
                f"additional_settings: {key} is managed by a dedicated option"
            )
        else:
            error = literal_error(value, key)
            if error:
                errors.append(f"additional_settings: {error}")
    return errors


def build_settings(params):
    """Desired settings as a plain dict. Mirrors the postgres block of hc/settings.py."""
    development = params["environment"] == "development"
    settings = {
        "DEBUG": development,
        "ALLOWED_HOSTS": params["allowed_hosts"] or ["*"],
        "DATABASES": {
            "default": {
                "ENGINE": "django.db.backends.postgresql",
                "HOST": params["db_host"],
                "PORT": params["db_port"],
                "NAME": params["db_name"],
                "USER": params["db_user"],
                "PASSWORD": params["db_password"],
                "CONN_MAX_AGE": 0,
                "TEST": {"CHARSET": "UTF8"},
                "OPTIONS": {
                    "application_name": params["settings_package"],
                    "sslmode": "prefer",
                    "target_session_attrs": "read-write",
                },
            }
        },
    }
    settings.update(params["additional_settings"])
    return settings


def to_python(value, indent=0):
    """Deterministic, readable Python literal. Dict keys are sorted for stable output."""
    inner = " " * (indent + 4)
    outer = " " * indent
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [
            f"{inner}{key!r}: {to_python(value[key], indent + 4)},"
            for key in sorted(value)
        ]
        # Python 3.9 forbids backslashes inside f-string expressions: join first
        body = "\n".join(items)
        return f"{{\n{body}\n{outer}}}"
    if isinstance(value, (list, tuple)):
        if not value:
            return "[]"
        items = [f"{inner}{to_python(item, indent + 4)}," for item in value]
        body = "\n".join(items)
        return f"[\n{body}\n{outer}]"
    return repr(value)


def render(settings):
    lines = [HEADER]
    for name in sorted(settings):
        lines.append(f"\n{name} = {to_python(settings[name])}\n")
    return "".join(lines)


def parse_settings(source):
    """Top-level NAME = <literal> assignments of an existing file."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return {}
    result = {}
    for node in tree.body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
        ):
            try:
                result[node.targets[0].id] = ast.literal_eval(node.value)
            except ValueError:
                result[node.targets[0].id] = None
    return result


def describe_changes(old, new):
    return {
        "added": sorted(set(new) - set(old)),
        "removed": sorted(set(old) - set(new)),
        "modified": sorted(key for key in set(new) & set(old) if old[key] != new[key]),
    }


def summary(changes):
    parts = [
        f"{kind}: {', '.join(names)}"
        for kind, names in sorted(changes.items())
        if names
    ]
    return "; ".join(parts) or "formatting only"


def read_file(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def write_atomically(module, path, content):
    """Write to a temp file in the same directory, then rename - never a half-written file."""
    fd, tmp_path = tempfile.mkstemp(
        prefix=".local_settings.", suffix=".tmp", dir=os.path.dirname(path)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        module.atomic_move(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            project_path=dict(type="path", required=True),
            settings_package=dict(type="str", default="hc"),
            environment=dict(
                type="str", required=True, choices=["development", "production"]
            ),
            db_host=dict(type="str", required=True),
            db_port=dict(type="int", default=5432),
            db_name=dict(type="str", required=True),
            db_user=dict(type="str", required=True),
            db_password=dict(type="str", required=True, no_log=True),
            allowed_hosts=dict(type="list", elements="str", default=[]),
            additional_settings=dict(type="dict", default={}),
        ),
        add_file_common_args=True,
        supports_check_mode=True,
    )
    params = module.params

    errors = validate(params)
    if errors:
        module.fail_json(msg=f"Invalid parameters: {'; '.join(errors)}", errors=errors)

    package_dir = os.path.join(params["project_path"], params["settings_package"])
    settings_py = os.path.join(package_dir, "settings.py")
    dest = os.path.join(package_dir, "local_settings.py")

    if not os.path.isdir(params["project_path"]):
        module.fail_json(msg=f"project_path {params['project_path']} does not exist")
    settings_source = None
    try:
        settings_source = read_file(settings_py)
    except (IOError, OSError) as exc:
        module.fail_json(msg=f"Cannot read {settings_py}: {to_native(exc)}")
    if settings_source is None:
        module.fail_json(
            msg=f"settings.py not found at {settings_py} - "
            "is project_path a Django project?"
        )
    elif "local_settings" not in settings_source:
        module.fail_json(
            msg=f"{settings_py} does not import local_settings - "
            "the generated file would be ignored"
        )

    if params["environment"] == "production" and "*" in params["allowed_hosts"]:
        module.warn(
            "ALLOWED_HOSTS contains '*' in production - Host header validation is disabled"
        )

    settings = build_settings(params)
    content = render(settings)
    current = None
    try:
        current = read_file(dest)
    except (IOError, OSError) as exc:
        module.fail_json(msg=f"Cannot read {dest}: {to_native(exc)}")

    content_changed = current != content
    changes = describe_changes(parse_settings(current) if current else {}, settings)

    if content_changed and not module.check_mode:
        try:
            write_atomically(module, dest, content)
        except (IOError, OSError) as exc:
            module.fail_json(msg=f"Cannot write {dest}: {to_native(exc)}")

    changed = content_changed
    if os.path.exists(dest):
        file_args = module.load_file_common_arguments(params, path=dest)
        if file_args.get("mode") is None:
            file_args["mode"] = DEFAULT_MODE
        changed = module.set_fs_attributes_if_different(file_args, changed)

    if content_changed:
        verb = "would be applied" if module.check_mode else "applied"
        message = f"Django settings {verb} to {dest} ({summary(changes)})"
    elif changed:
        message = (
            f"Django settings in {dest} are up to date, file attributes corrected"
        )
    else:
        message = f"Django settings in {dest} are already up to date"

    result = dict(
        changed=changed,
        message=message,
        path=dest,
        settings=sorted(settings),
        changes=changes,
    )
    if module._diff and content_changed:
        result["diff"] = dict(
            before=current or "", after=content, before_header=dest, after_header=dest
        )
    module.exit_json(**result)


if __name__ == "__main__":
    main()
