// swift-tools-version: 5.9
import PackageDescription

// The code every Neutrino iOS app shares: account identity, the OAuth flow, the E2EE key
// lifecycle, and the sign-in screens.
//
// Four layers, because they have four different dependency footprints — and one of them has to
// stay linkable from a share extension, which must not pull in SwiftUI:
//
//   NeutrinoCore    Foundation only. Config, Keychain, storage, wire models.
//   NeutrinoAuth    + the OAuth/PKCE flow and device registration.
//   NeutrinoCrypto  + libsodium. The identity keypair and everything sealed to it.
//   NeutrinoUI      + SwiftUI. Login, register, key import, lock screen.
//   NeutrinoOOXML   Foundation + Compression. Zip and XML plumbing, and the `.docx` reader.
//
// NeutrinoOOXML deliberately depends on nothing else here: it is a file format, not a client.
//
// What earns its place in it is the plumbing every OOXML format needs — `Zip/` and `XML/` — which
// is what Sheets links it for and what Slides will link it for. A single app's format mapping does
// not: the `.xlsx` reader and writer live in `neutrino_sheets_ios_mobile` next to the editor that
// is their only caller, because a package six apps rebuild against on save should carry nothing
// only one of them uses. `Docx/` predates that line and is the same question, still open.
let package = Package(
    name: "NeutrinoShared",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NeutrinoCore",   targets: ["NeutrinoCore"]),
        .library(name: "NeutrinoAuth",   targets: ["NeutrinoAuth"]),
        .library(name: "NeutrinoCrypto", targets: ["NeutrinoCrypto"]),
        .library(name: "NeutrinoUI",     targets: ["NeutrinoUI"]),
        .library(name: "NeutrinoOOXML",  targets: ["NeutrinoOOXML"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium", from: "0.9.1"),
    ],
    targets: [
        .target(name: "NeutrinoCore"),
        .target(name: "NeutrinoAuth", dependencies: ["NeutrinoCore"]),
        .target(
            name: "NeutrinoCrypto",
            dependencies: [
                "NeutrinoCore",
                "NeutrinoAuth",
                .product(name: "Sodium", package: "swift-sodium"),
            ]
        ),
        .target(name: "NeutrinoUI", dependencies: ["NeutrinoCore", "NeutrinoAuth", "NeutrinoCrypto"]),
        .target(name: "NeutrinoOOXML"),

        .testTarget(name: "NeutrinoCoreTests",   dependencies: ["NeutrinoCore"]),
        .testTarget(name: "NeutrinoAuthTests",   dependencies: ["NeutrinoAuth", "NeutrinoCore"]),
        .testTarget(name: "NeutrinoCryptoTests", dependencies: ["NeutrinoCrypto", "NeutrinoCore"]),
        .testTarget(name: "NeutrinoUITests",     dependencies: ["NeutrinoUI"]),
        .testTarget(name: "NeutrinoOOXMLTests",  dependencies: ["NeutrinoOOXML"]),
    ]
)
