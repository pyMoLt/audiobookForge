import ProjectDescription

let project = Project(
    name: "AudiobookForge",
    organizationName: "pyMoLt",
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
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
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "AudiobookForge",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "15.0",
                "LSApplicationCategoryType": "public.app-category.productivity",
                "NSHumanReadableCopyright": "Personal use.",
                "ITSAppUsesNonExemptEncryption": false,
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
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: ["AudiobookForgeTests/**"],
            dependencies: [.target(name: "AudiobookForge")]
        ),
    ]
)
