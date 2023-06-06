//
//  TaskRunner.swift
//  KitchenSync (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import Foundation
import Combine

// Shoule the debug window be its own package?
public struct DebugLogEntry: Identifiable {
  public let id = UUID()
  public var entry = ""
}

public class DebugLog: ObservableObject, Identifiable {
  public var id = UUID()
  public let label: String!
  
  @Published public var entries = [DebugLogEntry]()
  
  init(label: String) {
    self.label = label
  }
}

@MainActor public class DebugViewModel: ObservableObject {
  @Published public var debugLogs = [DebugLog]()
  private var disposables = Set<AnyCancellable>()
  
  public static let shared = DebugViewModel()
}

public enum Executable: String {
  case brew = "file:///opt/homebrew/bin/brew"
  case archetecture = "file:///usr/bin/arch"
  case git = "file:///usr/bin/git"
}

public enum TaskStatus {
  // Not super thrilled with complete having two arguments. Is there a better way?
  // data is needed for JSON deserialization. [String] is used for things like porcelain
  case complete(Data, [String])
  case buffer(String)
}

enum TaskError: Error {
  case unknownRunError(Error)
}

public protocol TaskRunnerProtocol {
//  func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())?) throws
  func launch(tool: URL, arguments: [String], input: Data, completionHandler: @escaping CompletionHandler)
}

public extension TaskRunnerProtocol {
//  // Help from Ray Wenderlich Forum
//  // Method issues a callback on each line of data from process.
//  // It will also return the entire output at the end of the process.
//  // This is useful when we want the entire output to parse (JSON) versus line by line output for basic commands
//  func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())? = nil) throws {
//    let process = Process()
//    let pipeOutput = Pipe()
//    let pipeError = Pipe()
//
//    process.executableURL = URL(fileURLWithPath: url.rawValue)
//    process.arguments = command
//
//    process.standardOutput = pipeOutput
//    process.standardError = pipeError
//    let debuglog = DebugLog(label: "\(url.rawValue) \(command.joined(separator: " "))")
//    DispatchQueue.main.async {
//      DebugViewModel.shared.debugLogs.append(debuglog)
//    }
//    /// Starts the external process.
//    // (This does the same as ”launch()“, but it is a more modern API.)
//
//    DispatchQueue.global(qos: .background).async {
//      try? process.run()
//      /// A buffer to store partial lines of data before we can turn them into strings.
//      ///
//      /// This is important, because we might get only the first or the second half of a multi‐byte character. Converting it before getting the rest of the character would result in corrupt replacements (�).
//      var stream = Data()
//
//      /// The POSIX newline character. (Windows line endings are more complicated, but they still contain it.)
//      let newline = "\n"
//      /// The newline as a single byte of data instead of a string (since we will be looking for it in data, not strings.
//      let newlineData = newline.data(using: String.Encoding.utf8)!
//
//      /// Reads whatever data the pipe has ready for us so far, returning `nil` when the pipe finished.
//      func read() -> Data? {
//        /// The data in the pipe.
//        ///
//        /// This will only be empty if the pipe is finished. Otherwise the pipe will stall until it has more. (See the documentation for `availableData`.)
//        let newData = pipeOutput.fileHandleForReading.availableData
//        // If the new data is empty, the pipe was indicating that it is finished. `nil` is a better indicator of that, so we return `nil`.
//        // If there actually is data, we return it.
//        return newData.isEmpty ? nil : newData
//      }
//
//      // The purpose in the following loop‐based design is two‐fold:
//      // 1. Each line of output can be handled in real time as it arrives.
//      // 2. The entire thing is encapsulated in a single synchronous function. (It is much easier to send a synchronous task to another queue than it is to stall a queue to wait for the result of an asynchronous task.)
//
//      /// A variable to store the output as we catch it.
//      var outputData = Data()
//      var outputArray = [String]()
//
//      // Loop as long as “shouldEnd” is “false”.
//      while process.isRunning {
//        // “autoreleasepool” cleans up after some Objective C stuff Foundation will be doing.
//        autoreleasepool {
//          guard let newData = read() else {
//            // “read()” returned `nil`, so we reached the end.
//            //          shouldEnd = true
//            // This returns from the autorelease pool.
//            return
//          }
//          // Put the new data into the buffer.
//          stream.append(newData)
//
//          // Loop as long as we can find a line break in what’s left.
//          while let lineEnd = stream.range(of: newlineData) {
//            /// The data up to the newline.
//            let lineData = stream.subdata(in: stream.startIndex ..< lineEnd.lowerBound)
//
//            // Clear the part of the buffer we’ve already dealt with.
//            stream.removeSubrange(..<lineEnd.upperBound)
//            /// The line converted back to a string.
//            let line = String(decoding: lineData, as: UTF8.self)
//
//            outputData.append(lineData)
//            outputArray.append(line)
//            Task { @MainActor in
//              debuglog.entries.append(DebugLogEntry(entry: line))
//              // TODO: The concept of buffer has issues with async.
//              // Look into making buffer be an async queue.
////              callback?(.buffer(line))
//            }
//          }
//        }
//      }
//      DispatchQueue.main.async {
//        callback?(.complete(outputData, outputArray))
//      }
//    }
//  }
  
  /// Runs the specified tool as a child process, supplying `stdin` and capturing `stdout`.
  ///
  /// - important: Must be run on the main queue.
  ///
  /// - Parameters:
  ///   - tool: The tool to run.
  ///   - arguments: The command-line arguments to pass to that tool; defaults to the empty array.
  ///   - input: Data to pass to the tool’s `stdin`; defaults to empty.
  ///   - completionHandler: Called on the main queue when the tool has terminated.

