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
//   NeutrinoOOXML   Foundation + Compression. The `.docx` a document is stored as.
//
// NeutrinoOOXML deliberately depends on nothing else here: it is a file format, not a client, and
// Sheets and Slides need the same zip and XML plumbing for `.xlsx` and `.pptx`.
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
