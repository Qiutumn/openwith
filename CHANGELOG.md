# Changes

## 20260913.1

- Replace global content-read interception with explicit file-opening entry points.
  External dispatch no longer kills temporary buffers or throws a success error.
- Correct Windows launch-result handling and honor configured programs and arguments.
  Use a Unicode launcher for explicit programs, including paths with spaces.
- Pass Unix command paths and arguments as separate values; preserve application
  lifetime beyond Emacs and report asynchronous failure diagnostics.
- Preserve background reads, previews, missing/directory/remote files and unsaved buffers.
- Add a one-visit Emacs command and dynamic bypass, deterministic first-rule
  confirmation, explicit case matching and strict extension end anchors.
- Integrate Dired/recentf, Ido, Consult final actions and Org plain file links.
- Replace obsolete default applications with system defaults; modernize metadata,
  installation documentation, license text, regression tests and cross-platform CI.

Compatibility: existing string-program association triples remain supported.
Windows now honors those programs; use the symbol default for the previous
system-association behavior. PROGRAM strings are executable paths, not shell
expressions. Code needing a visited buffer should use find-file-noselect or bind
openwith-inhibit; externally handled opening commands return nil.

