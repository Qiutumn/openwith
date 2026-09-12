;;; openwith.el --- Open files with external programs -*- lexical-binding: t; -*-

;; Copyright (C) 2007 Markus Triska
;; Author: Markus Triska <markus.triska@gmx.at>
;; Maintainer: Qiutumn <https://github.com/Qiutumn>
;; Keywords: files, processes
;; URL: https://github.com/Qiutumn/openwith
;; Version: 20260913.1
;; Package-Requires: ((emacs "28.2"))
;; SPDX-License-Identifier: GPL-2.0-or-later

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Configure openwith-associations and enable openwith-mode.
;; Only file-opening commands are intercepted; content reads and background
;; previews keep their normal behavior.  Remote files stay in Emacs.
;; Use openwith-find-file for a one-time bypass, or bind openwith-inhibit.
;; See README.md for examples, integrations and migration notes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function w32-shell-execute "w32fns.c")
(declare-function recentf-add-file "recentf" (file))
(defvar openwith-mode)

(defgroup openwith nil
  "Associate external applications with file name patterns."
  :group 'files :group 'processes)

(defcustom openwith-associations
  '(("\\.\\(?:pdf\\|mp3\\|mp4\\|mkv\\|jpe?g\\|png\\)\\'" default (file)))
  "Ordered associations (REGEXP PROGRAM ARGS); the first match wins.
PROGRAM is an executable name/path, or the symbol default to use the
operating system's default application.  ARGS is a list of strings and
the symbol file, replaced by the absolute file name.  With default,
ARGS must be (file).  PROGRAM is never a shell command.
Declining confirmation opens in Emacs without trying later rules."
  :type '(repeat (list (regexp :tag "Files")
                       (choice (const :tag "System default" default)
                               (string :tag "Executable"))
                       (repeat :tag "Arguments"
                               (choice (const file) string))))
  :group 'openwith)

(defcustom openwith-confirm-invocation nil
  "Ask before invoking an external application."
  :type 'boolean :group 'openwith)

(defcustom openwith-case-fold-search t
  "Non-nil means association matching ignores case.
This is independent of the current buffer's case-fold-search."
  :type 'boolean :group 'openwith)

(defvar openwith-inhibit nil
  "Bind non-nil to bypass external opening without changing the mode.")

(defvar openwith--ido-catch nil
  "Non-nil catch tag while an Ido file-opening command is active.")

(defconst openwith--commands
  '(find-file find-file-other-window find-file-other-frame
    find-file-read-only find-file-read-only-other-window
    find-file-read-only-other-frame find-alternate-file
    find-alternate-file-other-window)
  "Opening commands with FILENAME and optional WILDCARDS arguments.")

(defun openwith-make-extension-regexp (strings)
  "Match a dot and one of STRINGS at the absolute end of a file name."
  (concat "\\." (regexp-opt strings) "\\'"))

(defun openwith--association (file)
  "Return the first association matching FILE, preserving match data."
  (let ((case-fold-search openwith-case-fold-search))
    (save-match-data
      (cl-find-if (lambda (association)
                    (string-match-p (car association) file))
                  openwith-associations))))

(defun openwith--executable (program)
  "Resolve PROGRAM to an executable, or report an actionable error."
  (or (and (stringp program) (not (string-empty-p program))
           (executable-find program))
      (user-error "Openwith: executable not found: %s" program)))

(defun openwith--windows-quote (argument)
  "Quote ARGUMENT for a Windows executable's C runtime argument parser.
No command shell is involved.  Preserve empty strings and backslashes."
  (concat "\""
          (replace-regexp-in-string
           "\\(\\\\*\\)\"" (lambda (match)
                            (concat (make-string
                                     (1+ (* 2 (1- (length match)))) ?\\)
                                    "\""))
           (replace-regexp-in-string
            "\\\\+\\'" (lambda (match) (concat match match)) argument t t)
           t t)
          "\""))

(defun openwith--powershell-string (string)
  "Encode STRING as a literal PowerShell string."
  (concat "'" (replace-regexp-in-string "'" "''" string t t) "'"))

