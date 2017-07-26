;;; smex.el --- M-x interface with Ido-style fuzzy matching. -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2014 Cornelius Mika and contributors
;;
;; Author: Cornelius Mika <cornelius.mika@gmail.com> and contributors
;; URL: http://github.com/nonsequitur/smex/
;; Package-Requires: ((emacs "24.4") (ido-completing-read+ "4.1") (ivy "0"))
;; Version: 4.0
;; Keywords: convenience, usability

;; This file is not part of GNU Emacs.

;;; License:

;; Licensed under the same terms as Emacs.

;;; Commentary:

;; Quick start:
;; run (smex-initialize)
;;
;; Bind the following commands:
;; smex, smex-major-mode-commands
;;
;; For a detailed introduction see:
;; http://github.com/nonsequitur/smex/blob/master/README.markdown

;;; Code:

(require 'cl-lib)
;; TODO: lazily load the appropriate backend when needed, perhaps
;; falling back to `completing-read-default'
(require 'ido)
(require 'ido-completing-read+)
(require 'ivy)

(defgroup smex nil
  "M-x interface with Ido-style fuzzy matching and ranking heuristics."
  :group 'extensions
  :group 'convenience
  :link '(emacs-library-link :tag "Lisp File" "smex.el"))

;;;###autoload
(define-minor-mode smex-mode
  "Use ido completion for M-x"
  :global t
  :group 'smex
  (if smex-mode
      (progn
        (unless smex-initialized-p
          (smex-initialize))
        (global-set-key [remap execute-extended-command] 'smex))
    (when (eq (global-key-binding [remap execute-extended-command]) 'smex)
      (global-unset-key [remap execute-extended-command]))))

(defcustom smex-backend 'auto
  "Completion function to select a candidate from a list of strings.

This function should take the same arguments as
`smex-completing-read': CHOICES and INITIAL-INPUT.

By default, an appropriate method is selected based on whether
`ivy-mode' or `ido-mode' is enabled."
  :type '(choice
          (const :tag "Auto-select" auto)
          (const :tag "Ido" ido)
          (const :tag "Ivy" ivy)
          (const :tag "Standard" standard)
          (symbol :tag "Custom backend")))
(define-obsolete-variable-alias 'smex-completion-method 'smex-backend "4.0")

