#!/usr/bin/env python3
"""Verify the local IPA's packaging and platform; never infer game compatibility."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = plistlib.loads((ROOT / "ios/Vita3K/App/Info.plist").read_bytes())["CFBundleShortVersionString"]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ipa", type=Path, default=ROOT / f"dist/ios/LinVita-{VERSION}-test.ipa")
parser.add_argument("--build-log", type=Path, default=ROOT / "dist/ios/build.log")
parser.add_argument("--report", type=Path, default=ROOT / "dist/ios/validation.json")
args = parser.parse_args()
IPA = args.ipa.resolve()


def run(*args):
    process = subprocess.run(args, text=True, capture_output=True)
    if process.returncode:
        raise RuntimeError(process.stderr or process.stdout)
    return process.stdout


with tempfile.TemporaryDirectory(prefix="linvita-verify-") as temporary:
    output = Path(temporary)
    with zipfile.ZipFile(IPA) as archive:
        assert archive.testzip() is None, "IPA CRC failure"
        names = archive.namelist()
        assert len(names) == len(set(names)), "Duplicate ZIP entries"
        for entry in archive.infolist():
            relative = Path(entry.filename)
            assert not relative.is_absolute() and ".." not in relative.parts
            assert not any(part.startswith("._") or part == "__MACOSX" for part in relative.parts), "AppleDouble files in IPA"
            archive.extract(entry, output)
            mode = (entry.external_attr >> 16) & 0o777
            if mode:
                (output / relative).chmod(mode)

    app = output / "Payload/LinVita.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "online.linxz.LinVita"
    assert info["MinimumOSVersion"] == "26.0"
    assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
    assert info["UIFileSharingEnabled"] and info["LSSupportsOpeningDocumentsInPlace"]
    executable = app / info["CFBundleExecutable"]
    core = app / "Frameworks/libVita3KCore.dylib"
    run("codesign", "--verify", "--deep", "--strict", str(app))
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(app)).encode())
    assert entitlements.get("get-task-allow") is True
    assert not any("icloud" in key or "ubiquity" in key for key in entitlements)
    images = {}
    for name, path in (("app", executable), ("core", core)):
        arch = run("lipo", "-archs", str(path)).strip()
        build = run("xcrun", "vtool", "-show-build", str(path))
        assert arch == "arm64" and "platform IOS" in build and "minos 26.0" in build
        images[name] = {"architecture": arch, "build": build.replace(str(path), name),
                        "uuid": run("dwarfdump", "--uuid", str(path)).split()[1]}
    built_core = ROOT / "build/ios-device/vita3k/libVita3KCore.dylib"
    assert images["core"]["uuid"] == run("dwarfdump", "--uuid", str(built_core)).split()[1]
    assert "_vkGetInstanceProcAddr" in run("nm", "-gU", str(executable))
    lookups = [line.strip() for line in run("nm", "-m", str(core)).splitlines()
               if "dynamically looked up" in line]
    assert all("_objc_msgSend " in line or "_vkGetInstanceProcAddr " in line for line in lookups)
    assert (app / "shaders-builtin/vulkan/render_main.frag.spv").is_file()
    assert (app / "AppIcon60x60@3x.png").is_file()

assert "BUILD SUCCEEDED" in args.build_log.read_text()
report = {
    "status": "READY_FOR_SIDELOAD_NOT_GAMEPLAY_VERIFIED", "date": datetime.now().astimezone().isoformat(),
    "ipa": str(IPA), "bytes": IPA.stat().st_size,
    "sha256": hashlib.sha256(IPA.read_bytes()).hexdigest(),
    "bundle": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "minimum_ios": info["MinimumOSVersion"],
    "signature": "ad-hoc; a sideload tool must supply the developer signature",
    "signature_verified": True, "entitlements": entitlements,
    "images": images, "dynamic_lookups": lookups,
    "package_checks": {"zip_crc": "pass", "build_log": "pass", "core_uuid_matches_build": "pass"},
    "host_tests": "not executed by this packaging checker; run the test scripts separately",
    "device_tests": {key: "pending" for key in (
        "install", "jit", "menu", "gameplay", "audio", "inputs", "save_reload", "performance", "full_campaign")},
    "build_tools": {"xcode": run("xcodebuild", "-version").strip(),
                    "iphoneos_sdk": run("xcrun", "--sdk", "iphoneos", "--show-sdk-version").strip(),
                    "deployment": "26.0"},
    "upstream": "https://github.com/veebteam/Veeb/commit/9f18e4ecbc06b7d3b787516e537937b6f00438af",
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: report[key] for key in (
    "status", "bytes", "sha256", "bundle", "minimum_ios", "signature_verified")}, ensure_ascii=False))
