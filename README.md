# SideStore Increased Memory Limit fix

Community build that preserves `com.apple.developer.kernel.increased-memory-limit` when installing an IPA whose executable already requests it. Includes a LiveContainer + SideStore package with the iPhone Duo support from [LiveContainer PR #1695](https://github.com/LiveContainer/LiveContainer/pull/1695).

## Downloads

[Release notes and all files](https://github.com/Silverhza/SideStore/releases/tag/memoryfix-2026.11.05)

| Package | Download |
| --- | --- |
| LiveContainer 3.8.11 + patched SideStore, SDK 27.2 | [Combined IPA](https://github.com/Silverhza/SideStore/releases/download/memoryfix-2026.11.05/LiveContainer-PR1695-SideStore-memoryfix-unsigned.ipa) |
| Patched SideStore 0.7.0-memoryfix | [Standalone IPA](https://github.com/Silverhza/SideStore/releases/download/memoryfix-2026.11.05/SideStore-memoryfix-unsigned.ipa) |

These are unsigned/ad-hoc packages that need signing through your normal sideloading process. They are third-party builds of the upstream projects.

## Problem and change

SideStore's legacy App ID feature path does not enable Apple's modern `INCREASED_MEMORY_LIMIT` capability. A generated provisioning profile can consequently lack the entitlement, and re-signing drops the IPA's original request. See [SideStore issue #1616](https://github.com/SideStore/SideStore/issues/1616).

The patch reads the request per bundle, retaining the source IPA value when an older cached profile lacks the key. After legacy feature/app-group updates, it enables `INCREASED_MEMORY_LIMIT` through Apple's JSON capability API and then downloads a profile. It checks that the profile actually authorizes the entitlement, reporting an error if it does not. The capability step runs for subsequent provisioning refreshes as well as installation.

The change is in SideStore's app code; the pinned SideSign and minimuxer dependencies are unchanged. The combined IPA retains the original PR #1695 LiveContainer host, LiveProcess, widget and SideStoreSupport binaries, replacing the embedded SideStore with the patched build.

## Use with NX2Apple or another IPA

1. Sign and install one of the packages above.
2. Import the original app IPA, with `com.apple.developer.kernel.increased-memory-limit = true` in its executable's entitlements, into the patched SideStore and install it again.
3. Verify the installed app's executable signature and provisioning profile both contain the entitlement. For NX2Apple, its [entitlement guide](https://github.com/LNPANDY/NX2Apple/blob/main/ENTITLEMENTS.md) also explains checking memory headroom in `Documents/log.txt`.

Profile-only refresh does not re-sign an executable whose entitlement was already lost. Reinstall the original IPA once to repair that signature. A manually assigned provisioning profile must already authorize the capability. Adding the entitlement to an executable that never requested it is outside this patch's scope.

## Validation

- Xcode 27.2 Release archive: passed, arm64 / iPhoneOS 27.2.
- Actual request construction, entitlement selection and 13 mocked API responses: passed, with no Apple account calls in the tests.
- Combined package: ZIP integrity checked; embedded SideStore machine-code section matches the patched archive byte for byte; original LiveContainer and LiveProcess entitlement requests remain `true`.
- On 2026-11-05, the repository owner reported successful on-device testing with no issues observed. No specific memory-budget measurement is claimed.

The automated checks do not exercise a live Apple account or replace device testing. A single successful device report does not establish compatibility with every device, iOS version or account type.

## Source and rebuild

```sh
git clone --recurse-submodules https://github.com/Silverhza/SideStore.git
cd SideStore
git checkout memoryfix-2026.11.05
git submodule update --init --recursive

# Focused regression tests (macOS).
mkdir -p build
xcrun swiftc -swift-version 6 \
  SideStore/Core/Auth/IncreasedMemoryLimitCapability.swift \
  scripts/tests/IncreasedMemoryLimitCapabilityTests.swift \
  -o build/memory-capability-tests
build/memory-capability-tests

# Release archive without a development signing identity.
xcodebuild archive -project AltStore.xcodeproj -scheme SideStore \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/SideStore-memory-fix.xcarchive \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  AD_HOC_CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=XYZ0123456 \
  ORG_IDENTIFIER=com.SideStore MARKETING_VERSION=0.7.0-memoryfix
```

Use `scripts/memoryfix/package_combo.py --help` to rebuild the combined package from that archive and the original PR #1695 combined IPA. The original IPA comes from [workflow run 40319062051](https://github.com/abjugard/LiveContainer/actions/runs/40319062051), artifact `12648416512`; its SHA256 is `8159c0a7df59026a6f3f398225610ecdba762997b5098d56ab7a29cfc9011c9b`. It requires LiveContainer's `dylibify` 1.0 and Procursus `ldid` v2.1.5-procursus7. Release assets include SHA256 checksums, the fix patch, source snapshots and portable build/package records.

| Component | Source revision |
| --- | --- |
| SideStore | [LiveContainer/SideStore `ee3cc16a`](https://github.com/LiveContainer/SideStore/commit/ee3cc16a67f9fed766f79a0ed70938f0f8ad5a07) plus this patch |
| SideSign | `752d1ef602aa792a432ffa1e71646dc1ecf7363c` |
| minimuxer | `12be70dc2627307a16bfd2dc7a009080d5bec909` |
| LiveContainer PR #1695 | [Head `3b941489`](https://github.com/LiveContainer/LiveContainer/commit/3b9414897cee008f53d14eab73cfc5f310fe5cce) |

## Credits and license

Based on [SideStore](https://github.com/SideStore/SideStore), [LiveContainer/SideStore](https://github.com/LiveContainer/SideStore) and [LiveContainer](https://github.com/LiveContainer/LiveContainer). The capability request follows [AltSign's implementation](https://github.com/rileytestut/AltSign/commit/b2c88617932905b13e42f1dd0d8b1d45d26cf671), which credits GetMoreRam. The original SideStore README is retained in [README.upstream.md](README.upstream.md), and the inherited [AGPLv3 license](LICENSE) and upstream notices are retained.

## 中文说明

这是用于保留 IPA 原有 `increased-memory-limit` 权限的第三方 SideStore 修复版，另提供保留 LiveContainer PR #1695 iPhone Duo 适配的组合包。

SideStore 原流程缺少正确的 App ID 能力开通请求，可能使新 profile 不包含内存权限，进而在重签名时丢失。此补丁先开通 `INCREASED_MEMORY_LIMIT`，再获取并检查 profile，并在后续刷新时重新执行能力开通步骤。

签装本修复版后，请重新导入已包含该权限的原始 IPA。仅刷新不能修复此前已丢失的可执行文件签名；自定义 profile 也必须自行具备授权。此补丁用于保留原有权限，不负责给原本没有该权限的 IPA 添加权限。

完整构建、请求与权限选择测试、13 个模拟响应及组合包检查均已通过。
