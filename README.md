# Storage Genie for iPhone

Pairs an iPhone with the owner's own assistant ("genie") by a one-time code, the same way as the Android app. The genie can then suggest photos and videos to clean up. **Nothing is deleted unless the person ticks it and confirms Apple's own delete sheet**, and deleted items stay in Recently Deleted for 30 days.

## What iOS allows
- The app sees **only the Photos library**, not the whole phone.
- Every delete goes through **Apple's confirm sheet**. The genie can never delete.
- The link to the genie runs **only while the app is open**.

## Security model
- **Pairing:** the device shows a 6-character code. It is valid for 30 minutes, works once, and rotates after 5 wrong tries.
- **Token:** the genie trades the code for a random token. The device stores only its SHA-256.
- **One genie at a time:** while paired, every other genie is refused. Only the person can unpair.
- **Transport:** iroh (QUIC, end-to-end encrypted), with the device's key in the Keychain on this device only.
- **No secrets in this repository.** Signing happens on the CI runner with credentials held in GitHub Actions secrets.

## Layout
- `StorageGenieCore/`: pure Swift. Holds pairing (`Binding`), the wire format (`Frames`), and commands with the delete gate (`Commands`).
  - Selftest: `cd StorageGenieCore && swift run sgcore-selftest`, exit 0 = PASS.
- `StorageGenie/`: the SwiftUI app. Holds the Photos library, the iroh link and the review screen.
- `project.yml`: XcodeGen. The Xcode project is generated in CI and never committed.
- `.github/workflows/ios-testflight.yml`: manual or tag-triggered build. It archives unsigned, signs only at export, and uploads to TestFlight.
