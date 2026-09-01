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
let package = Package(
    name: "NeutrinoShared",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NeutrinoCore",   targets: ["NeutrinoCore"]),
        .library(name: "NeutrinoAuth",   targets: ["NeutrinoAuth"]),
        .library(name: "NeutrinoCrypto", targets: ["NeutrinoCrypto"]),
        .library(name: "NeutrinoUI",     targets: ["NeutrinoUI"]),
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

        .testTarget(name: "NeutrinoCoreTests",   dependencies: ["NeutrinoCore"]),
        .testTarget(name: "NeutrinoAuthTests",   dependencies: ["NeutrinoAuth", "NeutrinoCore"]),
        .testTarget(name: "NeutrinoCryptoTests", dependencies: ["NeutrinoCrypto", "NeutrinoCore"]),
        .testTarget(name: "NeutrinoUITests",     dependencies: ["NeutrinoUI"]),
    ]
)
