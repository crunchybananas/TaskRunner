import Foundation

public actor ProcessExecutor {
  
  public init() {}
  
  // MARK: - Types
  
  public enum ExecutionError: Error, LocalizedError {
    case invalidPath(String)
    case executionFailed(exitCode: Int32, stderr: String)
    case decodingFailed(Error)
    case timeout
    
    public var errorDescription: String? {
      switch self {
      case .invalidPath(let path):
        return "Invalid executable path: \(path)"
      case .executionFailed(let code, let stderr):
        return "Process failed with exit code \(code): \(stderr)"
      case .decodingFailed(let error):
        return "Failed to decode output: \(error.localizedDescription)"
      case .timeout:
        return "Process execution timed out"
      }
    }
  }
  
  public struct Result: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    
    public var stdoutString: String {
      String(data: stdout, encoding: .utf8) ?? ""
    }
    
    public var stderrString: String {
      String(data: stderr, encoding: .utf8) ?? ""
    }
    
    public var lines: [String] {
      stdoutString
        .split(separator: "\n")
        .map { String($0) }
        .filter { !$0.isEmpty }
    }
    
    public var isSuccess: Bool {
      exitCode == 0
    }
  }
  
  // MARK: - Public Methods
  
  /// Execute a command and return the full result.
  public func execute(
    _ executable: String,
    arguments: [String] = [],
    workingDirectory: String? = nil,
    throwOnNonZeroExit: Bool = true
  ) async throws -> Result {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    
    // Resolve executable path
    guard let executableURL = resolveExecutable(executable) else {
      throw ExecutionError.invalidPath(executable)
    }
    
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    
    if let workingDirectory {
      process.currentDirectoryURL = URL(filePath: workingDirectory)
    }
    
    // Run the process
    try process.run()
    
    // Read output asynchronously
    async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd()
    async let stderrData = stderrPipe.fileHandleForReading.readToEnd()
    
    // Wait for completion without blocking the actor
    let exitCode: Int32 = await withCheckedContinuation { continuation in
      if process.isRunning {
        process.terminationHandler = { proc in
          continuation.resume(returning: proc.terminationStatus)
        }
      } else {
        continuation.resume(returning: process.terminationStatus)
      }
    }
    
    let stdout = try await stdoutData ?? Data()
    let stderr = try await stderrData ?? Data()
    
    let result = Result(stdout: stdout, stderr: stderr, exitCode: exitCode)
    
    // Throw on error if requested
    if throwOnNonZeroExit && !result.isSuccess {
      throw ExecutionError.executionFailed(exitCode: exitCode, stderr: result.stderrString)
    }
    
    return result
  }
  
  /// Execute a command and decode JSON response.
  public func executeJSON<T: Decodable>(
    _ type: T.Type,
    executable: String,
    arguments: [String] = [],
    workingDirectory: String? = nil,
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    let result = try await execute(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory
    )
    
    do {
      return try decoder.decode(T.self, from: result.stdout)
    } catch {
      throw ExecutionError.decodingFailed(error)
    }
  }
  
  /// Stream output line-by-line for long-running commands.
  public func stream(
    _ executable: String,
    arguments: [String] = [],
    workingDirectory: String? = nil
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let process = Process()
          let stdoutPipe = Pipe()
          
          guard let executableURL = resolveExecutable(executable) else {
            throw ExecutionError.invalidPath(executable)
          }
          
          process.executableURL = executableURL
          process.arguments = arguments
          process.standardOutput = stdoutPipe
          process.standardError = stdoutPipe  // Merge stderr into stdout for streaming
          
          if let workingDirectory {
            process.currentDirectoryURL = URL(filePath: workingDirectory)
          }
          
          try process.run()
          
          let handle = stdoutPipe.fileHandleForReading
          
          // Read line by line
          for try await line in handle.bytes.lines {
            continuation.yield(line)
          }
          
          let exitCode: Int32 = await withCheckedContinuation { continuation in
      if process.isRunning {
        process.terminationHandler = { proc in
          continuation.resume(returning: proc.terminationStatus)
        }
      } else {
        continuation.resume(returning: process.terminationStatus)
      }
    }
          
          if exitCode != 0 {
            continuation.finish(throwing: ExecutionError.executionFailed(
              exitCode: exitCode,
              stderr: "Process exited with code \(exitCode)"
            ))
          } else {
            continuation.finish()
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
  
  // MARK: - Private Helpers
  
  private func resolveExecutable(_ path: String) -> URL? {
    // Try as absolute path first
    if path.hasPrefix("/") {
      return URL(filePath: path)
    }
    
    // Try common paths for executables
    let commonPaths = [
      "/usr/bin/\(path)",
      "/usr/local/bin/\(path)",
      "/opt/homebrew/bin/\(path)",
      "/bin/\(path)"
    ]
    
    for fullPath in commonPaths {
      if FileManager.default.isExecutableFile(atPath: fullPath) {
        return URL(filePath: fullPath)
      }
    }
    
    // Try using 'which' to find it
    let whichProcess = Process()
    whichProcess.executableURL = URL(filePath: "/usr/bin/which")
    whichProcess.arguments = [path]
    
    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    whichProcess.standardError = Pipe()
    
    do {
      try whichProcess.run()
      whichProcess.waitUntilExit()
      
      if whichProcess.terminationStatus == 0,
         let data = try pipe.fileHandleForReading.readToEnd(),
         let resolvedPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !resolvedPath.isEmpty {
        return URL(filePath: resolvedPath)
      }
    } catch {
      return nil
    }
    
    return nil
  }
}
