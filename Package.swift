// swift-tools-version:5.10
//
// NotchIsland — the iPhone's Dynamic Island, reimagined for the MacBook notch,
// built on top of boring.notch (GPL-3.0).
//
// The canonical build is `./Scripts/build.sh`, which uses plain `swiftc`
// (works with only the Command Line Tools installed) and assembles + signs
// NotchIsland.app. This manifest mirrors the same layout so the project can
// also be opened in Xcode or built with `swift build` on a healthy toolchain.
//
import PackageDescription

let package = Package(
    name: "NotchIsland",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"]),
    ],
    targets: [
        .target(name: "Defaults", path: "Vendor/Defaults", exclude: ["LICENSE"]),
        .target(
            name: "KeyboardShortcuts",
            path: "Vendor/KeyboardShortcuts",
            exclude: ["LICENSE", "resource_bundle_accessor.swift"],
            resources: [.process("Localization")]
        ),
        .target(name: "LaunchAtLogin", path: "Vendor/LaunchAtLogin", exclude: ["LICENSE"]),
        .target(name: "SwiftUIIntrospect", path: "Vendor/SwiftUIIntrospect", exclude: ["LICENSE"]),
        .target(name: "SkyLightWindow", path: "Vendor/SkyLightWindow", exclude: ["LICENSE"]),
        .target(
            name: "MacroVisionKit",
            path: "Vendor/MacroVisionKit",
            exclude: ["LICENSE"],
            swiftSettings: [.unsafeFlags(["-swift-version", "6"])]
        ),
        .executableTarget(
            name: "NotchIsland",
            dependencies: [
                "Defaults", "KeyboardShortcuts", "LaunchAtLogin",
                "SwiftUIIntrospect", "SkyLightWindow", "MacroVisionKit",
            ],
            path: "boringNotch",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "boringNotch.entitlements",
                "Localizable.xcstrings",
                "metal",
                "Preview Content",
                "boring.m4a",
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
