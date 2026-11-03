// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IntelDocktor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "IntelDocktor",
            path: "Sources/IntelDocktor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
