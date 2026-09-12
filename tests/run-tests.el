(setq load-prefer-newer t)
(add-to-list 'load-path
             (file-name-directory
              (directory-file-name (file-name-directory load-file-name))))
(load (expand-file-name "openwith-tests.el"
                        (file-name-directory load-file-name)) nil t)
(ert-run-tests-batch-and-exit)

