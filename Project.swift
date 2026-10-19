import ProjectDescription

let project = Project(
    name: "AudiobookForge",
    organizationName: "pyMoLt",
    // v3.1: German source strings, English translation (Localizable.xcstrings).
    options: .options(developmentRegion: "de"),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "ENABLE_HARDENED_RUNTIME": "NO",
            // Signed with the free "Personal Team" developer account.
            "CODE_SIGN_STYLE": "Automatic",
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
                "CFBundleShortVersionString": "3.0.0",
                "CFBundleVersion": "3",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIconName": "AppIcon",
                "LSMinimumSystemVersion": "26.0",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSHumanReadableCopyright": "Personal use.",
                "ITSAppUsesNonExemptEncryption": false,
                "NSMicrophoneUsageDescription": "Aufnehmen einer eigenen Stimme für das Stimmklonen (optional).",
            ]),
            sources: ["AudiobookForge/Sources/**"],
            resources: ["AudiobookForge/Resources/**"],
            entitlements: nil,
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "CODE_SIGN_STYLE": "Automatic",
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
