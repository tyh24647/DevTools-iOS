# Signing and uploading build 2

The review candidate is on `fix/testflight-media-review`. Keep that branch selected while preparing the next TestFlight build. The app and all seven extensions use version **1.0.0**, build **2**.

The simulator and unsigned device builds have passed. [CI run 42884343710](https://github.com/tyh24647/DevTools-iOS/actions/runs/42884343710) also passed a real unsigned `.xcarchive` build and verified its application layout and eight bundles. An unsigned product cannot be uploaded to TestFlight as a signed distribution. The manual distribution path creates a fresh, normally signed archive so Xcode processes the app and extension entitlements during compilation and signing. Actual signed export and upload remain unverified until the existing credentials are supplied and the manual workflow completes.

Signing and upload require access to existing Apple signing material. App Store Connect browser authentication does not supply the signing private key to a CI runner. The account's Xcode Cloud page currently shows initial setup, with no configured workflow available to run.

## Use the Mac that signed build 1

This path can use the Apple account and signing identities already configured in Xcode:

1. Check out `fix/testflight-media-review` and open `DevTools.xcodeproj`.
2. Select the **DevTools** scheme and a generic iOS device destination. Verify the existing team on the app and all seven extensions, and the shared App Group `group.com.tyh24647.DevTools`.
3. Use **Product → Archive**. The Archive action uses Release. Do not apply a global `SKIP_INSTALL=NO` override to the extension targets.
4. In Organizer, validate and distribute the archive through **App Store Connect**. Confirm all eight bundles have build number 2 and the expected identifiers before uploading.
5. After processing, use the replacement testing text and review notes in [APP-REVIEW-5.2.3.md](APP-REVIEW-5.2.3.md), after checking the signed build's behavior.

For an existing local signing setup, the equivalent archive command is:

```bash
bash Scripts/archive-ios.sh --signed
```

This command creates an archive using the configured signing assets. It does not upload it or create signing credentials. If a previous archive exists, set `DEVTOOLS_ARCHIVE_PATH` to a new location to preserve it.

## Use the manual GitHub Actions path

The existing `ios-build.yml` workflow has a manual `distribution` input:

| Value | Behavior |
| --- | --- |
| `none` | Normal browser, Swift helper, simulator, and unsigned archive checks |
| `readiness` | Report which required secret inputs are present; do not sign, export, or upload |
| `export` | Run validation, create a normally signed archive, export and verify an IPA, and save the IPA as an artifact |
| `upload` | Perform the same checks, then upload the distribution to App Store Connect with the supplied API key |

The distribution job only runs for a manual dispatch. Pull requests and ordinary pushes do not sign or upload a build. Signing jobs are serialized and are not canceled by a newer validation run.

### Existing material to supply

Add these values in the repository's **Settings → Secrets and variables → Actions**. Do not place private keys or passwords in source files, review notes, pull requests, or chat.

| Repository secret | Contents |
| --- | --- |
| `DEVTOOLS_CERTIFICATE_P12_BASE64` | Base64 of an existing Apple Distribution identity exported as `.p12`, including its private key |
| `DEVTOOLS_CERTIFICATE_PASSWORD` | The password for that `.p12` file |
| `DEVTOOLS_PROFILES_TGZ_BASE64` | Base64 of a gzip-compressed tar containing the eight existing App Store distribution `.mobileprovision` files |
| `DEVTOOLS_ASC_KEY_BASE64` | Base64 of the existing App Store Connect team API private key `.p8`; required for upload |
| `DEVTOOLS_ASC_KEY_ID` | That API key's Key ID; required for upload |
| `DEVTOOLS_ASC_ISSUER_ID` | That API key's Issuer ID; required for upload |

The workflow uses the project's existing team, `GZ6B7VNBWJ`, and the verified App Store Connect app ID `6831456709`. Each profile must authorize that team, the same supplied distribution certificate, and the shared App Group. Provide one profile for each identifier:

```text
com.tyh24647.DevTools
com.tyh24647.DevTools.Safari
com.tyh24647.DevTools.AddBlacklist
com.tyh24647.DevTools.AddAllowList
com.tyh24647.DevTools.Show
com.tyh24647.DevTools.Hide
com.tyh24647.DevTools.Enable
com.tyh24647.DevTools.Disable
```

Use App Store distribution profiles, with current expiry dates. Development, ad hoc, enterprise, wildcard, duplicate, or mismatched profiles do not satisfy this workflow. A public `.cer` file alone does not contain the private key needed to sign.

On a Mac, these commands copy existing files into the format expected by the relevant secrets. Replace the example filenames with the actual local files. The `provisioning-profiles` folder should contain only the eight profiles.

```bash
base64 -i distribution.p12 | pbcopy
COPYFILE_DISABLE=1 tar -czf profiles.tar.gz -C provisioning-profiles .
base64 -i profiles.tar.gz | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

Copy and save each value to its corresponding secret before running the next command. API key creation, certificate creation, and provisioning changes are separate account operations; this workflow uses existing material.

### Run on the repair branch

The workflow is already registered on the default branch. The GitHub CLI can select the repair branch and pass the new input without merging these changes into `main`:

```bash
gh workflow run ios-build.yml \
  --repo tyh24647/DevTools-iOS \
  --ref fix/testflight-media-review \
  -f distribution=readiness
```

Readiness reports input presence only. It does not establish that a certificate, profile, API key, or upload will be accepted. Use `distribution=export` to validate the signing material and generate a verified IPA. Use `distribution=upload` for the explicit upload operation.

Normal validation also runs a read-only readiness check on its Mac runner to report tool availability and the count of usable local signing identities. That automatic check receives no signing secrets, so its missing-input lines describe that job's environment, not an inventory of repository secrets. Use the manual `readiness` mode to check the configured secret inputs.

GitHub's web interface also offers manual workflow runs and branch selection. If it displays only the older default-branch input form, use the CLI command with `--ref` and `-f` above.

### What the distribution path verifies

The helper checks the required inputs before changing keychain or profile state. It creates an isolated checkout of the selected commit, installs the supplied identity into a temporary keychain, validates and assigns each target its own provisioning profile, and creates a signed Release archive. It preserves the source entitlements and build numbers.

Before permitting upload, the exported app and all seven extensions must have valid signatures, the expected version/build and bundle identifiers, the correct team/application identifiers and shared App Group, matching embedded distribution profiles, and no enabled development debugging entitlement. The helper does not substitute a manually re-signed unsigned archive for that process.

Upload uses Apple's `altool --upload-package` with the exact verified IPA, the app ID, and its verified bundle/version/build values. API authentication reads the supplied `.p8` from a temporary private-key directory. It does not enable Xcode automatic provisioning or re-export a different IPA for upload.

For local reuse with another App Store record, `DEVTOOLS_ASC_APP_ID` can override the numeric app ID. `DEVTOOLS_ASC_PROVIDER_ID` optionally supplies altool's public provider identifier when the account requires one. These identifiers are not additional private-key secrets; keep the defaults for this app.

Temporary private keys, imported profiles, and the temporary keychain are cleaned up; the previous keychain search list and preexisting profiles are restored. Only the IPA and a nonsecret verification summary are published as `DevTools-TestFlight-Export` artifacts. If export verification succeeds but upload fails, the workflow preserves those verified outputs for inspection.

An accepted upload still needs App Store Connect processing and the appropriate TestFlight review. This workflow does not send an App Review message, change testing metadata, add testers, or submit an App Store release.

## References

- [Apple: manually manage distribution signing](https://help.apple.com/xcode/mac/current/en.lproj/devcac6ab5b3.html)
- [Apple: provisioning profiles and signing entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple: upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple: altool package upload and API authentication](https://help.apple.com/asc/appsaltool/en.lproj/static.html)
- [GitHub: install Apple signing assets on runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub: manual workflow runs and branch selection](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
