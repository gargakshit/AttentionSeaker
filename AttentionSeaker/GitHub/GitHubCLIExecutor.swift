import Foundation

struct GitHubCLIResult: Equatable, Sendable {
    let standardOutput: Data
    let standardError: String
    let terminationStatus: Int32
}

protocol GitHubCLIExecuting: AnyObject {
    var executableURL: URL? { get }
    var executableOverridePath: String? { get set }
    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCLIResult
}

@MainActor
final class LocalGitHubCLIExecutor: GitHubCLIExecuting {
    private let fileManager: FileManager
    private let environment: [String: String]
    var executableOverridePath: String?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableOverridePath: String? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.executableOverridePath = executableOverridePath
    }

    var executableURL: URL? {
        if let executableOverridePath {
            var isDirectory: ObjCBool = false
            guard executableOverridePath.hasPrefix("/"),
                  fileManager.fileExists(
                    atPath: executableOverridePath,
                    isDirectory: &isDirectory
                  ),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: executableOverridePath)
            else {
                return nil
            }
            return URL(fileURLWithPath: executableOverridePath)
        }

        var candidatePaths: [String] = []
        if let path = environment["PATH"] {
            candidatePaths.append(contentsOf: path.split(separator: ":").map {
                String($0) + "/gh"
            })
        }
        candidatePaths.append(contentsOf: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/opt/local/bin/gh",
            "/usr/bin/gh",
        ])

        var visited: Set<String> = []
        for path in candidatePaths where visited.insert(path).inserted {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCLIResult {
        guard let executableURL else {
            throw GitHubCLIError.executableNotFound
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AttentionSeaker-gh-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("stdin")
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: inputURL.path, contents: standardInput ?? Data())
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        fileManager.createFile(atPath: errorURL.path, contents: nil)

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    continuation.resume(returning: finishedProcess.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try Task.checkCancellation()

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let output = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        return GitHubCLIResult(
            standardOutput: output,
            standardError: errorText,
            terminationStatus: status
        )
    }
}