(defun openwith--windows-start (command arglist hidden)
  "Start COMMAND with ARGLIST through the Unicode Windows API.
HIDDEN hides the target window, for noninteractive helper programs.
A short-lived PowerShell helper avoids ShellExecute's ANSI conversion of
parameters in Emacs.  Wait for launch acknowledgement, not the target's exit."
  (let* ((program (openwith--executable command))
         (powershell
          (or (executable-find "powershell.exe")
              (let ((path (expand-file-name
                           "System32/WindowsPowerShell/v1.0/powershell.exe"
                           (or (getenv "SystemRoot") "C:/Windows"))))
                (and (file-executable-p path) path))
              (user-error "Openwith: Windows PowerShell is unavailable")))
         (script
          (concat
           "$ErrorActionPreference='Stop'; try { "
           "$p=New-Object System.Diagnostics.ProcessStartInfo; $p.FileName="
           (openwith--powershell-string program)
           "; $p.Arguments="
           (openwith--powershell-string
            (mapconcat #'openwith--windows-quote arglist " "))
           "; $p.WorkingDirectory=" (openwith--powershell-string default-directory)
           "; $p.UseShellExecute=$true; $p.WindowStyle="
           (if hidden "'Hidden'" "'Normal'")
           "; [System.Diagnostics.Process]::Start($p) | Out-Null; exit 0 "
           "} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"))
         (output (generate-new-buffer " *openwith-launch*"))
         process)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "openwith-launch" :buffer output :noquery t
                 :connection-type 'pipe :sentinel #'ignore
                 :command (list powershell "-NoProfile" "-NonInteractive"
                                "-WindowStyle" "Hidden" "-EncodedCommand"
                                (base64-encode-string
                                 (encode-coding-string script 'utf-16le) t))))
          (let ((deadline (+ (float-time) 15)))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (when (process-live-p process)
            (user-error "Openwith: Windows launch timed out for %s" program))
          (unless (zerop (process-exit-status process))
            (user-error "Openwith: could not launch %s: %s" program
                        (with-current-buffer output (string-trim (buffer-string)))))
          t)
      (when (and process (process-live-p process)) (delete-process process))
      (kill-buffer output))))

(defun openwith-open-windows (file &optional command arglist hidden)
  "Open local FILE on Windows, optionally using COMMAND with ARGLIST.
Without COMMAND, use the system association.  HIDDEN hides a specified
program's window.  Return t on launch acknowledgement, not a process.
Launch failures are reported; the target's later exit code is unavailable."
  (unless (fboundp 'w32-shell-execute)
    (user-error "Openwith: Windows shell integration is unavailable"))
  (if command
      (openwith--windows-start command arglist hidden)
    (w32-shell-execute "open" (convert-standard-filename file))))

(defun openwith--sentinel (process _event)
  "Report failures of PROCESS and clean up its diagnostic file."
  (when (memq (process-status process) '(exit signal))
    (let ((log (process-get process 'openwith-log)))
      (when log
        (process-put process 'openwith-log nil)
        (unwind-protect
            (unless (and (eq (process-status process) 'exit)
                         (zerop (process-exit-status process)))
              (let ((details
                     (when (file-readable-p log)
                       (with-temp-buffer
                         (let ((size (file-attribute-size (file-attributes log))))
                           (insert-file-contents log nil (max 0 (- size 8192))))
                         (string-trim (buffer-string))))))
                (display-warning
                 'openwith
                 (format "%s failed (exit %s)%s"
                         (process-get process 'openwith-program)
                         (process-exit-status process)
                         (if (string-empty-p (or details "")) ""
                           (concat ": " details)))
                 :warning)))
          (when (file-exists-p log) (delete-file log)))))))

(defun openwith-open-unix (command arglist)
  "Run COMMAND with ARGLIST, surviving termination of Emacs.
Return a process with exit queries disabled.  User values are separate
arguments.  A fixed shell wrapper disconnects application standard I/O
from Emacs's pipes; nohup prevents termination by SIGHUP."
  (let* ((program (openwith--executable command))
         (nohup (openwith--executable "nohup"))
         (shell (openwith--executable "sh"))
         (log (make-temp-file "openwith-" nil ".log"))
         (startup (generate-new-buffer " *openwith-startup*"))
         process)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "openwith" :buffer startup :noquery t
                 :connection-type 'pipe
                 :command (append
                           (list nohup shell "-c"
                                 "log=$1; shift; trap '' HUP; printf 'ready\\n'; exec \"$@\" </dev/null >/dev/null 2>\"$log\""
                                 "openwith" log program)
                           arglist)
                 :sentinel #'ignore))
          ;; Do not let Emacs exit before the child has installed its signal
          ;; handling.  An unstarted nohup can itself be killed by SIGHUP.
          (let ((deadline (+ (float-time) 15)))
            (while (and (process-live-p process)
                        (with-current-buffer startup
                          (not (string-match-p "ready\n" (buffer-string))))
                        (< (float-time) deadline))
              (accept-process-output process 0.01)))
          (unless (with-current-buffer startup
                    (string-match-p "ready\n" (buffer-string)))
            (user-error "Openwith: could not initialize launcher: %s"
                        (with-current-buffer startup (string-trim (buffer-string)))))
          (process-put process 'openwith-log log)
          (process-put process 'openwith-program program)
          (set-process-sentinel process #'openwith--sentinel)
          ;; Cover a process which exited before sentinel installation.
          (openwith--sentinel process "")
          process)
      (when process (set-process-buffer process nil))
      (kill-buffer startup)
      (unless (and process (process-get process 'openwith-program))
        (when (and process (process-live-p process)) (delete-process process))
        (when (file-exists-p log) (delete-file log))))))

(defun openwith--launch (file association)
  "Launch FILE according to ASSOCIATION and return a launch result."
  (let ((program (nth 1 association))
        (arguments (nth 2 association)))
    (unless (and (= (length association) 3)
                 (proper-list-p arguments)
                 (cl-every (lambda (arg) (or (stringp arg) (eq arg 'file)))
                           arguments))
      (user-error "Openwith: arguments must be strings or the symbol file"))
    (if (eq program 'default)
        (progn
          (unless (equal arguments '(file))
            (user-error "Openwith: system default requires arguments (file)"))
          (pcase system-type
            ('windows-nt (openwith-open-windows file))
            ('darwin (openwith-open-unix "open" (list file)))
            (_ (openwith-open-unix "xdg-open" (list file)))))
      (unless (stringp program)
        (user-error "Openwith: program must be an executable or default"))
      (setq arguments (mapcar (lambda (arg) (if (eq arg 'file) file arg)) arguments))
      (if (eq system-type 'windows-nt)
          (openwith-open-windows file program arguments)
        (openwith-open-unix program arguments)))))

(defun openwith--try-open (filename)
  "Open FILENAME externally when eligible; return non-nil if handled.
Remote, missing, nonregular, and locally modified files stay in Emacs.
Declining the first matching association also leaves the file to Emacs."
  (when (and openwith-mode (not openwith-inhibit) (stringp filename))
    (let* ((file (expand-file-name filename))
           (association (and (not (file-remote-p file))
                             (openwith--association file))))
      (when (and association (file-regular-p file)
                 (not (let ((buffer (find-buffer-visiting file)))
                        (and buffer (buffer-modified-p buffer)))))
        (when (or (not openwith-confirm-invocation)
                  (y-or-n-p (format "Open %s with %s? "
                                      (file-name-nondirectory file)
                                      (nth 1 association))))
          (openwith--launch file association)
          (when (featurep 'recentf) (recentf-add-file file))
          (message "Opening %s externally" (file-name-nondirectory file))
          t)))))

(defun openwith--around-find-file (original filename &optional wildcards)
  "Dispatch FILENAME before ORIGINAL creates a buffer; honor WILDCARDS."
  (cond
   ((or openwith-inhibit (not openwith-mode))
    (funcall original filename wildcards))
   ((and wildcards find-file-wildcards
         (not (file-remote-p filename))
         (not (file-name-quoted-p filename))
         (string-match-p "[[*?]" filename)
         (file-expand-wildcards filename t))
    (let ((files (file-expand-wildcards filename t))
          (find-file-wildcards nil))
      (delq nil (mapcar (lambda (file)
                         (openwith--around-find-file original file nil))
                       files))))
   ((openwith--try-open filename) nil)
   (t
    ;; Nested entry points must not retry confirmation.
    (let ((openwith-inhibit t)) (funcall original filename wildcards)))))

(defun openwith--around-file-action (original file &rest args)
  "Dispatch FILE at a final action boundary; call ORIGINAL with ARGS otherwise."
  (unless (openwith--try-open file)
    (let ((openwith-inhibit t)) (apply original file args))))

(defun openwith--around-org (original path &optional in-emacs line search)
  "Dispatch plain Org PATH links, respecting IN-EMACS, LINE and SEARCH."
  (unless (and (not in-emacs) (not line) (not search)
               (openwith--try-open (if (equal path "") buffer-file-name
                                     (substitute-in-file-name path))))
    (let ((openwith-inhibit t)) (funcall original path in-emacs line search))))

(defun openwith--around-ido (original method &rest args)
  "Scope Ido interception to an opening METHOD in ORIGINAL with ARGS."
  (let ((openwith--ido-catch
         (and (not openwith-inhibit)
              (memq method '(nil selected-window other-window other-frame
                             raise-frame maybe-frame display))
              (make-symbol "openwith-ido"))))
    (if openwith--ido-catch
        (catch openwith--ido-catch (apply original method args))
      (apply original method args))))

(defun openwith--around-noselect (original filename &rest args)
  "Intercept only Ido's final visit to FILENAME; otherwise call ORIGINAL.
ARGS retains the normal find-file-noselect contract, including RAWFILE.
Minibuffer previews and all other background visits remain untouched."
  (if (and openwith--ido-catch (zerop (minibuffer-depth))
           (not (nth 1 args)) (openwith--try-open filename))
      (throw openwith--ido-catch nil)
    (apply original filename args)))

(defun openwith-file-handler (operation &rest args)
  "Relay legacy file handler OPERATION with ARGS without interception."
  (let ((inhibit-file-name-handlers
         (cons 'openwith-file-handler
               (and (eq inhibit-file-name-operation operation)
                    inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))
    (apply operation args)))

;;;###autoload
(defun openwith-find-file (filename &optional wildcards)
  "Visit FILENAME in Emacs this time, bypassing associations.
WILDCARDS is passed unchanged to find-file."
  (interactive (find-file-read-args "Find file in Emacs: " nil))
  (let ((openwith-inhibit t)) (find-file filename wildcards)))

(defconst openwith--integrations
  '((consult--file-action . openwith--around-file-action)
    (org-open-file . openwith--around-org)
    (ido-file-internal . openwith--around-ido))
  "Optional package integration points and their advice functions.")

(defun openwith--install-integrations ()
  "Install integrations for loaded packages while the mode is enabled."
  (when openwith-mode
    (dolist (entry openwith--integrations)
      (when (fboundp (car entry))
        (advice-add (car entry) :around (cdr entry))))))

(with-eval-after-load 'consult (openwith--install-integrations))
(with-eval-after-load 'org (openwith--install-integrations))
(with-eval-after-load 'ido (openwith--install-integrations))

;;;###autoload
(define-minor-mode openwith-mode
  "Dispatch file-opening commands to external applications.
Low-level reads and previews remain in Emacs.  Bind openwith-inhibit to
bypass it, or use openwith-find-file for one visit."
  :lighter "" :global t
  ;; Remove a stale handler when upgrading an already loaded installation.
  (setq file-name-handler-alist
        (rassq-delete-all 'openwith-file-handler file-name-handler-alist))
  (dolist (command openwith--commands)
    (if openwith-mode
        (advice-add command :around #'openwith--around-find-file)
      (advice-remove command #'openwith--around-find-file)))
  (if openwith-mode
      (progn
        (advice-add 'find-file-noselect :around #'openwith--around-noselect)
        (openwith--install-integrations))
    (advice-remove 'find-file-noselect #'openwith--around-noselect)
    (dolist (entry openwith--integrations)
      (advice-remove (car entry) (cdr entry)))))

(provide 'openwith)
;;; openwith.el ends here
