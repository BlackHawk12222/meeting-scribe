#!/usr/bin/env python3
"""0.7.3.1: check Credits & licenses against the build.

usage: check_licenses.py <Package.resolved> <Scribe.app/Contents/Resources/Licenses>

Fails (exit 1) when a package pinned in Package.resolved has no entry in licenses.json (matched by
"pin" = the pin's identity), or when a license/notice file an entry names is missing from the
bundle. Prints every pin with its version and license.
"""
import json, os, sys

resolved_path, lic_dir = sys.argv[1], sys.argv[2]
errors = []
manifest_path = os.path.join(lic_dir, "licenses.json")
if not os.path.isfile(manifest_path):
    print("::error::licenses.json is not in the app bundle (%s)" % manifest_path)
    sys.exit(1)
entries = json.load(open(manifest_path))["entries"]
by_pin = {e["pin"]: e for e in entries if e.get("pin")}

pins = []
if os.path.isfile(resolved_path):
    data = json.load(open(resolved_path))
    raw = data.get("pins") or data.get("object", {}).get("pins") or []
    for p in raw:
        ident = p.get("identity") or (p.get("package") or "").lower()
        st = p.get("state") or {}
        pins.append((ident, st.get("version") or (st.get("revision") or "?")[:10], p.get("location") or p.get("repositoryURL")))
else:
    errors.append("Package.resolved not found at %s" % resolved_path)

for ident, ver, loc in pins:
    e = by_pin.get(ident)
    if e is None:
        errors.append("resolved package '%s' %s (%s) has no entry in Resources/Licenses/licenses.json" % (ident, ver, loc))
    else:
        print("LICENSE_CHECK pin=%s version=%s license=%s" % (ident, ver, e["license"]))

for e in entries:
    for f in ([e["file"]] if e.get("file") else []) + (e.get("notices") or []):
        path = os.path.join(lic_dir, f)
        if not os.path.isfile(path) or os.path.getsize(path) < 200:
            errors.append("license file missing or empty in the bundle: %s (%s)" % (f, e["id"]))

stale = sorted(set(by_pin) - {i for i, _, _ in pins})
if pins and stale:
    print("::warning::licenses.json lists packages that are no longer resolved: %s" % ", ".join(stale))

for err in errors:
    print("::error::" + err)
print("LICENSE_CHECK pins=%d entries=%d errors=%d" % (len(pins), len(entries), len(errors)))
sys.exit(1 if errors else 0)
