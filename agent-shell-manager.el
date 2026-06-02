;;; agent-shell-manager.el --- Buffer manager for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Jethro Kuan

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:
;;
;; Provides a buffer manager with tabulated list view of all open agent-shell buffers,
;; showing buffer name, session status, and other details.
;;
;; Features:
;; - View all agent-shell buffers in a tabulated list
;; - See real-time status (ready, working, waiting, initializing, killed)
;; - Kill, restart, or create new agent-shells
;; - Manage session modes
;; - View traffic logs for debugging
;; - Auto-refresh every 2 seconds
;; - Killed processes are displayed at the bottom in red
;;
;; Usage:
;;   M-x agent-shell-manager-toggle
;;
;; Key bindings in the manager buffer:
;;   RET   - Switch to agent-shell buffer
;;   g     - Refresh buffer list
;;   k     - Kill agent-shell process
;;   c     - Create new agent-shell
;;   r     - Restart agent-shell
;;   d     - Delete all killed buffers
;;   m     - Set session mode
;;   M     - Set session model
;;   C-c C-c - Interrupt agent
;;   t     - View traffic logs
;;   l     - Toggle logging
;;   q     - Quit manager window

;;; Code:

(require 'agent-shell)
(require 'tabulated-list)

(declare-function agent-shell-get-model-name "agent-shell" (state))
(declare-function agent-shell-get-mode-name "agent-shell" (state))

(defgroup agent-shell-manager nil
  "Buffer manager for `agent-shell'."
  :group 'agent-shell)

(defcustom agent-shell-manager-side 'bottom
  "Side of the frame to display the `agent-shell' manager.
Can be 'left, 'right, 'top, 'bottom, or nil.  When nil, buffer display
is controlled by the user's `display-buffer-alist'."
  :type '(choice (const :tag "Left" left)
          (const :tag "Right" right)
          (const :tag "Top" top)
          (const :tag "Bottom" bottom)
          (const :tag "User-controlled" nil))
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-transient nil
  "When non-nil, automatically hide the manager window after actions.
This includes switching to a shell buffer with RET.  When enabled,
the manager window can also be closed by `delete-other-windows' (C-x 1)."
  :type 'boolean
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-layout 'table
  "Layout style for the manager buffer.
`table' uses the original horizontal tabulated-list view.
`vertical' shows each agent as a multi-line block, suitable for
narrow side windows where the full table would be truncated."
  :type '(choice (const :tag "Horizontal table" table)
                 (const :tag "Vertical blocks" vertical))
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-vertical-fields
  '((buffer . "Buffer")
    (status . "Status")
    (mode   . "Mode")
    (model  . "Model")
    (perms  . "Perms")
    (path   . "Path"))
  "Fields to display in vertical layout, in order.
Each entry is (FIELD-KEY . LABEL).  Valid FIELD-KEYs are those
handled by `agent-shell-manager--field-value'."
  :type '(alist :key-type symbol :value-type string)
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-vertical-separator ""
  "Separator line inserted between agent blocks in vertical layout.
A blank line is always inserted between blocks; this string, when
non-empty, is inserted on its own line before that blank line (e.g.
set to (make-string 40 ?─) to draw a horizontal rule)."
  :type 'string
  :group 'agent-shell-manager)

(defun agent-shell-manager--apply-keybindings (map)
  "Apply the shared agent-shell-manager keybindings to MAP."
  (define-key map (kbd "RET") #'agent-shell-manager-goto)
  (define-key map (kbd "g")   #'agent-shell-manager-refresh)
  (define-key map (kbd "q")   #'quit-window)
  (define-key map (kbd "k")   #'agent-shell-manager-kill)
  (define-key map (kbd "c")   #'agent-shell-manager-new)
  (define-key map (kbd "r")   #'agent-shell-manager-restart)
  (define-key map (kbd "d")   #'agent-shell-manager-delete-killed)
  (define-key map (kbd "m")   #'agent-shell-manager-set-mode)
  (define-key map (kbd "M")   #'agent-shell-manager-set-model)
  (define-key map (kbd "C-c C-c") #'agent-shell-manager-interrupt)
  (define-key map (kbd "t")   #'agent-shell-manager-view-traffic)
  (define-key map (kbd "l")   #'agent-shell-manager-toggle-logging))

(defvar agent-shell-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (agent-shell-manager--apply-keybindings map)
    (define-key map (kbd "TAB")       #'agent-shell-manager-next-agent)
    (define-key map (kbd "<backtab>") #'agent-shell-manager-previous-agent)
    map)
  "Keymap for `agent-shell-manager-mode'.")

(defvar-local agent-shell-manager--refresh-timer nil
  "Timer for auto-refreshing the buffer list.")

(defvar agent-shell-manager--global-buffer nil
  "The global manager buffer for `agent-shell' buffer list.")

(define-derived-mode agent-shell-manager-mode tabulated-list-mode "Agent-Shell-Buffers"
  "Major mode for listing `agent-shell' buffers.

Key bindings:
\\[agent-shell-manager-goto] - Switch to `agent-shell' buffer at point
\\[agent-shell-manager-refresh] - Refresh the buffer list
\\[agent-shell-manager-kill] - Kill the `agent-shell' process at point
\\[agent-shell-manager-new] - Create a new `agent-shell'
\\[agent-shell-manager-restart] - Restart the `agent-shell' at point
\\[agent-shell-manager-delete-killed] - Delete all killed `agent-shell' buffers
\\[agent-shell-manager-set-mode] - Set session mode for agent at point
\\[agent-shell-manager-set-model] - Set session model for agent at point
\\[agent-shell-manager-interrupt] - Interrupt the agent at point
\\[agent-shell-manager-view-traffic] - View traffic logs for agent at point
\\[agent-shell-manager-toggle-logging] - Toggle ACP logging
\\[agent-shell-manager-next-agent] - Move to next agent (vertical layout)
\\[agent-shell-manager-previous-agent] - Move to previous agent (vertical layout)
\\[quit-window] - Quit the manager window

\\{agent-shell-manager-mode-map}"
  (setq tabulated-list-format
        [("Buffer" 40 t)
         ("Status" 15 t)
         ("Mode" 15 t)
         ("Model" 21 t)
         ("Pending Permissions" 20 t)
         ("Path" 20 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Buffer" nil))
  (tabulated-list-init-header)
  (agent-shell-manager--setup-refresh-timer))

(defun agent-shell-manager--setup-refresh-timer ()
  "(Re)start the auto-refresh timer for the current manager buffer."
  (when agent-shell-manager--refresh-timer
    (cancel-timer agent-shell-manager--refresh-timer))
  ;; Set up auto-refresh timer (refresh every 2 seconds)
  (setq agent-shell-manager--refresh-timer
        (run-with-timer 2 2 #'agent-shell-manager-refresh))
  ;; Cancel timer when buffer is killed
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when agent-shell-manager--refresh-timer
                (cancel-timer agent-shell-manager--refresh-timer)
                (setq agent-shell-manager--refresh-timer nil)))
            nil t))

(defun agent-shell-manager--buffer-at-point ()
  "Return the agent-shell buffer for the entry at point, or nil.
Dispatches on `agent-shell-manager-layout'."
  (pcase agent-shell-manager-layout
    ('table    (tabulated-list-get-id))
    ('vertical (get-text-property (point) 'agent-shell-manager-buffer))
    (_         (tabulated-list-get-id))))

(defun agent-shell-manager--get-status (buffer)
  "Get the current status of `agent-shell' BUFFER.
Returns one of: waiting, ready, working, killed, or unknown."
  (with-current-buffer buffer
    (if (not (boundp 'agent-shell--state))
        "unknown"
      (let* ((state agent-shell--state)
             (acp-proc (map-nested-elt state '(:client :process)))
             (acp-process-alive (and acp-proc
                                     (processp acp-proc)
                                     (process-live-p acp-proc)
                                     ;; Additional check: process status should not be 'exit or 'signal
                                     (memq (process-status acp-proc) '(run open listen connect stop))))
             ;; Check the comint process (the actual shell process)
             (comint-proc (get-buffer-process (current-buffer)))
             (comint-process-alive (and comint-proc
                                        (processp comint-proc)
                                        (process-live-p comint-proc)
                                        (memq (process-status comint-proc) '(run open listen connect stop))))
             ;; Both processes must be alive for the shell to be truly alive
             (process-alive (and acp-process-alive comint-process-alive))
             (has-active-requests (map-elt state :active-requests))
             (has-pending-permission
              (seq-find (lambda (tool-call)
                          (and (map-elt (cdr tool-call) :permission-request-id)
                               (equal (map-elt (cdr tool-call) :status) "pending")))
                        (map-elt state :tool-calls))))
        (cond
         ;; Check if comint process is dead or missing - if so, always report killed
         ((or (not comint-proc)
              (and (processp comint-proc)
                   (not comint-process-alive)))
          "killed")
         ;; Check if ACP client process is dead or missing (when client exists)
         ((and (map-elt state :client)
               (or (not acp-proc)
                   (and (processp acp-proc)
                        (not acp-process-alive))))
          "killed")
         ;; Check if any tool call is waiting for permission.
         ((and process-alive has-pending-permission)
          "waiting")
         ;; Check if an ACP request is currently in flight.
         ((and process-alive has-active-requests)
          "working")
         ;; During initialization/restoration, a busy shell without an active
         ;; session is still working.  Once a session exists, active requests
         ;; are more reliable than stale shell/tool-call state.
         ((and process-alive
               (fboundp 'shell-maker-busy)
               (shell-maker-busy)
               (not (map-nested-elt state '(:session :id))))
          "working")
         ;; Check if session is active (only if process is alive)
         ((and process-alive
               (map-nested-elt state '(:session :id)))
          "ready")
         ;; Still initializing
         ((not (map-elt state :initialized))
          "initializing")
         (t "unknown"))))))

(defun agent-shell-manager--get-buffer-name (buffer)
  "Get the buffer name for BUFFER."
  (buffer-name buffer))

(defun agent-shell-manager--get-compact-buffer-name (buffer)
  "Get a compact buffer name for BUFFER, optimized for narrow windows."
  (let ((name (agent-shell-manager--get-buffer-name buffer)))
    (if (string-match "^\\(.*?\\) Agent @ \\(.*\\)$" name)
        (let ((agent (match-string 1 name))
              (target (match-string 2 name)))
          (cond
           ((string-empty-p target) agent)
           ((string-empty-p agent) target)
           (t (format "%s (%s)" target agent))))
      name)))

(defun agent-shell-manager--get-session-status (buffer)
  "Get session status for BUFFER."
  (with-current-buffer buffer
    (let ((status (agent-shell-manager--get-status buffer)))
      (if (string= status "killed")
          "none"
        (if (and (boundp 'agent-shell--state)
                 (map-nested-elt agent-shell--state '(:session :id)))
            "active"
          "none")))))

(defun agent-shell-manager--get-combined-status (buffer)
  "Get combined status for BUFFER that merges operational and session state.
Returns a user-friendly status string with appropriate face."
  (with-current-buffer buffer
    (let ((status (agent-shell-manager--get-status buffer))
          (session (agent-shell-manager--get-session-status buffer)))
      (cond
       ;; Killed - highest priority
       ((string= status "killed")
        (propertize "Killed" 'face 'error))
       ;; Initializing without session
       ((and (string= status "initializing")
             (string= session "none"))
        (propertize "Starting..." 'face 'font-lock-comment-face))
       ;; Ready but no session (edge case)
       ((and (string= status "ready")
             (string= session "none"))
        (propertize "No Session" 'face 'font-lock-comment-face))
       ;; Ready with active session
       ((and (string= status "ready")
             (string= session "active"))
        (propertize "Ready" 'face 'success))
       ;; Working
       ((string= status "working")
        (propertize "Working" 'face 'warning))
       ;; Waiting for user input/permission
       ((string= status "waiting")
        (propertize "Waiting" 'face 'font-lock-keyword-face))
       ;; Unknown/fallback
       (t
        (propertize "Unknown" 'face 'font-lock-comment-face))))))

(defun agent-shell-manager--get-session-mode (buffer)
  "Get the current session mode for BUFFER."
  (with-current-buffer buffer
    (if (boundp 'agent-shell--state)
        (or (and (fboundp 'agent-shell-get-mode-name)
                 (agent-shell-get-mode-name agent-shell--state))
            (and (map-nested-elt agent-shell--state '(:session :mode-id))
                 (or (agent-shell--resolve-session-mode-name
                      (map-nested-elt agent-shell--state '(:session :mode-id))
                      (map-nested-elt agent-shell--state '(:session :modes)))
                     (map-nested-elt agent-shell--state '(:session :mode-id))))
            "-")
      "-")))

(defun agent-shell-manager--get-agent-kind (buffer)
  "Get the agent kind for BUFFER by parsing the buffer name."
  (with-current-buffer buffer
    (let ((buffer-name (buffer-name)))
      ;; Buffer names are in the format: "Agent Name Agent @ /path/to/dir"
      ;; Extract the agent name before " Agent @ "
      (if (string-match "^\\(.*?\\) Agent @ " buffer-name)
          (match-string 1 buffer-name)
        "-"))))

(defun agent-shell-manager--get-model-id (buffer)
  "Get the current model ID for BUFFER."
  (with-current-buffer buffer
    (if (boundp 'agent-shell--state)
        (or (and (fboundp 'agent-shell-get-model-name)
                 (agent-shell-get-model-name agent-shell--state))
            (when-let* ((model-id (map-nested-elt agent-shell--state '(:session :model-id))))
              (let* ((models (map-nested-elt agent-shell--state '(:session :models)))
                     (model-info (seq-find (lambda (model)
                                             (string= (map-elt model :model-id) model-id))
                                           models)))
                (or (and model-info (map-elt model-info :name))
                    model-id)))
            "-")
      "-")))

(defun agent-shell-manager--count-pending-permissions (buffer)
  "Count the number of pending permission requests for BUFFER.
Returns a propertized string with yellow/warning face for non-zero counts."
  (with-current-buffer buffer
    (if (and (boundp 'agent-shell--state)
             (map-elt agent-shell--state :tool-calls))
        (let ((count 0))
          (map-do
           (lambda (_tool-call-id tool-call-data)
             (when (and (map-elt tool-call-data :permission-request-id)
                        (let ((status (map-elt tool-call-data :status)))
                          (equal status "pending")))
               (setq count (1+ count))))
           (map-elt agent-shell--state :tool-calls))
          (if (> count 0)
              (propertize (number-to-string count)
                          'face 'warning
                          'font-lock-face 'warning)
            "-"))
      "-")))

(defun agent-shell-manager--status-face (status)
  "Return face for STATUS string."
  (cond
   ((string= status "ready") 'success)
   ((string= status "working") 'warning)
   ((string= status "waiting") 'font-lock-keyword-face)
   ((string= status "initializing") 'font-lock-comment-face)
   ((string= status "killed") 'error)
   (t 'default)))

(defun agent-shell-manager--get-cwd (buffer)
  "Get the current session directory for BUFFER."
  (with-current-buffer buffer
    default-directory))

(defun agent-shell-manager--field-value (field buffer)
  "Return the string value of FIELD for BUFFER.
FIELD is a symbol: `buffer', `status', `mode', `model', `perms' or `path'."
  (pcase field
    ('buffer (agent-shell-manager--get-buffer-name buffer))
    ('status (agent-shell-manager--get-combined-status buffer))
    ('mode   (agent-shell-manager--get-session-mode buffer))
    ('model  (agent-shell-manager--get-model-id buffer))
    ('perms  (agent-shell-manager--count-pending-permissions buffer))
    ('path   (abbreviate-file-name (agent-shell-manager--get-cwd buffer)))
    (_ "")))

(defun agent-shell-manager--sorted-buffers ()
  "Return live agent-shell buffers, with killed ones pushed to the bottom."
  (let* ((buffers (agent-shell-buffers))
         (buffers (if (listp buffers) buffers (list buffers)))
         (buffers (seq-filter #'buffer-live-p buffers)))
    (sort (copy-sequence buffers)
          (lambda (a b)
            (let ((status-a (agent-shell-manager--get-status a))
                  (status-b (agent-shell-manager--get-status b)))
              (cond
               ;; Both killed or both not killed - maintain original order (stable)
               ((and (string= status-a "killed") (string= status-b "killed")) nil)
               ((and (not (string= status-a "killed")) (not (string= status-b "killed"))) nil)
               ;; a is killed, b is not - a goes after b
               ((string= status-a "killed") nil)
               ;; b is killed, a is not - a goes before b
               (t t)))))))

(defun agent-shell-manager--entries ()
  "Return list of entries for tabulated-list."
  (mapcar
   (lambda (buffer)
     (list buffer
           (vector
            (agent-shell-manager--field-value 'buffer buffer)
            (agent-shell-manager--field-value 'status buffer)
            (agent-shell-manager--field-value 'mode   buffer)
            (agent-shell-manager--field-value 'model  buffer)
            (agent-shell-manager--field-value 'perms  buffer)
            (agent-shell-manager--field-value 'path   buffer))))
   (agent-shell-manager--sorted-buffers)))

(defun agent-shell-manager--render-vertical ()
  "Render agent-shell buffer list in vertical block layout."
  (let* ((inhibit-read-only t)
         (saved-buffer (agent-shell-manager--buffer-at-point))
         (fields agent-shell-manager-vertical-fields)
         (label-width (if fields
                          (apply #'max (mapcar (lambda (f) (length (cdr f)))
                                               fields))
                        0)))
    (erase-buffer)
    (let ((buffers (agent-shell-manager--sorted-buffers)))
      (if (null buffers)
          (insert (propertize "No agent-shell buffers.\n"
                              'face 'font-lock-comment-face))
        (dolist (buffer buffers)
          (let ((block-start (point)))
            (dolist (field fields)
              (let* ((key   (car field))
                     (label-text (concat (cdr field) ":"))
                     (label (propertize label-text
                                        'face 'font-lock-keyword-face))
                     (pad (make-string
                           (max 1 (- (+ label-width 2) (length label-text)))
                           ?\s))
                     (value (if (eq key 'buffer)
                                (agent-shell-manager--get-compact-buffer-name buffer)
                              (agent-shell-manager--field-value key buffer))))
                (insert label pad value "\n")))
            (add-text-properties block-start (point)
                                 `(agent-shell-manager-buffer ,buffer))
            (unless (string-empty-p agent-shell-manager-vertical-separator)
              (insert agent-shell-manager-vertical-separator "\n"))
            ;; Blank line between blocks
            (insert "\n")))))
    ;; Restore cursor on the same agent block when possible
    (goto-char (point-min))
    (when saved-buffer
      (let (found)
        (while (and (not found) (not (eobp)))
          (if (eq (get-text-property (point) 'agent-shell-manager-buffer)
                  saved-buffer)
              (setq found t)
            (forward-line 1)))
        (unless found (goto-char (point-min)))))))

(defun agent-shell-manager-next-agent ()
  "Move point to the start of the next agent block (vertical layout)."
  (interactive)
  (let* ((start (point))
         (here  (get-text-property (point) 'agent-shell-manager-buffer))
         (pos   (point)))
    ;; 1. If we are inside a block, first jump to just past this block.
    (when here
      (setq pos (or (next-single-property-change
                     pos 'agent-shell-manager-buffer)
                    (point-max)))
      (goto-char pos))
    ;; 2. Skip over the separator (region with nil property) to the next block.
    (while (and (< (point) (point-max))
                (null (get-text-property (point) 'agent-shell-manager-buffer)))
      (forward-line 1))
    (when (eobp)
      (goto-char start))))

(defun agent-shell-manager-previous-agent ()
  "Move point to the start of the previous agent block (vertical layout)."
  (interactive)
  (let* ((start (point))
         (here  (get-text-property (point) 'agent-shell-manager-buffer)))
    ;; If at the very top of a block, step back one char so that
    ;; `previous-single-property-change' leaves this block.
    (when (and here
               (> (point) (point-min))
               (not (eq (get-text-property (1- (point))
                                           'agent-shell-manager-buffer)
                        here)))
      (backward-char 1))
    ;; Walk back until we find a block.
    (while (and (> (point) (point-min))
                (null (get-text-property (point) 'agent-shell-manager-buffer)))
      (backward-char 1))
    (when (get-text-property (point) 'agent-shell-manager-buffer)
      ;; Now jump to the beginning of this block.
      (let ((top (previous-single-property-change
                  (1+ (point)) 'agent-shell-manager-buffer)))
        (goto-char (or top (point-min)))))
    (beginning-of-line)
    ;; If we didn't actually move, restore original point.
    (when (= (point) start)
      (goto-char start))))

(defun agent-shell-manager-refresh ()
  "Refresh the buffer list."
  (interactive)
  (when (and agent-shell-manager--global-buffer
             (buffer-live-p agent-shell-manager--global-buffer))
    (with-current-buffer agent-shell-manager--global-buffer
      (pcase agent-shell-manager-layout
        ('vertical
         (agent-shell-manager--render-vertical))
        (_
         (setq tabulated-list-entries (agent-shell-manager--entries))
         (tabulated-list-print t))))))

(defun agent-shell-manager--hide-window ()
  "Hide the manager window if `agent-shell-manager-transient' is non-nil."
  (when agent-shell-manager-transient
    (when-let* ((buffer agent-shell-manager--global-buffer)
                (window (and (buffer-live-p buffer)
                             (get-buffer-window buffer))))
      (delete-window window))))

(defun agent-shell-manager-goto ()
  "Go to the `agent-shell' buffer at point.
If `agent-shell-manager-transient' is non-nil, hide the manager window.
If the buffer is already visible, switch to it.
Otherwise, if another `agent-shell' window is open, reuse it."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (if (buffer-live-p buffer)
        (let ((buffer-window (get-buffer-window buffer t))
              (agent-shell-window nil))
          (cond
           ;; If the buffer is already visible, just switch to it
           (buffer-window
            (select-window buffer-window))

           ;; Otherwise, find an existing agent-shell window to reuse
           (t
            (walk-windows
             (lambda (win)
               (when (and (not agent-shell-window)
                          (not (eq win (selected-window)))
                          (with-current-buffer (window-buffer win)
                            (derived-mode-p 'agent-shell-mode)))
                 (setq agent-shell-window win)))
             nil t)

            (if agent-shell-window
                ;; Reuse the existing agent-shell window
                (progn
                  (set-window-buffer agent-shell-window buffer)
                  (select-window agent-shell-window))
              ;; No existing agent-shell window, use default behavior
              (agent-shell--display-buffer buffer))))
          (agent-shell-manager--hide-window))
      (user-error "Buffer no longer exists"))))

(defun agent-shell-manager-kill ()
  "Kill the `agent-shell' process at point."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (when (yes-or-no-p (format "Kill agent-shell process in %s? " (buffer-name buffer)))
      (with-current-buffer buffer
        (when (and (boundp 'agent-shell--state)
                   (map-elt agent-shell--state :client)
                   (map-nested-elt agent-shell--state '(:client :process)))
          (let ((proc (map-nested-elt agent-shell--state '(:client :process))))
            (when (process-live-p proc)
              (comint-send-eof)
              (message "Sent EOF to agent-shell process in %s" (buffer-name buffer))))))
      ;; Give the process a moment to update its status before refreshing
      (run-with-timer 0.1 nil #'agent-shell-manager-refresh))))

(defun agent-shell-manager-new ()
  "Create a new `agent-shell'."
  (interactive)
  (agent-shell t)
  (if agent-shell-manager-transient
      (agent-shell-manager--hide-window)
    (agent-shell-manager-refresh)))

(defun agent-shell-manager--get-buffer-config (buffer)
  "Try to determine the config used for BUFFER.
Returns nil if config cannot be determined."
  (with-current-buffer buffer
    ;; Try to match buffer name against known configs
    (when (derived-mode-p 'agent-shell-mode)
      (let ((buffer-name-prefix (replace-regexp-in-string " Agent @ .*$" "" (buffer-name))))
        (seq-find (lambda (config)
                    (string= buffer-name-prefix (map-elt config :buffer-name)))
                  agent-shell-agent-configs)))))

(defun agent-shell-manager-restart ()
  "Restart the `agent-shell' at point.
Kills the current process and starts a new one with the same config if possible."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (let ((config (agent-shell-manager--get-buffer-config buffer))
          (buffer-name (buffer-name buffer)))
      (when (yes-or-no-p (format "Restart agent-shell %s? " buffer-name))
        ;; Kill the current process
        (with-current-buffer buffer
          (when (and (boundp 'agent-shell--state)
                     (map-elt agent-shell--state :client)
                     (map-nested-elt agent-shell--state '(:client :process)))
            (let ((proc (map-nested-elt agent-shell--state '(:client :process))))
              (when (process-live-p proc)
                (kill-process proc)))))
        ;; Kill the buffer
        (kill-buffer buffer)
        ;; Start a new one
        (if config
            (agent-shell-start :config config)
          (agent-shell t))
        (agent-shell-manager-refresh)
        (message "Restarted %s" buffer-name)))))

(defun agent-shell-manager-delete-killed ()
  "Delete all killed `agent-shell' buffers from the list."
  (interactive)
  (let ((killed-buffers (seq-filter
                         (lambda (buffer)
                           (and (buffer-live-p buffer)
                                (string= (agent-shell-manager--get-status buffer) "killed")))
                         (mapcar #'get-buffer (agent-shell-buffers)))))
    (if (null killed-buffers)
        (message "No killed buffers to delete")
      (when (yes-or-no-p (format "Delete %d killed buffer%s? "
                                 (length killed-buffers)
                                 (if (= (length killed-buffers) 1) "" "s")))
        (dolist (buffer killed-buffers)
          (kill-buffer buffer))
        (agent-shell-manager-refresh)
        (message "Deleted %d killed buffer%s"
                 (length killed-buffers)
                 (if (= (length killed-buffers) 1) "" "s"))))))

(defun agent-shell-manager-set-mode ()
  "Set session mode for the `agent-shell' at point."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-mode)
        (user-error "Not an agent-shell buffer"))
      (agent-shell-set-session-mode #'agent-shell-manager-refresh))
    (agent-shell-manager-refresh)))

(defun agent-shell-manager-set-model ()
  "Set session model for the `agent-shell' at point."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-mode)
        (user-error "Not an agent-shell buffer"))
      (agent-shell-set-session-model #'agent-shell-manager-refresh))
    (agent-shell-manager-refresh)))

(defun agent-shell-manager-interrupt ()
  "Interrupt the `agent-shell' at point."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-mode)
        (user-error "Not an agent-shell buffer"))
      (agent-shell-interrupt))
    (agent-shell-manager-refresh)))

(defun agent-shell-manager-view-traffic ()
  "View traffic logs for the `agent-shell' at point."
  (interactive)
  (when-let* ((buffer (agent-shell-manager--buffer-at-point)))
    (unless (buffer-live-p buffer)
      (user-error "Buffer no longer exists"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-mode)
        (user-error "Not an agent-shell buffer"))
      (agent-shell-view-traffic))))

(defun agent-shell-manager-toggle-logging ()
  "Toggle logging for `agent-shell'."
  (interactive)
  (agent-shell-toggle-logging)
  (agent-shell-manager-refresh))

;;;###autoload
(defun agent-shell-manager-toggle ()
  "Toggle the `agent-shell' buffer list window.
Shows buffer name, agent type, status (ready/waiting/working), session info, and mode.
The position of the window is controlled by `agent-shell-manager-side'.
When `agent-shell-manager-transient' is non-nil, the window can be closed
by `delete-other-windows' (C-x 1)."
  (interactive)
  (let* ((buffer (get-buffer-create "*Agent-Shell Buffers*"))
         (window (get-buffer-window buffer)))
    (if (and window (window-live-p window))
        ;; Window is visible, hide it
        (delete-window window)
      ;; Window is not visible, show it
      (let ((window (if agent-shell-manager-side
                        ;; Use side window with configured position
                        (let ((size-param (if (memq agent-shell-manager-side
                                                    '(left right))
                                              'window-width
                                            'window-height)))
                          (display-buffer-in-side-window
                           buffer
                           `((side . ,agent-shell-manager-side)
                             (slot . 0)
                             (,size-param . 0.3)
                             (preserve-size . ,(if (memq
                                                    agent-shell-manager-side
                                                    '(left right))
                                                   '(t . nil)
                                                 '(nil . t)))
                             ,@(unless agent-shell-manager-transient
                                 '((window-parameters .
                                    ((no-delete-other-windows . t))))))))
                      ;; Use regular window, let user's config control display
                      (display-buffer buffer))))
        (setq agent-shell-manager--global-buffer buffer)
        (with-current-buffer buffer
          (agent-shell-manager-mode)
          ;; In vertical layout, suppress the tabulated-list header line
          (when (eq agent-shell-manager-layout 'vertical)
            (setq-local header-line-format nil))
          (agent-shell-manager-refresh))
        ;; Make the window dedicated so it can't be used for other buffers
        (set-window-dedicated-p window t)
        (select-window window)))))

(provide 'agent-shell-manager)

;;; agent-shell-manager.el ends here