(defcustom smex-auto-update t
  "If non-nil, `Smex' checks for new commands each time it is run.
Turn it off for minor speed improvements on older systems."
  :type 'boolean)

(defcustom smex-save-file (locate-user-emacs-file "smex-items" ".smex-items")
  "File in which the smex state is saved between Emacs sessions.
Variables stored are: `smex-data', `smex-history'.
Must be set before initializing Smex."
  :type 'string)

(defcustom smex-history-length 7
  "Determines on how many recently executed commands
Smex should keep a record.
Must be set before initializing Smex."
  :type 'integer)

(defcustom smex-prompt-string "M-x "
  "String to display in the Smex prompt."
  :type 'string)

(define-obsolete-variable-alias 'smex-flex-matching 'ido-enable-flex-matching "4.0")

(defvar smex-initialized-p nil)
(defvar smex-cache)
(defvar smex-ido-cache)
(defvar smex-data)
(defvar smex-history)
(defvar smex-command-count 0)
(defvar smex-custom-action nil)
(defvar smex-minibuffer-depth -1)

;; Check if Smex is supported
(when (equal (cons 1 1)
             (ignore-errors
               (subr-arity (symbol-function 'execute-extended-command))))
  (error "Your Emacs has a non-elisp version of `execute-extended-command', which is incompatible with Smex"))

;;--------------------------------------------------------------------------------
;; Smex Interface

;;;###autoload
(defun smex ()
  (interactive)
  (unless smex-initialized-p
    (smex-initialize))
  (if (smex-active)
      (smex-update-and-rerun)
    (and smex-auto-update (smex-update-if-needed))
    (smex-read-and-run smex-ido-cache)))

(defun smex-active ()
  "Return non-nil if smex is currently using the minibuffer"
  (>= smex-minibuffer-depth (minibuffer-depth)))
(define-obsolete-function-alias 'smex-already-running 'smex-active "4.0")

(defun smex-update-and-rerun ()
  (let ((new-initial-input
         (funcall (smex-backend-get-text-fun (smex-get-backend)))))
    (smex-do-with-selected-item
     (lambda (_) (smex-update) (smex-read-and-run smex-ido-cache new-initial-input)))))

(defun smex-read-and-run (commands &optional initial-input)
  (let* ((chosen-item-name (smex-completing-read commands initial-input))
         (chosen-item (intern chosen-item-name)))
    (if smex-custom-action
        (let ((action smex-custom-action))
          (setq smex-custom-action nil)
          (funcall action chosen-item))
      (unwind-protect
          (with-no-warnings ; Don't warn about interactive use of `execute-extended-command'
            (execute-extended-command current-prefix-arg chosen-item-name))
        (smex-rank chosen-item)))))

;;;###autoload
(defun smex-major-mode-commands ()
  "Like `smex', but limited to commands that are relevant to the active major mode."
  (interactive)
  (unless smex-initialized-p
    (smex-initialize))
  (let ((commands (delete-dups (append (smex-extract-commands-from-keymap (current-local-map))
                                       (smex-extract-commands-from-features major-mode)))))
    (setq commands (smex-sort-according-to-cache commands))
    (setq commands (mapcar #'symbol-name commands))
    (smex-read-and-run commands)))

(defvar smex-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "C-h f") 'smex-describe-function)
    (define-key keymap (kbd "C-h w") 'smex-where-is)
    (define-key keymap (kbd "M-.") 'smex-find-function)
    keymap)
  "Additional key bindings for smex completion.")

(defvar smex-ido-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "C-a") 'move-beginning-of-line)
    (set-keymap-parent keymap smex-map)
    keymap))

(defun smex-prepare-ido-bindings ()
  (setq ido-completion-map
        (make-composed-keymap (list smex-ido-map ido-completion-map))))

(declare-function ivy-read "ext:ivy")
(declare-function ivy-done "ext:ivy")

(defun smex-default-exit-minibuffer ()
  "Run the key binding for RET.

This should work for most completion backends."
  (execute-kbd-macro (kbd "RET")))

(cl-defstruct smex-backend
  name
  comp-fun
  get-text-fun
  exit-fun)

(defvar smex-known-backends nil)

(cl-defun smex-define-backend (name comp-fun get-text-fun &optional
                                    (exit-fun 'smex-default-exit-minibuffer))
  (declare (indent 1)
           (advertised-calling-convention
            (name comp-fun get-text-fun &optional exit-fun) nil))
  (let ((backend
         (make-smex-backend :name name
                            :comp-fun comp-fun
                            :get-text-fun get-text-fun
                            :exit-fun exit-fun)))
    (setq smex-known-backends
          (plist-put smex-known-backends name backend))))

(cl-defun smex-get-backend (&optional (backend smex-backend))
  (cond
   ((smex-backend-p backend)
    backend)
   ((plist-get smex-known-backends backend))
   (t (error "Unknown smex backed %S" backend))))

(defun smex-completing-read-default (choices initial-input)
  "Smex backend for default Emacs completion"
  (let ((minibuffer-completion-table choices))
    (minibuffer-with-setup-hook
        (lambda ()
          (use-local-map (make-composed-keymap (list smex-map (current-local-map)))))
      (completing-read (smex-prompt-with-prefix-arg) choices nil t
                       initial-input 'extended-command-history (car choices)))))

(defun smex-default-get-text ()
  "Default function for getting the user's current text input.

May not work for things like ido and ivy."
  (buffer-substring-no-properties (minibuffer-prompt-end) (point-max)))

(smex-define-backend 'standard
  'smex-completing-read-default
  'smex-default-get-text)

(defun smex-completing-read-ido (choices initial-input)
  "Smex backend for ido completion"
  (let ((ido-completion-map ido-completion-map)
        (ido-setup-hook (cons 'smex-prepare-ido-bindings ido-setup-hook))
        (minibuffer-completion-table choices))
    (ido-completing-read+ (smex-prompt-with-prefix-arg) choices nil t
                          initial-input 'extended-command-history (car choices))))

(defun smex-ido-get-text ()
  ido-text)

(smex-define-backend 'ido
  'smex-completing-read-ido
  'smex-ido-get-text)

(defun smex-completing-read-ivy (choices initial-input)
  "Smex backend for ivy completion"
  (ivy-read (smex-prompt-with-prefix-arg) choices
                :keymap smex-map
                :history 'extended-command-history
                :initial-input initial-input
                :preselect (car choices)))

(defun smex-ivy-get-text ()
  ivy-text)

(smex-define-backend 'ivy
  'smex-completing-read-ivy
  'smex-ivy-get-text)

(defun smex-completing-read-auto (choices initial-input)
  (let ((smex-backend
         (cond
          (ivy-mode 'ivy)
          (ido-mode 'ido)
          (t 'standard))))
    (smex-completing-read choices initial-input)))
(smex-define-backend 'auto
  'smex-completing-read-auto
  (lambda () (error "This exit function should never be called."))
  (lambda () (error "This get-text function should never be called.")))

(defun smex-completing-read (choices initial-input)
  (let ((smex-minibuffer-depth (1+ (minibuffer-depth)))
        (comp-fun (smex-backend-comp-fun (smex-get-backend))))
    (funcall comp-fun choices initial-input)))

(defun smex-prompt-with-prefix-arg ()
  (if (not current-prefix-arg)
      smex-prompt-string
    (concat
     (if (eq current-prefix-arg '-)
         "- "
       (if (integerp current-prefix-arg)
           (format "%d " current-prefix-arg)
         (if (= (car current-prefix-arg) 4)
             "C-u "
           (format "%d " (car current-prefix-arg)))))
     smex-prompt-string)))

;;--------------------------------------------------------------------------------
;; Cache and Maintenance

(defun smex-rebuild-cache ()
  (interactive)
  (setq smex-cache nil)

  ;; Build up list 'new-commands' and later put it at the end of 'smex-cache'.
  ;; This speeds up sorting.
  (let (new-commands)
    (mapatoms (lambda (symbol)
                (when (commandp symbol)
                  (let ((known-command (assq symbol smex-data)))
                    (if known-command
                        (setq smex-cache (cons known-command smex-cache))
                      (setq new-commands (cons (list symbol) new-commands)))))))
    (if (eq (length smex-cache) 0)
        (setq smex-cache new-commands)
      (setcdr (last smex-cache) new-commands)))

  (setq smex-cache (sort smex-cache 'smex-sorting-rules))
  (smex-restore-history)
  (setq smex-ido-cache (smex-convert-for-ido smex-cache)))

(defun smex-convert-for-ido (command-items)
  (mapcar (lambda (command-item) (symbol-name (car command-item))) command-items))

(defun smex-restore-history ()
  "Rearranges `smex-cache' according to `smex-history'"
  (if (> (length smex-history) smex-history-length)
      (setcdr (nthcdr (- smex-history-length 1) smex-history) nil))
  (mapc (lambda (command)
          (unless (eq command (caar smex-cache))
            (let ((command-cell-position (smex-detect-position
                                          smex-cache
                                          (lambda (cell)
                                            (eq command (caar cell))))))
              (when command-cell-position
                (let ((command-cell (smex-remove-nth-cell
                                     command-cell-position smex-cache)))
                  (setcdr command-cell smex-cache)
                  (setq smex-cache command-cell))))))
        (reverse smex-history)))

(defun smex-sort-according-to-cache (list)
  "Sorts a list of commands by their order in `smex-cache'"
  (let (sorted)
    (dolist (command-item smex-cache)
      (let ((command (car command-item)))
        (when (memq command list)
          (setq sorted (cons command sorted))
          (setq list (delq command list)))))
    (nreverse (append list sorted))))

(defun smex-update ()
  (interactive)
  (smex-save-history)
  (smex-rebuild-cache))

(defun smex-detect-new-commands ()
  (let ((i 0))
    (mapatoms (lambda (symbol) (if (commandp symbol) (setq i (1+ i)))))
    (unless (= i smex-command-count)
      (setq smex-command-count i))))

(defun smex-update-if-needed ()
  (if (smex-detect-new-commands) (smex-update)))

(defun smex-auto-update (&optional idle-time)
  "Update Smex when Emacs has been idle for IDLE-TIME."
  (unless idle-time (setq idle-time 60))
  (run-with-idle-timer idle-time t 'smex-update-if-needed))

;;;###autoload
(defun smex-initialize ()
  (interactive)
  (ido-common-initialization)
  (smex-load-save-file)
  (smex-detect-new-commands)
  (smex-rebuild-cache)
  (add-hook 'kill-emacs-hook 'smex-save-to-file)
  (setq smex-initialized-p t))

(define-obsolete-function-alias
  'smex-initialize-ido 'ido-common-initialization
  "4.0")

(define-obsolete-function-alias
  'smex-save-file-not-empty-p 'smex-buffer-not-empty-p "4.0")
(defsubst smex-buffer-not-empty-p ()
  (string-match-p "\[^[:space:]\]" (buffer-string)))

(defun smex-load-save-file ()
  "Loads `smex-history' and `smex-data' from `smex-save-file'"
  (let ((save-file (expand-file-name smex-save-file)))
    (if (file-readable-p save-file)
        (with-temp-buffer
          (insert-file-contents save-file)
          (condition-case nil
              (setq smex-history (read (current-buffer))
                    smex-data    (read (current-buffer)))
            (error (if (smex-buffer-not-empty-p)
                       (error "Invalid data in smex-save-file (%s). Can't restore history."
                              smex-save-file)
                     (unless (boundp 'smex-history) (setq smex-history nil))
                     (unless (boundp 'smex-data)    (setq smex-data nil))))))
      (setq smex-history nil smex-data nil))))

(defun smex-save-history ()
  "Updates `smex-history'"
  (setq smex-history
        (cl-loop
         for i from 1 upto smex-history-length
         for (command-name . count) in smex-cache
         collect command-name)))

(defmacro smex-pp (list-var)
  `(smex-pp* ,list-var ,(symbol-name list-var)))

(defun smex-save-to-file ()
  (interactive)
  (smex-save-history)
  (with-temp-file (expand-file-name smex-save-file)
    (smex-pp smex-history)
    (smex-pp smex-data)))

;;--------------------------------------------------------------------------------
;; Ranking

(defun smex-sorting-rules (command-item other-command-item)
  "Returns true if COMMAND-ITEM should sort before OTHER-COMMAND-ITEM."
  (let* ((count        (or (cdr command-item      ) 0))
         (other-count  (or (cdr other-command-item) 0))
         (name         (car command-item))
         (other-name   (car other-command-item))
         (length       (length (symbol-name name)))
         (other-length (length (symbol-name other-name))))
    (or (> count other-count)                         ; 1. Frequency of use
        (and (= count other-count)
             (or (< length other-length)              ; 2. Command length
                 (and (= length other-length)
                      (string< name other-name))))))) ; 3. Alphabetical order

(defun smex-rank (command)
  (let ((command-item (or (assq command smex-cache)
                          ;; Update caches and try again if not found.
                          (progn (smex-update)
                                 (assq command smex-cache)))))
    (when command-item
      (smex-update-counter command-item)

      ;; Don't touch the cache order if the chosen command
      ;; has just been execucted previously.
      (unless (eq command-item (car smex-cache))
        (let (command-cell
              (pos (smex-detect-position smex-cache (lambda (cell)
                                                      (eq command-item (car cell))))))
          ;; Remove the just executed command.
          (setq command-cell (smex-remove-nth-cell pos smex-cache))
          ;; And put it on top of the cache.
          (setcdr command-cell smex-cache)
          (setq smex-cache command-cell)

          ;; Repeat the same for the ido cache. Should this be DRYed?
          (setq command-cell (smex-remove-nth-cell pos smex-ido-cache))
          (setcdr command-cell smex-ido-cache)
          (setq smex-ido-cache command-cell)

          ;; Now put the last history item back to its normal place.
          (smex-sort-item-at smex-history-length))))))

(defun smex-update-counter (command-item)
  (let ((count (cdr command-item)))
    (setcdr command-item
            (if count
                (1+ count)
              ;; Else: Command has just been executed for the first time.
              ;; Add it to `smex-data'.
              (if smex-data
                  (setcdr (last smex-data) (list command-item))
                (setq smex-data (list command-item)))
              1))))

(defun smex-sort-item-at (n)
  "Sorts item at position N in `smex-cache'."
  (let* ((command-cell (nthcdr n smex-cache))
         (command-item (car command-cell)))
    (let ((insert-at (smex-detect-position
                      command-cell
                      (lambda (cell)
                        (smex-sorting-rules command-item (car cell))))))
      ;; TODO: Should we handle the case of 'insert-at' being nil?
      ;; This will never happen in practice.
      (when (> insert-at 1)
        (setq command-cell (smex-remove-nth-cell n smex-cache))
        ;; smex-cache just got shorter by one element, so subtract '1' from insert-at.
        (setq insert-at (+ n (- insert-at 1)))
        (smex-insert-cell command-cell insert-at smex-cache)

        ;; Repeat the same for the ido cache. DRY?
        (setq command-cell (smex-remove-nth-cell n smex-ido-cache))
        (smex-insert-cell command-cell insert-at smex-ido-cache)))))

(defun smex-detect-position (cell function)
  "Detects, relatively to CELL, the position of the cell
on which FUNCTION returns true.
Only checks cells after CELL, starting with the cell right after CELL.
Returns nil when reaching the end of the list."
  (let ((pos 1))
    (catch 'break
      (while t
        (setq cell (cdr cell))
        (if (not cell)
            (throw 'break nil)
          (if (funcall function cell) (throw 'break pos))
          (setq pos (1+ pos)))))))

(defun smex-remove-nth-cell (n list)
  "Removes and returns the Nth cell in LIST."
  (let* ((previous-cell (nthcdr (- n 1) list))
         (result (cdr previous-cell)))
    (setcdr previous-cell (cdr result))
    result))

(defun smex-insert-cell (new-cell n list)
  "Inserts cell at position N in LIST."
  (let* ((cell (nthcdr (- n 1) list))
         (next-cell (cdr cell)))
    (setcdr (setcdr cell new-cell) next-cell)))

;;--------------------------------------------------------------------------------
;; Help and Reference

(defun smex-exit-minibuffer ()
  "Call the backend-specific minibuffer exit function."
  (interactive)
  (funcall (smex-backend-exit-fun (smex-get-backend))))

(defun smex-do-with-selected-item (fn)
  "Exit minibuffer and call FN on the selected item."
  (setq smex-custom-action fn)
  (smex-exit-minibuffer))

(defun smex-describe-function ()
  (interactive)
  (smex-do-with-selected-item (lambda (chosen)
                                (describe-function chosen)
                                (pop-to-buffer "*Help*"))))

(defun smex-where-is ()
  (interactive)
  (smex-do-with-selected-item 'where-is))

(defun smex-find-function ()
  (interactive)
  (smex-do-with-selected-item 'find-function))

(defun smex-extract-commands-from-keymap (keymap)
  (let (commands)
    (smex-parse-keymap keymap commands)
    commands))

(defun smex-parse-keymap (keymap commands)
  (map-keymap (lambda (_binding element)
                (if (and (listp element) (eq 'keymap (car element)))
                    (smex-parse-keymap element commands)
                  ;; Strings are commands, too. Reject them.
                  (if (and (symbolp element) (commandp element))
                      (push element commands))))
              keymap))

(defun smex-extract-commands-from-features (mode)
  (let ((library-path (symbol-file mode))
        (mode-name (symbol-name mode))
        commands)

    (string-match "\\(.+?\\)\\(-mode\\)?$" mode-name)
    ;; 'lisp-mode' -> 'lisp'
    (setq mode-name (match-string 1 mode-name))
    (if (string= mode-name "c") (setq mode-name "cc"))
    (setq mode-name (regexp-quote mode-name))

    (dolist (feature load-history)
      (let ((feature-path (car feature)))
        (when (and feature-path (or (equal feature-path library-path)
                                    (string-match mode-name (file-name-nondirectory
                                                             feature-path))))
          (dolist (item (cdr feature))
            (if (and (listp item) (eq 'defun (car item)))
                (let ((function (cdr item)))
                  (when (commandp function)
                    (setq commands (append commands (list function))))))))))
    commands))

(defun smex-show-unbound-commands ()
  "Shows unbound commands in a new buffer,
sorted by frequency of use."
  (interactive)
  (setq smex-data (sort smex-data 'smex-sorting-rules))
  (let ((unbound-commands (delq nil
                                (mapcar (lambda (command-item)
                                          (unless (where-is-internal (car command-item))
                                            command-item))
                                        smex-data))))
    (view-buffer-other-window "*Smex: Unbound Commands*")
    (setq buffer-read-only t)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (smex-pp unbound-commands))
    (set-buffer-modified-p nil)
    (goto-char (point-min))))

(defmacro smex-auto-update-after (&rest functions)
  "Advise each of FUNCTIONS to execute smex-update upon completion."
  (cons
   'progn
   (mapcar (lambda (fun)
             `(defadvice ,fun (after smex-update activate)
                "Run smex-update upon completion"
                (ignore-errors
                  (when (and smex-initialized-p smex-auto-update)
                    (smex-update-if-needed)))))
           ;; Defining advice on `eval' causes infinite recursion, so
           ;; don't allow that.
           (cl-delete-if (apply-partially 'equal 'eval)
                         functions))))

;; If you call `smex-update' after every invocation of just these few
;; functions, you almost never need any other updates.
(smex-auto-update-after load eval-last-sexp eval-buffer eval-region eval-expression)

;; A copy of `ido-pp' that's compatible with lexical bindings
(defun smex-pp* (list list-name)
  (let ((print-level nil) (eval-expression-print-level nil)
        (print-length nil) (eval-expression-print-length nil))
    (insert "\n;; ----- " list-name " -----\n(\n ")
    (while list
      (let* ((elt (car list))
             (s (if (consp elt) (car elt) elt)))
        (if (and (stringp s) (= (length s) 0))
            (setq s nil))
        (if s
            (prin1 elt (current-buffer)))
        (if (and (setq list (cdr list)) s)
            (insert "\n "))))
    (insert "\n)\n")))

(provide 'smex)
;;; smex.el ends here
