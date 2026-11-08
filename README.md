# NeutrinoShared

The Swift package every Neutrino Apple app is built on. It holds account identity, the OAuth
sign-in flow, the end-to-end encryption key lifecycle, the sign-in and key screens, Office file
plumbing and printing, all written once rather than copied into each app. Every app talks to the
same backend, [`wcherry/neutrino`](https://github.com/wcherry/neutrino) (`/api/v1`).

## Who uses it

Each app references the package **by local path, unversioned** (`NeutrinoShared: path:
../neutrino_shared_ios` in its `project.yml` or `Package.swift`):

- The iOS apps: Drive, Docs, Sheets, Notes, Photos, Slides and Calendar
- `neutrino_drive_mac_desktop`, the macOS Drive client
- `neutrino_atlas_mac_desktop`, and `neutrino_atlaskit` beneath it

There's no version pin to absorb a breaking change, so an edit here reaches every one of those apps
the next time it builds. They must sit beside this repository:

```
getneutrino.app/
├── neutrino_shared_ios/        ← this repo
├── neutrino_drive_ios_mobile/
├── neutrino_docs_ios_mobile/
└── …
```

## Modules

| Product | Depends on | What is in it |
|---|---|---|
| `NeutrinoCore` | Foundation only | Per-app config, Keychain, storage, wire models, Drive dates, multipart bodies, the offline file cache, network monitoring, retry policy, app links, document previews |
| `NeutrinoAuth` | `NeutrinoCore` | The OAuth/PKCE flow, access tokens, device identity and registration, Face ID / Touch ID |
| `NeutrinoCrypto` | `NeutrinoCore`, `NeutrinoAuth`, [swift-sodium](https://github.com/jedisct1/swift-sodium) | The identity keypair and keyring, key import (file, paste, QR), the key vault, recovery kits, device pairing, Drive file encryption, saved-place envelopes |
| `NeutrinoUI` | the three above, SwiftUI | Login, register, encryption setup, key import, QR scanning, lock screen, device pairing, recovery-kit restore, the connectivity banner, brand components |
| `NeutrinoOOXML` | Foundation, Compression | Zip and XML plumbing for Office files, and the `.docx` reader and writer |
| `NeutrinoPrint` | UIKit, SwiftUI | Pagination, running header, page numbers and the print dialog. Each app turns its document into a `PrintJob` |

The layers are deliberate, and shouldn't be merged:

- `NeutrinoCore` stays Foundation-only so the Drive share extension can link it without pulling in
  SwiftUI.
- `NeutrinoOOXML` and `NeutrinoPrint` depend on nothing else here. A file format and a printer need
  no account and no keys.
- A format only one app uses belongs in that app, not here. For example, the `.xlsx` reader and
  writer live in `neutrino_sheets_ios_mobile`.

## Platforms

iOS 16 and macOS 13. `NeutrinoCore`, `NeutrinoAuth`, `NeutrinoCrypto` and `NeutrinoOOXML` build
for both. `NeutrinoUI` and `NeutrinoPrint` are iOS-only: their sources are wrapped in
`#if os(iOS)`, so they compile to empty modules on macOS. A platform conditional must leave iOS
behaviour exactly as it was.

## Testing

Run the tests on both platforms:

```bash
swift test                                            # macOS
xcodebuild -scheme NeutrinoShared-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # iOS
```

Then build at least one dependent app as well, because a green package proves nothing about the
apps that rebuild against it:

```bash
cd ../neutrino_docs_ios_mobile && xcodegen generate && xcodebuild …
```

Build the Mac apps too when the change touches `NeutrinoCore`, `NeutrinoAuth` or
`NeutrinoCrypto`.

`scripts/generate_place_envelope_vectors.mjs` regenerates the saved-place test vectors from the
web's own crypto code, so `NeutrinoCrypto` is tested against what the web actually writes.

## Rules that reach beyond this repo

- **Each app's identity lives here.** `NeutrinoAppConfig+Apps.swift` gives each app its OAuth
  client id (`neutrino-ios`, `neutrino-docs-ios`, `neutrino-sheets-ios`, …) and its Keychain prefix
  (`nd`, `ndoc`, `nsheet`, `nn`, `nphoto`, `nslide`, `ncal`, `natlas`).
  - **Client ids:** every one must also be registered by a migration in `neutrino`. A client added
    only here fails sign-in with an opaque error.
  - **Prefixes:** these keep co-installed apps' sessions apart. Never reuse or drop one.
- **Encryption is a wire format.** `NeutrinoCrypto` is one of four implementations, alongside the
  web, Windows and Android, and all four must agree with each other and the server. A change to the
  key file, key vault, QR transfer or file encryption is a coordinated change across every repo.
  See `neutrino/agent_docs/end-to-end-encryption.md`.
- **The shared Keychain group holds keys only.** Every iOS app declares `com.neutrino.shared` so a key
  imported in one app is there in the others. Sessions stay in each app's own group.

Design notes are in `agent_docs/`. The platform-wide rules are in the root `CLAUDE.md` of the
workspace.
