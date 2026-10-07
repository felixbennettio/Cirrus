// Prints the CGWindowID of the frontmost on-screen window of the app at the
// given path, for `screencapture -l` (.github/workflows/glass-preview.yml).
import AppKit

let path = CommandLine.arguments.dropFirst().first ?? ""
let pids = NSWorkspace.shared.runningApplications
  .filter { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }
  .map { $0.processIdentifier }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  as? [[String: Any]] ?? []
guard let window = windows.first(where: {
  pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) && ($0[kCGWindowLayer as String] as? Int) == 0
}), let id = window[kCGWindowNumber as String] as? Int else {
  FileHandle.standardError.write("no window for \(path)\n".data(using: .utf8)!)
  exit(1)
}
print(id)
