import ProjectDescription

let project = Project(
    name: "AudiobookForge",
    organizationName: "pyMoLt",
    // v3.1: German source strings, English translation (Localizable.xcstrings).
    options: .options(automaticSchemesOptions: .disabled, developmentRegion: "de"),
    // v4.1: Phonon on the Neural Engine (Swift package with Gradium's
    // compiled core, pinned to the release the Core ML exporter matches).
    packages: [
        .remote(url: "https://github.com/gradium-ai/xn-ptts", requirement: .exact("0.4.2")),
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            // Apple silicon only (MLX, Neural Engine; PhononCore ships arm64 only).
            "ARCHS": "arm64",
            "ENABLE_HARDENED_RUNTIME": "NO",
            // Ad-hoc signed for local distribution.
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": "",
            "CODE_SIGN_IDENTITY": "-",
        ]
    ),
    targets: [
        .target(
            name: "AudiobookForge",
            destinations: .macOS,
            product: .app,
            bundleId: "com.pymolt.AudiobookForge",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "AudiobookForge",
                "CFBundleShortVersionString": "4.4.0",
                "CFBundleVersion": "4",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIconName": "AppIcon",
                "LSMinimumSystemVersion": "26.0",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSHumanReadableCopyright": "Copyright (c) 2026 pyMoLt. MIT License.",
                "ITSAppUsesNonExemptEncryption": false,
                "NSMicrophoneUsageDescription": "Aufnehmen einer eigenen Stimme für das Stimmklonen (optional).",
            ]),
            sources: ["AudiobookForge/Sources/**"],
            resources: ["AudiobookForge/Resources/**"],
            copyFiles: [
                // Core ML exporter for Phonon (see Helpers/README.md), next to
                // the app binary and signed with it.
                .executables(name: "Helpers", files: [.glob(pattern: "Helpers/phonon-coreml-export", codeSignOnCopy: true)]),
            ],
            entitlements: nil,
            dependencies: [.package(product: "ptts")],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "CODE_SIGN_STYLE": "Manual",
                    "DEVELOPMENT_TEAM": "",
                    "CODE_SIGN_IDENTITY": "-",
                ]
            )
        ),
        .target(
            name: "AudiobookForgeTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.pymolt.AudiobookForge.tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: ["AudiobookForgeTests/**"],
            dependencies: [.target(name: "AudiobookForge")]
        ),
    ],
    schemes: [
        .scheme(
            name: "AudiobookForge",
            shared: true,
            buildAction: .buildAction(targets: ["AudiobookForge"]),
            // Tests compare German UI strings — run them in German
            // regardless of the Mac's (or the app's) language.
            testAction: .targets(
                ["AudiobookForgeTests"],
                arguments: .arguments(launchArguments: [
                    .launchArgument(name: "-AppleLanguages", isEnabled: true),
                    .launchArgument(name: "(de)", isEnabled: true),
                ])
            ),
            runAction: .runAction(executable: "AudiobookForge")
        ),
    ]
)
