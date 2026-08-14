import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct GitHubCLIExecutorTests {
    @Test
    func usesTheDiscoveredExecutableAndInheritedGlobalEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionSeaker-ExecutorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("gh")
        let script = """
            #!/bin/sh
            printf '%s\n' "$GH_CONFIG_DIR"
            /bin/cat
            """
        #expect(FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(script.utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let executor = LocalGitHubCLIExecutor(environment: [
            "PATH": directory.path,
            "GH_CONFIG_DIR": "/user/global-gh-config",
        ])
        let input = Data("request-from-stdin".utf8)

        let result = try await executor.run(arguments: ["api", "graphql"], standardInput: input)

        #expect(executor.executableURL == executable)
        #expect(result.terminationStatus == 0)
        #expect(String(data: result.standardOutput, encoding: .utf8) ==
            "/user/global-gh-config\nrequest-from-stdin")
    }
}
