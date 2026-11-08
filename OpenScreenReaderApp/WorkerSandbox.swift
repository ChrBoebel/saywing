import Darwin
import Foundation

/// The one Seatbelt profile for every local model worker (dictation and speech).
/// `Runtime/Dictation/worker.sb` is a byte-identical copy for scripts and integration checks.
enum WorkerSandbox {
  static let profile = ##"""
    (version 1)
    ; Saywing local model workers. Parameters are canonical paths: RESOURCES worker runtime,
    ; MODEL_ROOT folder that holds the model, PYTHON interpreter binary, PYTHON_HOME its prefix.
    (deny default)
    (import "bsd.sb")
    ; Reads: the runtime, the verified model and the interpreter; system libraries come from bsd.sb.
    (allow file-read* (subpath (param "RESOURCES")) (subpath (param "MODEL_ROOT")) (subpath (param "PYTHON_HOME")))
    ; Metal: read shader caches and compile through the system compiler service on the GPU.
    (allow file-read* (regex #"^/private/var/folders/[^/]+/[^/]+/C/com\.apple\.(metal|metalfe|gpuarchiver)(/|$)"))
    (allow file-issue-extension (extension-class "com.apple.app-sandbox.read"))
    ; macOS 27: MTLCompilerService only compiles when the worker can hand it write access to
    ; these two shader caches. The worker itself still cannot write anywhere (deny file-write*).
    (allow file-issue-extension (require-all (extension-class "com.apple.app-sandbox.read-write")
      (regex #"^/private/var/folders/[^/]+/[^/]+/C/com\.apple\.(metalfe|gpuarchiver)(/|$)")))
    (allow mach-lookup (global-name "com.apple.MTLCompilerService"))
    (allow iokit-open-user-client (iokit-user-client-class "AGXDeviceUserClient" "IOSurfaceRootUserClient"))
    ; The only executable is the interpreter sandbox-exec starts; no child processes.
    (allow process-exec (literal (param "PYTHON")))
    (deny process-fork)
    ; Never network, file writes, Apple Events, pasteboard, Launch Services or privacy prompts.
    (deny network*)
    (deny file-write*)
    (allow file-write-data (literal "/dev/null"))
    (deny appleevent-send)
    (deny mach-lookup (global-name "com.apple.coreservices.launchservicesd" "com.apple.pasteboard.1"
      "com.apple.tccd" "com.apple.tccd.system" "com.apple.windowserver.active" "com.apple.nsurlsessiond"))

    """##

  /// Seatbelt matches resolved paths; Foundation's symlink resolution drops `/private`, `realpath` does not.
  static func canonicalPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// `sandbox-exec` arguments up to and including the interpreter; `nil` when a path does not exist.
  static func arguments(resources: URL, modelRoot: URL?, python: URL) -> [String]? {
    guard let root = canonicalPath(resources),
      let models = canonicalPath(modelRoot ?? resources),
      let interpreter = canonicalPath(python)
    else { return nil }
    let home = URL(fileURLWithPath: interpreter).deletingLastPathComponent().deletingLastPathComponent().path
    // An interpreter directly below `/` would make the whole disk readable.
    guard home != "/" else { return nil }
    return [
      "-p", profile,
      "-D", "RESOURCES=\(root)", "-D", "MODEL_ROOT=\(models)",
      "-D", "PYTHON=\(interpreter)", "-D", "PYTHON_HOME=\(home)",
      python.path,
    ]
  }
}
