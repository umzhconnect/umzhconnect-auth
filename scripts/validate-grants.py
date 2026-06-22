#!/usr/bin/env python3
"""
Validate the grant-based client configuration:

  1. Every app_key referenced in a grants file must have a matching app config
     in keycloak/config/apps/.

  2. Every required_scope declared by an app must be present in each grant
     that targets that app.

Usage:
  python3 scripts/validate-grants.py

Can be run from any directory; paths are resolved relative to this script.
Exit code 0 = all checks pass. Exit code 1 = one or more errors found.

Requires: pyyaml  (pip install pyyaml)
"""

import sys
import os
import glob

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml is required. Install it with: pip install pyyaml")
    sys.exit(2)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT  = os.path.dirname(SCRIPT_DIR)
APPS_DIR   = os.path.join(REPO_ROOT, "keycloak", "config", "apps")
GRANTS_DIR = os.path.join(REPO_ROOT, "keycloak", "config", "grants")


def load_yaml_dir(directory):
    result = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
        key = os.path.splitext(os.path.basename(path))[0]
        with open(path) as f:
            result[key] = yaml.safe_load(f)
    return result


def main():
    errors = []

    apps   = load_yaml_dir(APPS_DIR)
    grants = load_yaml_dir(GRANTS_DIR)

    if not apps:
        print(f"ERROR: no app files found in {APPS_DIR}")
        sys.exit(2)
    if not grants:
        print(f"ERROR: no grant files found in {GRANTS_DIR}")
        sys.exit(2)

    grant_count = 0

    for server_key, grant_cfg in sorted(grants.items()):
        for app_key, app_grant in sorted((grant_cfg.get("grants") or {}).items()):
            grant_count += 1

            # Check 1: referenced app must exist
            if app_key not in apps:
                errors.append(
                    f"{server_key}: grant references unknown app '{app_key}'"
                    f" — no matching file in keycloak/config/apps/"
                )
                continue

            # Check 2: all required_scopes must be covered by the grant
            required = set(apps[app_key].get("required_scopes") or [])
            granted  = set(app_grant.get("scopes") or [])
            missing  = required - granted

            for scope in sorted(missing):
                errors.append(
                    f"{server_key}: grant for '{app_key}' is missing"
                    f" required scope '{scope}'"
                )

    if errors:
        print(f"FAIL — {len(errors)} error(s) in {grant_count} grant(s):\n")
        for e in errors:
            print(f"  FAIL  {e}")
        sys.exit(1)

    print(
        f"OK — {grant_count} grant(s) across {len(grants)} FHIR server(s)"
        f" validated against {len(apps)} app(s)."
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
