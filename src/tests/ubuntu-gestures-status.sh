#!/bin/bash
# Helper permission reports must belong to the current running process.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/main.swift" <<'SWIFT'
import Foundation
var failures = 0
func expect(_ label: String, _ value: Bool) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
let old = "omacvm-gestures: starting (pid 10)\nomacvm-gestures: permissions: Accessibility granted, Input Monitoring granted\n"
let current = old + "omacvm-gestures: starting (pid 20)\nomacvm-gestures: permissions: Accessibility granted, Input Monitoring MISSING\n"
expect("separate current grants", UbuntuGesturesStatus.parse(current, pid: 20) == "Accessibility: Allowed\nInput Monitoring: Not granted")
expect("old process report rejected", UbuntuGesturesStatus.parse(current, pid: 10) == nil)
expect("missing report rejected", UbuntuGesturesStatus.parse(old + "omacvm-gestures: starting (pid 20)\n", pid: 20) == nil)
expect("missing startup rejected", UbuntuGesturesStatus.parse("omacvm-gestures: permissions: Accessibility granted, Input Monitoring granted", pid: 20) == nil)
let changed = current + "omacvm-gestures: permissions: Accessibility granted, Input Monitoring granted\n"
expect("latest report wins", UbuntuGesturesStatus.parse(changed, pid: 20) == "Accessibility: Allowed\nInput Monitoring: Allowed")
var nestedLayout = false
let timer = Timer(timeInterval: 0, repeats: false) { _ in nestedLayout = true }
RunLoop.main.add(timer, forMode: .default)
let lines = Storage.processLines()
timer.invalidate()
expect("process listing still returns commands", !lines.isEmpty)
expect("process listing does not reenter the run loop", !nestedLayout)
exit(failures == 0 ? 0 : 1)
SWIFT
swiftc -o "$T/tests" "$R/app/app/Sources/OmacVM/UbuntuGesturesStatus.swift" "$R/app/app/Sources/OmacVM/Storage.swift" "$T/main.swift"
"$T/tests"