  func launch(tool: URL, arguments: [String] = [], input: Data = Data(), completionHandler: @escaping CompletionHandler) {
    // This precondition is important; read the comment near the `run()` call to
    // understand why.
    dispatchPrecondition(condition: .onQueue(.main))
    
    let group = DispatchGroup()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    
    var errorQ: Error? = nil
    var output = Data()
    
    let proc = Process()
    proc.executableURL = tool
    proc.arguments = arguments
    proc.standardInput = inputPipe
    proc.standardOutput = outputPipe
    group.enter()
    
    let debuglog = DebugLog(label: "\(tool.description) \(arguments.joined(separator: " "))")
    
    DispatchQueue.main.async {
      DebugViewModel.shared.debugLogs.append(debuglog)
    }
    
    proc.terminationHandler = { _ in
      // This bounce to the main queue is important; read the comment near the
      // `run()` call to understand why.
      DispatchQueue.main.async {
        group.leave()
      }
    }
    
    // This runs the supplied block when all three events have completed (task
    // termination and the end of both I/O channels).
    //
    // - important: If the process was never launched, requesting its
    // termination status raises an Objective-C exception (ouch!).  So, we only
    // read `terminationStatus` if `errorQ` is `nil`.
    
    group.notify(queue: .main) {
      if let error = errorQ {
        completionHandler(.failure(error), output)
      } else {
        completionHandler(.success(proc.terminationStatus), output)
      }
    }
    
    do {
      func posixErr(_ error: Int32) -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: nil) }
      
      // If you write to a pipe whose remote end has closed, the OS raises a
      // `SIGPIPE` signal whose default disposition is to terminate your
      // process.  Helpful!  `F_SETNOSIGPIPE` disables that feature, causing
      // the write to fail with `EPIPE` instead.
      
      let fcntlResult = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      guard fcntlResult >= 0 else { throw posixErr(errno) }
      
      // Actually run the process.
      
      try proc.run()
      
      // At this point the termination handler could run and leave the group
      // before we have a chance to enter the group for each of the I/O
      // handlers.  I avoid this problem by having the termination handler
      // dispatch to the main thread.  We are running on the main thread, so
      // the termination handler can’t run until we return, at which point we
      // have already entered the group for each of the I/O handlers.
      //
      // An alternative design would be to enter the group at the top of this
      // block and then leave it in the error hander.  I decided on this
      // design because it has the added benefit of all my code running on the
      // main queue and thus I can access shared mutable state, like `errorQ`,
      // without worrying about thread safety.
      
      // Enter the group and then set up a Dispatch I/O channel to write our
      // data to the child’s `stdin`.  When that’s done, record any error and
      // leave the group.
      //
      // Note that we ignore the residual value passed to the
      // `write(offset:data:queue:ioHandler:)` completion handler.  Earlier
      // versions of this code passed it along to our completion handler but
      // the reality is that it’s not very useful. The pipe buffer is big
      // enough that it usually soaks up all our data, so the residual is a
      // very poor indication of how much data was actually read by the
      // client.
      
      group.enter()
      let writeIO = DispatchIO(type: .stream, fileDescriptor: inputPipe.fileHandleForWriting.fileDescriptor, queue: .main) { _ in
        // `FileHandle` will automatically close the underlying file
        // descriptor when you release the last reference to it.  By holidng
        // on to `inputPipe` until here, we ensure that doesn’t happen. And
        // as we have to hold a reference anyway, we might as well close it
        // explicitly.
        //
        // We apply the same logic to `readIO` below.
        try! inputPipe.fileHandleForWriting.close()
      }
      let inputDD = input.withUnsafeBytes { DispatchData(bytes: $0) }
      writeIO.write(offset: 0, data: inputDD, queue: .main) { isDone, _, error in
        print(1)
        if isDone || error != 0 {
          writeIO.close()
          if errorQ == nil && error != 0 { errorQ = posixErr(error) }
          group.leave()
        }
      }
      
      // Enter the group and then set up a Dispatch I/O channel to read data
      // from the child’s `stdin`.  When that’s done, record any error and
      // leave the group.
      
      group.enter()
      let readIO = DispatchIO(type: .stream, fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor, queue: .main) { _ in
        try! outputPipe.fileHandleForReading.close()
      }
      readIO.read(offset: 0, length: .max, queue: .main) { isDone, chunkQ, error in
        output.append(contentsOf: chunkQ ?? .empty)
        print(String(data: chunkQ as AnyObject as! Data, encoding: .utf8))
        if isDone || error != 0 {
          readIO.close()
          if errorQ == nil && error != 0 { errorQ = posixErr(error) }
          group.leave()
        }
      }
    } catch {
      // If either the `fcntl` or the `run()` call threw, we set the error
      // and manually call the termination handler.  Note that we’ve only
      // entered the group once at this point, so the single leave done by the
      // termination handler is enough to run the notify block and call the
      // client’s completion handler.
      errorQ = error
      proc.terminationHandler!(proc)
    }
  }

  /// Called when the tool has terminated.
  ///
  /// This must be run on the main queue.
  ///
  /// - Parameters:
  ///   - result: Either the tool’s termination status or, if something went
  ///   wrong, an error indicating what that was.
  ///   - output: Data captured from the tool’s `stdout`.

  typealias CompletionHandler = (_ result: Result<Int32, Error>, _ output: Data) -> Void


  
}




