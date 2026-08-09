#!/usr/bin/env zsh
# Browser helpers — sourced by init.zsh

chrome-cdp() {
  "${DEV_ENV_ROOT:-$HOME/Documents/projects/dev-env}/scripts/browser/chrome-cdp.sh" "$@"
}

chrome() {
  open -a "Google Chrome" "$@"
}

firefox() {
  open -a "Firefox" "$@"
}

edge() {
  open -a "Microsoft Edge" "$@"
}

safari() {
  open -a "Safari" "$@"
}

# Show which app actually handles http/https URLs.
browser-default() {
  swift -e '
import AppKit
for s in ["http", "https"] {
    let u = URL(string: "\(s)://example.com")!
    print("\(s) -> \(NSWorkspace.shared.urlForApplication(toOpen: u)?.path ?? "none")")
}'
}

# Make Chrome the default browser for the current user.
#
# duti does NOT work for this on current macOS: `duti -s com.google.Chrome
# https all` registers a file EXTENSION named "https", prints "ok", and leaves
# the real URL-scheme handler untouched. `open -a Chrome --args
# --make-default-browser` is a no-op too. NSWorkspace is the supported path and
# raises the system confirmation prompt when macOS wants one.
browser-make-chrome-default() {
  swift -e '
import AppKit
import Foundation

let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")

func handler(_ scheme: String) -> String {
    let u = URL(string: "\(scheme)://example.com")!
    return NSWorkspace.shared.urlForApplication(toOpen: u)?.path ?? "none"
}

print("before: http -> \(handler("http")), https -> \(handler("https"))")

// One scheme at a time: firing both concurrently makes the second fail with
// "The file couldn’t be opened." while the confirmation prompt is up.
for scheme in ["http", "https"] {
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.setDefaultApplication(at: chrome, toOpenURLsWithScheme: scheme) { err in
        if let err = err { print("  \(scheme): \(err.localizedDescription)") }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 60)
}

let http = handler("http"), https = handler("https")
print("after:  http -> \(http), https -> \(https)")
exit((http == chrome.path && https == chrome.path) ? 0 : 1)
'
}
