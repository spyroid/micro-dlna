import Darwin
import Foundation

// Exercise release scripts with fake tools instead of signing keys or Apple uploads.
struct ToolCall: Codable {
    let name: String
    let arguments: [String]
}

let files = FileManager.default
let environment = ProcessInfo.processInfo.environment
let executable = URL(fileURLWithPath: CommandLine.arguments[0])
let toolNames = [
    "lipo", "ditto", "hdiutil", "codesign", "xcrun", "spctl", "generate_appcast", "sign_update",
]

func runFakeTool() throws {
    let name = executable.lastPathComponent
    let arguments = Array(CommandLine.arguments.dropFirst())
    let log = try FileHandle(forWritingTo: URL(fileURLWithPath: environment["RELEASE_CHECK_LOG"]!))
    defer { try? log.close() }
    try log.seekToEnd()
    try log.write(contentsOf: JSONEncoder().encode(ToolCall(name: name, arguments: arguments)))
    try log.write(contentsOf: Data([10]))

    if name == "xcrun", arguments.starts(with: ["notarytool", "submit"]) {
        let status = ["status": environment["RELEASE_CHECK_STATUS"] ?? "Accepted"]
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(status))
        exit(Int32(environment["RELEASE_CHECK_EXIT"] ?? "0")!)
    }
    if name == "ditto" {
        let source = URL(fileURLWithPath: arguments[arguments.count - 2])
        let target = URL(fileURLWithPath: arguments.last!)
        if arguments.contains("-c") {
            try Data("archive".utf8).write(to: target)
        } else {
            try files.copyItem(at: source, to: target)
        }
    }
    if name == "hdiutil", arguments.first == "create" {
        try Data("disk image".utf8).write(to: URL(fileURLWithPath: arguments.last!))
    }
    if name == "generate_appcast" {
        let directory = URL(fileURLWithPath: arguments.last!)
        try Data("<rss/>".utf8).write(to: directory.appendingPathComponent("appcast.xml"))
    }
}

func check(_ settings: [String: String], success: Bool, notarizations: Int = 0) throws {
    let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = files.temporaryDirectory.appendingPathComponent("microdlna-release-check-\(UUID())")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    for script in ["build-dmg.sh", "build-release.sh"] {
        try files.copyItem(
            at: project.appendingPathComponent(script), to: root.appendingPathComponent(script))
    }
    let builder = root.appendingPathComponent("build-app.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: builder)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: builder.path)
    let app = root.appendingPathComponent(".build/microDLNA.app/Contents")
    let tools = root.appendingPathComponent("tools")
    let sparkleTools = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin")
    for directory in [
        app.appendingPathComponent("MacOS"), root.appendingPathComponent("App"), tools,
        sparkleTools,
    ] {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data().write(to: app.appendingPathComponent("MacOS/microdlna"))
    let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
    try info.write(to: app.appendingPathComponent("Info.plist"))
    try info.write(to: root.appendingPathComponent("App/Info.plist"))
    for name in toolNames {
        let directory = ["generate_appcast", "sign_update"].contains(name) ? sparkleTools : tools
        // Reuse this compiled test executable as every fake command.
        try files.createSymbolicLink(
            at: directory.appendingPathComponent(name), withDestinationURL: executable)
    }
    let log = root.appendingPathComponent("calls.jsonl")
    try Data().write(to: log)
    var testEnvironment = environment
    for key in ["SIGNING_IDENTITY", "NOTARY_PROFILE", "RELEASE_CHECK_STATUS", "RELEASE_CHECK_EXIT"]
    {
        testEnvironment[key] = nil
    }
    testEnvironment.merge(settings) { _, value in value }
    testEnvironment["PATH"] = tools.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    testEnvironment["RELEASE_CHECK_LOG"] = log.path

    let process = Process()
    process.executableURL = root.appendingPathComponent("build-release.sh")
    process.currentDirectoryURL = root
    process.environment = testEnvironment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let messages = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(
        (process.terminationStatus == 0) == success, String(decoding: messages, as: UTF8.self))

    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(ToolCall.self, from: Data($0.utf8))
    }
    let published = files.fileExists(
        atPath: root.appendingPathComponent(".build/releases/v1.0/appcast.xml").path)
    precondition(published == success, "An incomplete release produced an appcast")
    let submissions = calls.indices.filter {
        calls[$0].name == "xcrun" && calls[$0].arguments.starts(with: ["notarytool", "submit"])
    }
    precondition(submissions.count == notarizations)
    if success && notarizations > 0 {
        let validated = calls.indices.filter {
            calls[$0].name == "xcrun" && calls[$0].arguments.starts(with: ["stapler", "validate"])
        }
        let feed = calls.firstIndex { $0.name == "generate_appcast" }!
        precondition(validated.count == 2)
        precondition(submissions[0] < validated[0] && validated[0] < submissions[1])
        precondition(submissions[1] < validated[1] && validated[1] < feed)
    }
    if !success {
        precondition(!calls.contains { $0.name == "generate_appcast" })
    }
}

if toolNames.contains(executable.lastPathComponent) {
    try runFakeTool()
} else {
    let signed = [
        "SIGNING_IDENTITY": "Developer ID Application: Example (TEAM)", "NOTARY_PROFILE": "test",
    ]
    try check([:], success: true)
    try check(signed, success: true, notarizations: 2)
    try check(
        signed.merging(["RELEASE_CHECK_STATUS": "Invalid"]) { _, value in value }, success: false,
        notarizations: 1)
    try check(
        signed.merging(["RELEASE_CHECK_EXIT": "1"]) { _, value in value }, success: false,
        notarizations: 1)
    try check(["NOTARY_PROFILE": "test"], success: false)
    try check(["SIGNING_IDENTITY": signed["SIGNING_IDENTITY"]!], success: false)
    print(
        "Release checks passed: local builds, notarization order, rejected submissions, and incomplete settings"
    )
}
