// swift-tools-version: 6.2

// The diarization evaluation harness. It compiles the app's own meeting-voice files
// (symlinked from OpenScreenReaderApp/Meeting) against the same pinned FluidAudio as
// the app, so the numbers it reports are the adapter's. Never built by CI or the app.
import PackageDescription

let package = Package(
  name: "diarization-eval",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.2", traits: ["Diarizer"]),
  ],
  targets: [
    .executableTarget(
      name: "diarization-eval",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
