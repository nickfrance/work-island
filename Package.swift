// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ilha",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IlhaCore", targets: ["IlhaCore"]),
        .executable(name: "ilha-hook", targets: ["ilha-hook"]),
        .executable(name: "IlhaApp", targets: ["IlhaApp"]),
    ],
    targets: [
        .target(name: "IlhaCore"),
        .executableTarget(name: "ilha-hook", dependencies: ["IlhaCore"]),
        // Os `.lproj` não entram como recurso do SwiftPM (o bundle dele iria para a raiz do `.app` e
        // quebraria a assinatura): `scripts/bundle-app.sh` copia para `Contents/Resources`.
        .executableTarget(name: "IlhaApp", dependencies: ["IlhaCore"], exclude: ["Resources"]),
        .testTarget(name: "IlhaCoreTests", dependencies: ["IlhaCore"]),
    ]
)
