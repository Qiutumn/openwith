# Openwith

Open selected files in external applications from Emacs. Configure ordered
file associations, then enable the global mode.

This fork fixes the Windows process-return regression and replaces global
file-read interception with file-opening command integrations. Background
reads and previews retain their normal Emacs behavior.

Requires **Emacs 28.2 or later**. No third-party Emacs package is required.
Windows uses its built-in Windows PowerShell for explicit executables;
Unix/macOS require sh and nohup. Python 3 is used only by the native tests.

## Installation

Download [openwith.el](https://raw.githubusercontent.com/Qiutumn/openwith/main/openwith.el)
and install it with M-x package-install-file, or add its directory to load-path:

~~~elisp
(add-to-list 'load-path "~/path/to/openwith/")
(require 'openwith)
(openwith-mode 1)
~~~

Emacs 29+ can install this fork with:

~~~elisp
(package-vc-install
 '(openwith :url "https://github.com/Qiutumn/openwith"
            :branch "main"))
~~~

MELPA's openwith recipe currently points to jpkotta/openwith, so installing
the MELPA package does not select this fork. Keep only one copy on load-path.
To upgrade an already loaded old copy, disable openwith-mode, load the new
file, then enable the mode again; enabling also removes stale file handlers.

## Associations

Each entry is (REGEXP PROGRAM ARGUMENTS). The **first matching entry wins**.
PROGRAM is an executable name/path or the symbol default. Arguments are strings
or the symbol file, which is replaced with the absolute file name. Programs
are never interpreted as shell command strings.

~~~elisp
(setq openwith-associations
      (list
       ;; Use the operating system's application for PDFs.
       (list (openwith-make-extension-regexp '("pdf")) 'default '(file))
       ;; Use a specific program and preserve its arguments on every platform.
       (list (openwith-make-extension-regexp '("mp4" "mkv" "mp3"))
             "vlc" '("--play-and-exit" file))
       (list (openwith-make-extension-regexp '("docx" "xlsx" "pptx"))
             'default '(file))))
~~~

For example, a Windows PDF viewer can be configured as:

~~~elisp
(setq openwith-associations
      '(("\\.pdf\\'" "C:/Program Files/SumatraPDF/SumatraPDF.exe"
         ("-reuse-instance" file))))
~~~

Use the actual path installed on your machine. System-default entries require
exactly (file) as arguments; select an explicit executable for custom flags.
The default configuration uses system applications instead of legacy program
names such as acroread or xmms.

Extension helpers match the absolute end of the name, including compound
extensions such as ps.gz. Matching ignores case by default, independent of
the current buffer. Set openwith-case-fold-search to nil for case sensitivity.

## Confirmation and opening in Emacs

Set openwith-confirm-invocation to t to confirm launches. Declining opens
the file in Emacs and does not ask about later matching associations.

M-x openwith-find-file bypasses associations for one visit. A Lisp caller can
temporarily bypass every integration:

~~~elisp
(let ((openwith-inhibit t))
  (find-file "document.pdf"))
~~~

Literal visits remain in Emacs. Missing files, directories, remote files,
and files with unsaved changes in a visiting buffer also stay in Emacs.
Remote files are not downloaded or passed as TRAMP names to local programs.

## Integrations and return values

- C-x C-f, other-window/frame variants, read-only variants and alternate-file
  commands dispatch before creating a buffer. External success returns nil,
  leaves the current buffer/window alone, and updates recentf. Wildcard calls
  return the buffers opened internally; externally opened entries are omitted.
- Dired RET and recentf use these entry points. Emacs 30 also provides Dired E
  for explicitly using the system default application.
- Ido final file selection is supported, including read-only and other
  window/frame variants. Its minibuffer previews and literal reads are skipped.
- Consult recent files and its final file action are supported; preview actions
  do not launch applications. The optional integration is tested with Consult
  3.6 on Emacs 30.2. Vertico's standard find-file completion needs no adapter.
- Plain Org file links use openwith rules before Org's application choices.
  Explicit in-Emacs/system requests and line/search locators retain Org's
  behavior. Bind openwith-inhibit to keep Org's own association selection.
- insert-file-contents, direct find-file-noselect calls, and Dired display-file
  keep their normal buffer-returning behavior. Third-party callers requiring a
  buffer should use find-file-noselect or bind openwith-inhibit. Add integration
  at a final user action, never at a preview/content-reading operation.

Disabling the mode removes its advice, including optional integrations loaded
after the mode was enabled. The old openwith-file-handler remains a forwarding
compatibility function; the mode no longer registers it.

## Process behavior and diagnostics

Windows system-default opening uses ShellExecute and returns a launch
acknowledgement, not a process. Explicit executables use a hidden, short-lived
PowerShell helper calling the Unicode .NET/Windows API. This preserves empty
arguments, quotes, trailing backslashes and Unicode even when Emacs's locale
coding differs from the Windows ANSI code page. The helper waits at most
15 seconds for launch acknowledgement. Launch errors are reported; the target
application's later exit code is not observable through this detached backend.
Applications using an ANSI argument parser can still impose their own encoding
limits.

Unix/macOS use nohup and a fixed shell wrapper. The executable, log path and
every argument are separate process arguments, including paths with spaces.
Standard input/output are disconnected from Emacs so the application survives
Emacs exiting. Nonzero exits produce an openwith warning with up to 8 KiB of
stderr. Temporary diagnostic files are deleted after exit while Emacs is
running. If Emacs exits first, the application's temporary openwith-*.log may
remain in the system temporary directory; stderr files can grow while the
application runs. No success message is thrown as an error.

“Opening … externally” acknowledges dispatch, not proof that a GUI finished
loading the document. Native integration tests verify argument transmission
and child survival after the parent Emacs exits.

## Development and validation

~~~sh
emacs --batch -Q --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile openwith.el
emacs --batch -Q -l tests/run-tests.el
~~~

Tests require Python 3 on PATH for the real Unicode argument recorder.
The native tests launch hidden/noninteractive helper programs, not desktop
viewers. The Unix-only diagnostic test is skipped on Windows. The optional
Consult test is skipped unless Consult and Compat are on load-path.

CI tests Emacs 28.2 and 30.2 on Linux, and Emacs 30.2 on Windows and macOS.
On Emacs 30.2 it also checks out fixed Consult/Compat versions for integration
tests. Both interpreted and byte-compiled package behavior are tested.

See [CHANGELOG.md](CHANGELOG.md) for the changes and [COPYING](COPYING) for
GPL version 2. The package is licensed under GPL-2.0-or-later; original
authorship is retained.

