#!/usr/bin/env python3
"""Check release sequencing and rejection handling without keys or Apple uploads."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
FAKE_TOOL = r'''
import json
import os
from pathlib import Path
import shutil
import sys
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["RELEASE_CHECK_LOG"], "a") as log:
    log.write(json.dumps([name, args]) + "\n")
if name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"status": os.environ.get("RELEASE_CHECK_STATUS", "Accepted")}))
    sys.exit(int(os.environ.get("RELEASE_CHECK_EXIT", "0")))
if name == "ditto":
    source, target = map(Path, args[-2:])
    if "-c" in args:
        target.write_bytes(b"archive")
    else:
        shutil.copytree(source, target, dirs_exist_ok=True)
if name == "hdiutil" and args[0] == "create":
    Path(args[-1]).write_bytes(b"disk image")
if name == "generate_appcast":
    (Path(args[-1]) / "appcast.xml").write_text("<rss/>")
'''


def check(settings, success, notarizations=0):
    with tempfile.TemporaryDirectory(prefix="microdlna-release-check-") as temporary:
        root = Path(temporary)
        for script in ("build-dmg.sh", "build-release.sh"):
            shutil.copy2(PROJECT / script, root / script)
        builder = root / "build-app.sh"
        builder.write_text("#!/bin/sh\nexit 0\n")
        builder.chmod(0o755)
        app = root / ".build/microDLNA.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "MacOS/microdlna").touch()
        version_info = plistlib.dumps({"CFBundleShortVersionString": "1.0"})
        (app / "Info.plist").write_bytes(version_info)
        (root / "App").mkdir()
        (root / "App/Info.plist").write_bytes(version_info)
        tools = root / "tools"
        tools.mkdir()
        sparkle_tools = root / ".build/artifacts/sparkle/Sparkle/bin"
        sparkle_tools.mkdir(parents=True)
        for name in ("lipo", "ditto", "hdiutil", "codesign", "xcrun", "spctl",
                     "generate_appcast", "sign_update"):
            executable = (sparkle_tools if name in ("generate_appcast", "sign_update") else tools) / name
            executable.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            executable.chmod(0o755)
        log = root / "calls.jsonl"
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("SIGNING_IDENTITY", "NOTARY_PROFILE")}
        environment.update(settings, PATH=f"{tools}:{os.environ['PATH']}", RELEASE_CHECK_LOG=str(log))
        result = subprocess.run(["./build-release.sh"], cwd=root, env=environment,
                                capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        published = (root / ".build/releases/v1.0/appcast.xml").exists()
        assert published == success, "An incomplete release produced an appcast"
        submissions = [i for i, (name, args) in enumerate(calls)
                       if name == "xcrun" and args[:2] == ["notarytool", "submit"]]
        assert len(submissions) == notarizations
        if success and notarizations:
            validated = [i for i, (name, args) in enumerate(calls)
                         if name == "xcrun" and args[:2] == ["stapler", "validate"]]
            feed = next(i for i, (name, _) in enumerate(calls) if name == "generate_appcast")
            assert len(validated) == 2
            assert submissions[0] < validated[0] < submissions[1] < validated[1] < feed
        if not success:
            assert not any(name == "generate_appcast" for name, _ in calls)


signed = {"SIGNING_IDENTITY": "Developer ID Application: Example (TEAM)", "NOTARY_PROFILE": "test"}
check({}, True)
check(signed, True, notarizations=2)
check({**signed, "RELEASE_CHECK_STATUS": "Invalid"}, False, notarizations=1)
check({**signed, "RELEASE_CHECK_EXIT": "1"}, False, notarizations=1)
check({"NOTARY_PROFILE": "test"}, False)
check({"SIGNING_IDENTITY": signed["SIGNING_IDENTITY"]}, False)
print("Release checks passed: local builds, notarization order, rejected submissions, and incomplete settings")
