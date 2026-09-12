;;; openwith-tests.el --- Regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'openwith)
(require 'dired)
(require 'recentf)
(require 'ido)
(require 'org)
(require 'json)
(defconst ow-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defmacro ow-fixture (&rest body)
  (declare (indent 0))
  `(let* ((directory (make-temp-file "openwith-test-" t))
          (default-directory (file-name-as-directory directory))
          (file (expand-file-name "sample.ow"))
          (other (expand-file-name "other.txt"))
          (openwith-associations '(("\\.ow\\'" "viewer" ("--page=2" file))))
          (openwith-confirm-invocation nil)
          (openwith-case-fold-search t)
          (openwith-inhibit nil)
          (recentf-list nil)
          (recentf-exclude nil)
          (recentf-auto-cleanup 'never)
          (auto-mode-alist nil)
          (enable-local-variables nil)
          (enable-local-eval nil)
          (file-name-handler-alist (copy-tree file-name-handler-alist)))
     (unwind-protect
         (save-window-excursion
           (with-temp-file file (insert "fixture\nsecond\n"))
           (with-temp-file other (insert "other"))
           (openwith-mode 1)
           ,@body)
       (openwith-mode -1)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p (file-name-as-directory directory)
                                     (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(ert-deftest ow-windows-default-return-and-recentf ()
  (ow-fixture
    (let ((system-type 'windows-nt)
          (openwith-associations '(("\\.ow\\'" default (file))))
          called (source (current-buffer)))
      (cl-letf (((symbol-function 'w32-shell-execute)
                 (lambda (&rest args) (setq called args) t)))
        (should-not (find-file file))
        (should (equal called (list "open" (convert-standard-filename file))))
        (should (eq source (current-buffer)))
        (should (buffer-live-p source))
        (should-not (get-file-buffer file))
        (should (member file recentf-list))))))

(ert-deftest ow-windows-configured-program-and-arguments ()
  (ow-fixture
    (let ((system-type 'windows-nt) called)
      (cl-letf (((symbol-function 'openwith--windows-start)
                 (lambda (&rest args) (setq called args) t)))
        (find-file file)
        (should (equal called
                       (list "viewer" (list "--page=2" file) nil)))))))

(ert-deftest ow-background-read-and-visit ()
  (ow-fixture
    (cl-letf (((symbol-function 'openwith--launch)
               (lambda (&rest _) (ert-fail "Background launch"))))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "fixture\nsecond\n")))
      (with-temp-buffer
        (insert-file-contents file t)
        (should (buffer-live-p (current-buffer))))
      (should (bufferp (find-file-noselect file))))))

(ert-deftest ow-decline-first-match-once-in-read-only-command ()
  (ow-fixture
    (let ((openwith-confirm-invocation t)
          (openwith-associations '(("\\.ow\\'" "first" (file))
                                   ("\\.ow\\'" "second" (file))))
          (prompts 0))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (cl-incf prompts) nil))
                ((symbol-function 'openwith--launch)
                 (lambda (&rest _) (ert-fail "Declined launch"))))
        (find-file-read-only file)
        (should (= prompts 1))
        (should buffer-read-only)
        (should (equal buffer-file-name file))))))

(ert-deftest ow-first-rule-and-match-data ()
  (let ((openwith-associations '(("\\.ow\\'" "first" (file))
                                 ("sample" "second" (file)))))
    (string-match "\\(a\\)" "a")
    (let ((saved (match-data)))
      (should (equal (cadr (openwith--association "sample.ow")) "first"))
      (should (equal saved (match-data))))))

(ert-deftest ow-extension-boundaries-and-case ()
  (let ((rx (openwith-make-extension-regexp '("pdf" "ps.gz"))))
    (should (string-match-p rx "a.pdf"))
    (should (string-match-p rx "a.ps.gz"))
    (should-not (string-match-p rx "a.pdf\n.txt"))
    (should-not (string-match-p rx "aXpdf"))
    (should-not (string-match-p rx "a.psXgz"))
    (let ((openwith-associations (list (list rx 'default '(file))))
          (case-fold-search nil)
          (openwith-case-fold-search t))
      (should (openwith--association "a.PDF"))
      (let ((openwith-case-fold-search nil))
        (should-not (openwith--association "a.PDF"))))))

(ert-deftest ow-remote-skipped-before-stat ()
  (ow-fixture
    (require 'tramp)
    (cl-letf (((symbol-function 'file-regular-p)
               (lambda (_) (ert-fail "Remote stat")))
              ((symbol-function 'openwith--launch)
               (lambda (&rest _) (ert-fail "Remote launch"))))
      (should-not (openwith--try-open "/ssh:example.invalid:/tmp/sample.ow")))))

(ert-deftest ow-bypass-command-and-binding ()
  (ow-fixture
    (cl-letf (((symbol-function 'openwith--launch)
               (lambda (&rest _) (ert-fail "Bypass launched"))))
      (openwith-find-file file)
      (should (equal buffer-file-name file))
      (kill-buffer (current-buffer))
      (let ((openwith-inhibit t)) (find-file file))
      (should (equal buffer-file-name file)))))

(ert-deftest ow-modified-buffer-is-preserved ()
  (ow-fixture
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer (insert "unsaved"))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (ert-fail "Unsaved launch"))))
        (find-file file)
        (should (eq buffer (current-buffer)))
        (should (buffer-modified-p))))))

(ert-deftest ow-missing-unmatched-directory ()
  (ow-fixture
    (cl-letf (((symbol-function 'openwith--launch)
               (lambda (&rest _) (ert-fail "Unexpected launch"))))
      (find-file other)
      (should (equal (buffer-string) "other"))
      (find-file (expand-file-name "missing.ow"))
      (should (zerop (buffer-size)))
      (should-not (openwith--try-open directory)))))

(ert-deftest ow-opening-variants-no-buffer-side-effects ()
  (ow-fixture
    (let ((source (current-buffer)) (calls 0)
          (readonly buffer-read-only))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (cl-incf calls) t)))
        (dolist (command openwith--commands)
          (should-not (funcall command file))
          (should (eq source (current-buffer)))
          (should (eq readonly buffer-read-only))
          (should (buffer-live-p source)))
        (should (= calls (length openwith--commands)))))))

(ert-deftest ow-mixed-wildcards ()
  (ow-fixture
    (let ((calls 0))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (cl-incf calls) t)))
        (let ((buffers (find-file (expand-file-name "*") t)))
          (should (= calls 1))
          (should (= (length buffers) 1))
          (should (equal (buffer-file-name (car buffers)) other)))))))

(ert-deftest ow-mode-toggle-and-upgrade ()
  (ow-fixture
    (push '("some-other-pattern" . ignore) file-name-handler-alist)
    (push '("" . openwith-file-handler) file-name-handler-alist)
    (openwith-mode 1)
    (openwith-mode 1)
    (should-not (rassq 'openwith-file-handler file-name-handler-alist))
    (should (rassq 'ignore file-name-handler-alist))
    (openwith-mode -1)
    (should-not (advice-member-p #'openwith--around-find-file 'find-file))
    (should-not (advice-member-p #'openwith--around-noselect 'find-file-noselect))
    (should-not (advice-member-p #'openwith--around-org 'org-open-file))
    (cl-letf (((symbol-function 'openwith--launch)
               (lambda (&rest _) (ert-fail "Disabled launch"))))
      (find-file file)
      (should (equal buffer-file-name file)))))

(ert-deftest ow-legacy-handler-relays ()
  (ow-fixture
    (push '("" . openwith-file-handler) file-name-handler-alist)
    (with-temp-buffer
      (insert-file-contents file)
      (should (equal (buffer-string) "fixture\nsecond\n")))))

(ert-deftest ow-failure-preserves-source-and-recentf ()
  (ow-fixture
    (let ((source (current-buffer)))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (user-error "No association"))))
        (should-error (find-file file) :type 'user-error)
        (should (eq source (current-buffer)))
        (should-not recentf-list)
        (should-not (get-file-buffer file))))))

(ert-deftest ow-missing-executable ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (openwith--executable "missing") :type 'user-error)))

(ert-deftest ow-invalid-arguments ()
  (dolist (rule '(("x" "viewer" (bogus))
                  ("x" "viewer" ("valid" . "invalid"))
                  ("x" default ("--flag" file))
                  ("x" 23 (file))))
    (should-error (openwith--launch "x" rule) :type 'user-error)))

(ert-deftest ow-default-unix-and-macos ()
  (dolist (platform '(gnu/linux darwin))
    (let ((system-type platform) called)
      (cl-letf (((symbol-function 'openwith-open-unix)
                 (lambda (&rest args) (setq called args) 'process)))
        (openwith--launch "/tmp/example.pdf" '("pdf" default (file)))
        (should (equal called
                       (list (if (eq platform 'darwin) "open" "xdg-open")
                             '("/tmp/example.pdf"))))))))

(ert-deftest ow-dired-and-recentf ()
  (ow-fixture
    (let ((calls 0) dired-buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'openwith--launch)
                     (lambda (&rest _) (cl-incf calls) t)))
            (setq dired-buffer (dired-noselect directory))
            (switch-to-buffer dired-buffer)
            (dired-goto-file file)
            (dired-find-file)
            (should (eq dired-buffer (current-buffer)))
            (should (= calls 1))
            (funcall recentf-menu-action file)
            (should (= calls 2))
            (should (member file recentf-list)))
        (when (buffer-live-p dired-buffer) (kill-buffer dired-buffer))))))

(ert-deftest ow-org-plain-link-and-locators ()
  (ow-fixture
    (let ((calls 0) (org-file-apps '((t . emacs))))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (cl-incf calls) t)))
        (org-open-file file)
        (should (= calls 1))
        (org-open-file file t)
        (should (equal buffer-file-name file))
        (org-open-file file nil 2)
        (should (= (line-number-at-pos) 2))
        (should (= calls 1))))))

(ert-deftest ow-ido-final-and-read-only ()
  (ow-fixture
    (let ((ido-mode t) (ido-use-filename-at-point nil)
          (ido-use-url-at-point nil) (calls 0))
      (cl-letf (((symbol-function 'ido-read-internal)
                 (lambda (&rest _) (setq ido-exit 'done)
                   (file-name-nondirectory file)))
                ((symbol-function 'openwith--launch)
                 (lambda (&rest _) (cl-incf calls) t)))
        (ido-file-internal nil)
        (should (= calls 1))
        (should-not (get-file-buffer file))
        (ido-file-internal 'read-only 'find-file-read-only)
        (should (= calls 2))
        (should-not (get-file-buffer file))))))

(ert-deftest ow-ido-preview-and-literal ()
  (ow-fixture
    (let ((openwith--ido-catch 'test-catch))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (ert-fail "Preview launch")))
                ((symbol-function 'minibuffer-depth) (lambda () 1)))
        (should (bufferp (find-file-noselect file))))
      (kill-buffer (get-file-buffer file))
      (should (bufferp (find-file-noselect file nil t))))))

(ert-deftest ow-consult-preview-and-final ()
  (skip-unless (require 'consult nil t))
  (ow-fixture
    (let ((calls 0))
      (cl-letf (((symbol-function 'openwith--launch)
                 (lambda (&rest _) (cl-incf calls) t)))
        (let ((preview (consult--file-preview)))
          (funcall preview 'preview file)
          (should (= calls 0))
          (funcall preview 'return nil))
        (consult--file-action file)
        (should (= calls 1))))))

(defun ow-wait (predicate)
  "Wait at most ten seconds for PREDICATE."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun ow-write-child (path)
  "Write an Emacs Lisp argument recorder to PATH."
  (with-temp-file path
    (insert ";;; -*- lexical-binding: t; -*-\n"
            "(let ((output (pop command-line-args-left))\n"
            "      (delay (string-to-number (pop command-line-args-left))))\n"
            "  (sleep-for delay)\n"
            "  (let ((coding-system-for-write 'utf-8-unix))\n"
            "    (with-temp-file output (prin1 command-line-args-left (current-buffer))))\n"
            "  (setq command-line-args-left nil))\n")))

(ert-deftest ow-native-argument-round-trip ()
  (ow-fixture
    (let* ((child (expand-file-name "child 中文 script.py"))
           (output (expand-file-name "arguments.json"))
           ;; Python uses the Unicode Windows argument API.  Emacs itself
           ;; converts command-line arguments through the ANSI code page.
           (program (or (executable-find "python3") (executable-find "python")
                        (ert-fail "Python 3 is required for native argument tests")))
           (values '("" "with spaces" "中文🙂" "a\"b" "a\\\"b" "C:\\trailing\\"
                     "it's $literal; & harmless" "&;$(literal)" "first\nsecond"))
           (args (append (list child output) values)))
      (with-temp-file child
        (insert "import json, pathlib, sys\n"
                "pathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]), encoding='utf-8')\n"))
      (unless (eq system-type 'windows-nt)
        (let ((link (expand-file-name "viewer with spaces")))
          (make-symbolic-link program link)
          (setq program link)))
      (let ((default-directory ow-root))
       (if (eq system-type 'windows-nt)
          (openwith-open-windows file program args t)
        (let ((process (openwith-open-unix program args)))
          (should-not (process-query-on-exit-flag process))
          (should (ow-wait (lambda () (memq (process-status process) '(exit signal)))))
          (should (= (process-exit-status process) 0)))))
      (should (ow-wait (lambda () (file-exists-p output))))
      (should (equal (with-temp-buffer
                      (let ((coding-system-for-read 'utf-8-unix))
                        (insert-file-contents output))
                      (json-parse-buffer :array-type 'list))
                     values)))))

(ert-deftest ow-unix-failure-stderr-and-log-cleanup ()
  (skip-unless (not (eq system-type 'windows-nt)))
  (ow-fixture
    (let (warning)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (setq warning message))))
        (let* ((process (openwith-open-unix
                         "sh" '("-c" "echo diagnostic >&2; exit 17")))
               (log (process-get process 'openwith-log)))
          (should (ow-wait (lambda () warning)))
          (should (string-match-p "exit 17" warning))
          (should (string-match-p "diagnostic" warning))
          (when log (should-not (file-exists-p log))))))))

(ert-deftest ow-native-child-survives-parent-exit ()
  (ow-fixture
    (let* ((child (expand-file-name "child.el"))
           (parent (expand-file-name "parent.el"))
           (output (expand-file-name "survived.el"))
           (program (expand-file-name invocation-name invocation-directory))
           (log-file (expand-file-name "parent-log.el")))
      (ow-write-child child)
      (with-temp-file parent
        (prin1
         (list 'progn '(require 'openwith)
               (list 'let
                     (list (list 'result
                                 (if (eq system-type 'windows-nt)
                                     (list 'openwith-open-windows output program
                                           (list 'quote
                                                 (list "--batch" "-Q" "--script" child
                                                       output "1" "survived")) t)
                                   (list 'openwith-open-unix program
                                         (list 'quote
                                               (list "--batch" "-Q" "--script" child
                                                     output "1" "survived"))))))
                     (list 'when '(processp result)
                           (list 'with-temp-file log-file
                                 '(prin1 (process-get result 'openwith-log)
                                         (current-buffer))))))
         (current-buffer)))
      (let* ((default-directory ow-root)
             (process (make-process
                       :name "openwith-test-parent" :noquery t
                       :connection-type 'pipe :sentinel #'ignore
                       :command (list program "--batch" "-Q"
                                      "-L" ow-root "-l" parent))))
        (unwind-protect
            (progn
              (should (ow-wait (lambda ()
                                (memq (process-status process) '(exit signal)))))
              (should (= (process-exit-status process) 0)))
          (when (process-live-p process) (delete-process process))))
      (should (ow-wait (lambda () (file-exists-p output))))
      (should (equal (with-temp-buffer (insert-file-contents output)
                                      (read (current-buffer)))
                     '("survived")))
      (when (file-exists-p log-file)
        (let ((log (with-temp-buffer (insert-file-contents log-file)
                                    (read (current-buffer)))))
          (when (and log (file-exists-p log)) (delete-file log)))))))
(provide 'openwith-tests)
