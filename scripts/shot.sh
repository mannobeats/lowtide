#!/bin/zsh
# Captures one window of Lowtide (never the full screen) to a PNG.
#   scripts/shot.sh out.png [window title substring] [pid]
# With a pid, only that process's windows count (several copies running).
OUT=${1:-/tmp/lowtide.png}
TITLE=${2:-}
PID=${3:-0}
ID=$(swift -e '
import CoreGraphics
let args = CommandLine.arguments
let title = args.first { $0.hasPrefix("t:") }.map { String($0.dropFirst(2)) } ?? ""
let pid = args.first { $0.hasPrefix("p:") }.flatMap { Int($0.dropFirst(2)) } ?? 0
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.filter { ["Lowtide", "Lowtide"].contains($0["kCGWindowOwnerName"] as? String ?? "") }
  .filter { pid == 0 || ($0["kCGWindowOwnerPID"] as? Int) == pid }
  .filter { ($0["kCGWindowLayer"] as? Int) == 0 }
  .filter { title.isEmpty || (($0["kCGWindowName"] as? String) ?? "").contains(title) }
  .sorted { (($0["kCGWindowBounds"] as? [String: Double])?["Width"] ?? 0) > (($1["kCGWindowBounds"] as? [String: Double])?["Width"] ?? 0) }
if let id = match.first?["kCGWindowNumber"] as? Int { print(id) }
' "t:$TITLE" "p:$PID" 2>/dev/null)
[[ -z $ID ]] && { echo "no window"; exit 1; }
screencapture -o -x -l $ID $OUT && echo $OUT
