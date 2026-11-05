#!/usr/bin/env python3
"""Repackage PR1695 with a compiled SideStore.app; no downloads or signing identity.

Requires macOS, Python 3, /usr/bin/{codesign,zip,unzip}, dylibify 1.0, and
ldid 2.1.5-procursus7. The output still needs signing by a sideload installer.
"""

import argparse
import hashlib
import json
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path


BASE_SHA256 = "8159c0a7df59026a6f3f398225610ecdba762997b5098d56ab7a29cfc9011c9b"
EMBEDDED = "Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/"
MEMORY_ENTITLEMENT = "com.apple.developer.kernel.increased-memory-limit"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def zip_mode(entry):
    return stat.S_IMODE(entry.external_attr >> 16)


def payload_manifest(path):
    with zipfile.ZipFile(path) as archive:
        return {entry.filename: {
            "sha256": None if entry.is_dir() else hashlib.sha256(archive.read(entry)).hexdigest(),
            "mode": oct(zip_mode(entry)),
        } for entry in archive.infolist()}


def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def package(args):
    source, base, output = (value.resolve() for value in
                            (args.sidestore_app, args.base_ipa, args.output))
    dylibify, ldid = args.dylibify.resolve(), args.ldid.resolve()
    info_path = output.with_suffix(".package-info.json")
    checksum_path = output.with_suffix(output.suffix + ".sha256")
    require(not any(path.exists() for path in (output, info_path, checksum_path)),
            "Output or sidecar already exists; choose a new output path.")
    require(source.is_dir() and (source / "SideStore").is_file(),
            "--sidestore-app must be the compiled SideStore.app.")
    require(not any(path.is_symlink() for path in source.rglob("*")),
            "Symlinks in the compiled app are unsupported by this packager.")
    require(sha256(base) == BASE_SHA256, "Base IPA does not match the PR1695 artifact.")
    source_hash = sha256(source / "SideStore")
    source_info = plistlib.loads((source / "Info.plist").read_bytes())
    require(source_info.get("DTSDKName") == args.expected_sdk, "Unexpected SideStore SDK.")
    require(source_info.get("CFBundleShortVersionString") == args.expected_version,
            "Unexpected SideStore version.")

    with tempfile.TemporaryDirectory(prefix="sidestore-memoryfix-") as directory:
        stage = Path(directory)
        with zipfile.ZipFile(base) as archive:
            require(not any(stat.S_ISLNK(entry.external_attr >> 16)
                            for entry in archive.infolist()),
                    "Symlinks in the base IPA are unsupported by this packager.")
            archive.extractall(stage)  # The exact input archive was checked above.
            # extractall() otherwise turns executables into ordinary 0644 files.
            for entry in archive.infolist():
                (stage / entry.filename).chmod(zip_mode(entry))
        app = stage / "Payload/LiveContainer.app"
        embedded = stage / EMBEDDED
        lc_info = (embedded / "LCAppInfo.plist").read_bytes()
        openssl = "Frameworks/OpenSSL.framework/OpenSSL"
        require(sha256(source / openssl) == sha256(embedded / openssl),
                "SideStore OpenSSL differs from the original; review compatibility first.")
        host_info = plistlib.loads((app / "Info.plist").read_bytes())
        require(host_info.get("DTSDKName") == args.expected_sdk, "Unexpected host SDK.")
        shutil.rmtree(embedded)
        shutil.copytree(source, embedded, symlinks=True)
        converted = embedded / "SideStore.dylib"
        run(str(dylibify), str(embedded / "SideStore"), str(converted))
        converted.replace(embedded / "SideStore")
        run(str(ldid), "-S", str(embedded / "SideStore"))
        (embedded / "SideStore").chmod(stat.S_IMODE((source / "SideStore").stat().st_mode))
        (embedded / "LCAppInfo.plist").write_bytes(lc_info)
        for extension in sorted(embedded.rglob("*.appex"), reverse=True):
            shutil.rmtree(extension)
        for signature in sorted(app.rglob("_CodeSignature"), reverse=True):
            shutil.rmtree(signature)

        binary = (embedded / "SideStore").read_bytes()
        require(len(binary) >= 16 and struct.unpack_from("<I", binary)[0] == 0xfeedfacf
                and struct.unpack_from("<I", binary, 12)[0] == 6,
                "Packaged SideStore must be a 64-bit MH_DYLIB.")
        require(b"INCREASED_MEMORY_LIMIT" in binary and MEMORY_ENTITLEMENT.encode() in binary,
                "Memory capability code is missing from the compiled SideStore.")
        for executable in (app / "LiveContainer", app / "PlugIns/LiveProcess.appex/LiveProcess"):
            result = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(executable),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            require(plistlib.loads(result.stdout).get(MEMORY_ENTITLEMENT) is True,
                    f"Increased Memory Limit is missing from {executable.name}.")

        candidate = stage / "memoryfix.ipa"
        run("/usr/bin/zip", "-q", "-r", str(candidate), "Payload",
            "-x", "._*", "-x", ".DS_Store", "-x", "__MACOSX", cwd=stage)
        run("/usr/bin/unzip", "-tq", str(candidate))
        before, after = payload_manifest(base), payload_manifest(candidate)
        expected_host = {name: entry for name, entry in before.items()
                         if not name.startswith(EMBEDDED) and "/_CodeSignature/" not in name}
        actual_host = {name: entry for name, entry in after.items() if not name.startswith(EMBEDDED)}
        require(actual_host == expected_host,
                "File contents or Unix permissions outside embedded SideStore were changed.")
        require(not any("/_CodeSignature/" in name or
                        (name.startswith(EMBEDDED) and ".appex/" in name) for name in after),
                "Stale signatures or nested extensions remain.")
        for name, entry in after.items():
            path = stage / name
            require(oct(stat.S_IMODE(path.stat().st_mode)) == entry["mode"],
                    f"Packaged Unix permissions mismatch: {name}")
            if not name.endswith("/"):
                require(sha256(path) == entry["sha256"], f"Packaged payload mismatch: {name}")
        if args.compare_payload:
            require(after == payload_manifest(args.compare_payload.resolve()),
                    "Contents or Unix permissions differ from --compare-payload IPA.")
        if args.compare_content_only:
            comparison = payload_manifest(args.compare_content_only.resolve())
            contents = lambda manifest: {name: entry["sha256"] for name, entry in manifest.items()
                                         if not name.endswith("/")}
            require(contents(after) == contents(comparison),
                    "File contents differ from --compare-content-only IPA.")
        require(sha256(source / "SideStore") == source_hash, "Input executable changed.")
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate, output)

    result = {
        "output": output.name, "output_sha256": sha256(output), "unsigned": True,
        "base_ipa_sha256": BASE_SHA256,
        "livecontainer": {"repository": "abjugard/LiveContainer", "pull_request": 1695,
                          "run_id": 40319062051, "artifact_id": 12648416512,
                          "commit": "3b9414897cee008f53d14eab73cfc5f310fe5cce"},
        "sidestore_base_commit": "ee3cc16a67f9fed766f79a0ed70938f0f8ad5a07",
        "sidestore_version": args.expected_version, "sdk": args.expected_sdk,
        "source_executable_sha256": source_hash,
        "tools_sha256": {"dylibify": sha256(dylibify), "ldid": sha256(ldid)},
        "preserved_host_file_count": sum(not name.endswith("/") for name in expected_host),
        "payload_manifest": after,
        "comparison_payload_matched": bool(args.compare_payload),
        "comparison_file_contents_matched": bool(args.compare_content_only),
    }
    info_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    checksum_path.write_text(result["output_sha256"] + "  " + output.name + "\n")
    print(f"Created {output}\nSHA256 {result['output_sha256']}\nManifest {info_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("sidestore-app", "base-ipa", "dylibify", "ldid", "output"):
        parser.add_argument("--" + argument, required=True, type=Path)
    parser.add_argument("--expected-version", default="0.7.0-memoryfix")
    parser.add_argument("--expected-sdk", default="iphoneos27.2")
    parser.add_argument("--compare-payload", type=Path,
                        help="Require all payload contents and Unix modes to match another IPA.")
    parser.add_argument("--compare-content-only", type=Path,
                        help="Compare file contents with another IPA, ignoring Unix modes.")
    args = parser.parse_args()
    try:
        package(args)
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
