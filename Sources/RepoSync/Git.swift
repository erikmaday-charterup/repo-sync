import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var ok: Bool { status == 0 && !timedOut }
    var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Git {
    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    // Background runs must never block on a credential or host-key prompt.
    static var environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"].map { [$0] } ?? []
        env["PATH"] = (extraPaths + existing).joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GCM_INTERACTIVE"] = "never"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        env["LC_ALL"] = "C"
        return env
    }()

    static func run(_ args: [String], in directory: URL, timeout: TimeInterval = 120, input: String? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(args, in: directory, timeout: timeout, input: input))
            }
        }
    }

    private static func runBlocking(_ args: [String], in directory: URL, timeout: TimeInterval, input: String?) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", directory.path] + args
        process.environment = environment
        let inPipe = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            readGroup.wait()
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            finished.wait()
        }
        readGroup.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

// Runs a quick command with no terminal and nothing on stdin, keeping only its stdout.
enum Subprocess {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "", timedOut: false
                ))
            }
        }
    }
}
