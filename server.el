;;; server.el --- 水切り WebSocket game server (Emacs Lisp port)
;;
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1") (websocket "1.14"))
;;
;; Usage:
;;   emacs --batch --load server.el [-- [--host HOST] [--port PORT]]
;;   emacs --batch --load server.el -- --help
;;   emacs --batch --load server.el -- --version
;;
;; Optional:
;;   (package-install 'qrencode)  → enables QR-code generation
;;
;; All game logic is pure (no I/O); see GameEngine contract below.
;;
;; GameState hash-table keys:
;;   "board"     vector(9)  nil | "X" | "O"
;;   "queues"    hash-table "X"->list  "O"->list  (max 3 per player, FIFO)
;;   "current"   "X" | "O"
;;   "winner"    nil | "X" | "O"
;;   "winCells"  nil | list(3)   winning cell indices
;;   "scores"    hash-table "X"->int  "O"->int
;;   "moveCount" integer   monotonically increasing
;;   "gameOver"  boolean
;;
;; Invariants:
;;   length(queues[P]) <= 3
;;   gameOver => winner != nil
;;   board[i] == P  <=>  i in queues[P]
;;
;; Protocol contract:
;;   This file's mz-game-state-msg and index.html's GameEngine must
;;   emit identical field sets. Both files reference this docstring.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'package)

;; ---------------------------------------------------------------------------
;; Package bootstrap
;; ---------------------------------------------------------------------------

(setq package-archives
      '(("gnu"   . "https://elpa.gnu.org/packages/")
        ("melpa" . "https://melpa.org/packages/")))
(package-initialize)

(defun mz--require-package (pkg)
  "Install and require PKG; return t on success."
  (unless (package-installed-p pkg)
    (condition-case err
        (progn
          (unless package-archive-contents
            (package-refresh-contents))
          (package-install pkg))
      (error (message "[!] Cannot install %s: %s" pkg err)
             (cl-return-from mz--require-package nil))))
  (require pkg nil t))

(mz--require-package 'websocket)

(defvar mz--qrencode-p
  (mz--require-package 'qrencode)
  "Non-nil when qrencode.el is available.")

;; ---------------------------------------------------------------------------
;; Constants
;; ---------------------------------------------------------------------------

(defconst mz-version "1.0.0")

(defconst mz-win-lines
  '((0 1 2) (3 4 5) (6 7 8)
    (0 3 6) (1 4 7) (2 5 8)
    (0 4 8) (2 4 6))
  "All eight winning cell combinations.")

;; ---------------------------------------------------------------------------
;; Server state
;; ---------------------------------------------------------------------------

(defvar mz-host "127.0.0.1")
(defvar mz-port 8765)
(defvar mz-base-url
  (or (getenv "MIZUKIRI_BASE_URL") "https://mizukiri.dengzihao.me"))

(defvar mz-rooms (make-hash-table :test #'equal)
  "Map: room-code -> room hash-table.")

(defvar mz-ws-state (make-hash-table :test #'equal)
  "Map: ws-conn-key -> plist (:room CODE :player \"X\"|\"O\").")

(defvar mz-server nil
  "The live websocket-server process.")

;; ---------------------------------------------------------------------------
;; Game logic — pure functions, no I/O
;; ---------------------------------------------------------------------------

(defun mz-new-game (&optional first)
  "Return a fresh GameState hash-table.
FIRST is the starting player string (\"X\" or \"O\", default \"X\").

Post-condition: board is all-nil, both queues are empty,
moveCount is 0, gameOver is nil."
  (let ((g (make-hash-table :test #'equal))
        (q (make-hash-table :test #'equal))
        (s (make-hash-table :test #'equal)))
    (puthash "X" nil q) (puthash "O" nil q)
    (puthash "X" 0   s) (puthash "O" 0   s)
    (puthash "board"     (make-vector 9 nil) g)
    (puthash "queues"    q                   g)
    (puthash "current"   (or first "X")      g)
    (puthash "winner"    nil                 g)
    (puthash "winCells"  nil                 g)
    (puthash "scores"    s                   g)
    (puthash "moveCount" 0                   g)
    (puthash "gameOver"  nil                 g)
    g))

(defun mz-check-win (game player)
  "Return the winning line (list of 3 indices) for PLAYER, or nil.

Pre-condition: PLAYER's queue length <= 3.
Pure: does not modify GAME."
  (let ((q (gethash player (gethash "queues" game))))
    (when (>= (length q) 3)
      (let ((q-set (make-hash-table :test #'eql)))
        (mapc (lambda (i) (puthash i t q-set)) q)
        (cl-find-if (lambda (line)
                      (cl-every (lambda (i) (gethash i q-set)) line))
                    mz-win-lines)))))

(defun mz-apply-move (game pos)
  "Place a stone at POS (0-8) for the current player.

Side-effects: mutates GAME (board, queues, moveCount, winner,
              winCells, gameOver, scores, current).

Returns t on success; nil if the move is illegal (cell occupied
or game already over).

Post-conditions (when t):
  board[pos] == current-player
  length(queues[current-player]) <= 3
  moveCount incremented by 1
  if win: gameOver=t, winner set, score incremented
  turn switched to opponent."
  (cond
   ((gethash "gameOver" game) nil)
   ((aref (gethash "board" game) pos) nil)
   (t
    (let* ((p      (gethash "current" game))
           (board  (gethash "board"   game))
           (queues (gethash "queues"  game))
           (q      (gethash p queues)))
      ;; FIFO eviction when queue is at capacity
      (when (>= (length q) 3)
        (let ((old (car q)))
          (setq q (cdr q))
          (unless (member old q)
            (aset board old nil))))
      ;; Place new stone
      (setq q (append q (list pos)))
      (puthash p q queues)
      (aset board pos p)
      (puthash "moveCount" (1+ (gethash "moveCount" game)) game)
      ;; Win detection
      (let ((win (mz-check-win game p)))
        (if win
            (let ((scores (gethash "scores" game)))
              (puthash "winner"   p   game)
              (puthash "winCells" win game)
              (puthash "gameOver" t   game)
              (puthash p (1+ (gethash p scores)) scores))
          (puthash "current" (if (equal p "X") "O" "X") game)))
      t))))

;; ---------------------------------------------------------------------------
;; JSON helpers
;; ---------------------------------------------------------------------------

(defun mz--board->json (board)
  "Return a copy of BOARD with nil slots replaced by :null."
  (let ((v (copy-sequence board)))
    (cl-loop for i from 0 below 9
             when (null (aref v i)) do (aset v i :null))
    v))

(defun mz-game-state-msg (room)
  "Build a JSON-serialisable plist for a 'state' protocol message."
  (let* ((game    (gethash "game"    room))
         (swapped (gethash "swapped" room))
         (queues  (gethash "queues"  game))
         (scores  (gethash "scores"  game))
         (wc      (gethash "winCells" game)))
    `(:type      "state"
      :board     ,(mz--board->json (gethash "board" game))
      :queues    (:X ,(vconcat (gethash "X" queues))
                  :O ,(vconcat (gethash "O" queues)))
      :current   ,(gethash "current" game)
      :winner    ,(or (gethash "winner" game) :null)
      :winCells  ,(if wc (vconcat wc) :null)
      :scores    (:X ,(gethash "X" scores)
                  :O ,(gethash "O" scores))
      :gameOver  ,(if (gethash "gameOver" game) t :false)
      :swapped   ,(if swapped t :false)
      :moveCount ,(gethash "moveCount" game))))

;; ---------------------------------------------------------------------------
;; Network helpers
;; ---------------------------------------------------------------------------

(defun mz--ws-key (ws)
  "Return a stable string key for WS."
  (format "%s" (websocket-conn ws)))

(defun mz-send (ws plist)
  "Serialise PLIST to JSON and send over WS.
Degrades silently on a closed connection."
  (ignore-errors
    (websocket-send-text ws (json-serialize plist))))

(defun mz-broadcast (room alist)
  "Send ALIST to both host and guest of ROOM."
  (when-let ((h (gethash "host"  room))) (mz-send h alist))
  (when-let ((g (gethash "guest" room))) (mz-send g alist)))

;; ---------------------------------------------------------------------------
;; Room helpers
;; ---------------------------------------------------------------------------

(defun mz-make-code ()
  "Return a random 4-digit code string not already in mz-rooms."
  (let (c)
    (while (or (null c) (gethash c mz-rooms))
      (setq c (format "%04d" (random 10000))))
    c))

;; ---------------------------------------------------------------------------
;; QR code (optional dependency)
;; ---------------------------------------------------------------------------

(defun mz-make-qr (url)
  "Return a data-URI string encoding a QR code for URL.
Returns nil when qrencode.el is unavailable or generation fails."
  (when mz--qrencode-p
    (condition-case err
        (let* ((qr (qrencode url nil nil 'return-raw))
               (size (length qr))
               (rects nil))
          (cl-loop for row from 0 below size do
                   (cl-loop for col from 0 below size do
                            (when (/= (qrencode--aaref qr col row) 0)
                              (push (format
                                     (concat "<rect x=\"%d\" y=\"%d\" "
                                             "width=\"1\" height=\"1\" "
                                             "fill=\"#2c2416\"/>")
                                     col row)
                                    rects))))
          (let* ((svg (concat
                       (format
                        (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" "
                                "viewBox=\"0 0 %d %d\" width=\"256\" "
                                "height=\"256\" shape-rendering=\"crispEdges\">"
                                "<rect width=\"%d\" height=\"%d\" "
                                "fill=\"#fffef9\"/>")
                        size size size size)
                       (apply #'concat (nreverse rects))
                       "</svg>"))
                 (b64 (base64-encode-string
                       (encode-coding-string svg 'utf-8) t)))
            (concat "data:image/svg+xml;base64," b64)))
      (error
       (message "[!] QR generation failed: %s" err)
       nil))))

;; ---------------------------------------------------------------------------
;; WebSocket per-connection state
;; ---------------------------------------------------------------------------

(defun mz-ws-get (ws key)
  (plist-get (gethash (mz--ws-key ws) mz-ws-state) key))

(defun mz-ws-put (ws key val)
  (let* ((k  (mz--ws-key ws))
         (st (gethash k mz-ws-state)))
    (puthash k (plist-put st key val) mz-ws-state)))

;; ---------------------------------------------------------------------------
;; Message handlers
;; ---------------------------------------------------------------------------

(defun mz-handle-create (ws)
  "Handle 'create' message: allocate room and reply with code + QR."
  (let* ((code (mz-make-code))
         (room (make-hash-table :test #'equal)))
    (puthash "code"    code             room)
    (puthash "host"    ws               room)
    (puthash "guest"   nil              room)
    (puthash "state"   "waiting"        room)
    (puthash "game"    (mz-new-game "X") room)
    (puthash "swapped" nil              room)
    (puthash "created" (current-time)   room)
    (puthash code room mz-rooms)
    (mz-ws-put ws :room code)
    (mz-ws-put ws :player "X")
    (let* ((url (format "%s/?room=%s"
                        (string-trim-right mz-base-url "/")
                        code))
           (qr (or (mz-make-qr url) :null)))
      (mz-send ws `(:type "created"
                    :code ,code
                    :qr   ,qr)))
    (message "[+] Room %s created" code)))

(defun mz-handle-join (ws msg)
  "Handle 'join' message: pair guest with waiting host."
  (let* ((code (cdr (assoc 'code msg)))
         (room (and code (gethash code mz-rooms))))
    (if (or (null room) (not (equal (gethash "state" room) "waiting")))
        (mz-send ws '(:type "error" :msg "房间不存在或已满"))
      (puthash "guest" ws        room)
      (puthash "state" "playing" room)
      (mz-ws-put ws :room code)
      (mz-ws-put ws :player "O")
      (mz-send (gethash "host" room)
               '(:type "start" :player "X" :mode "remote"))
      (mz-send ws
               '(:type "start" :player "O" :mode "remote"))
      (mz-broadcast room (mz-game-state-msg room))
      (message "[+] Room %s joined" code))))

(defun mz-handle-move (ws msg)
  "Handle 'move' message: validate turn, apply, broadcast or reject."
  (let* ((code      (mz-ws-get ws :room))
         (my-player (mz-ws-get ws :player))
         (room      (and code (gethash code mz-rooms)))
         (game      (and room (gethash "game" room)))
         (pos       (cdr (assoc 'position msg))))
    (when (and room
               (equal (gethash "state" room) "playing")
               (equal (gethash "current" game) my-player)
               (integerp pos) (<= 0 pos 8))
      (if (mz-apply-move game pos)
          (mz-broadcast room (mz-game-state-msg room))
        (mz-send ws `(:type "rejected" :position ,pos))))))

(defun mz-handle-swap (ws)
  "Handle 'swap' message: toggle first player, reset board, keep scores."
  (let* ((code (mz-ws-get ws :room))
         (room (and code (gethash code mz-rooms))))
    (when (and room (equal (gethash "state" room) "playing"))
      (let* ((swapped (not (gethash "swapped" room)))
             (first   (if swapped "O" "X"))
             (scores  (gethash "scores" (gethash "game" room)))
             (ng      (mz-new-game first)))
        (puthash "scores"  scores  ng)
        (puthash "swapped" swapped room)
        (puthash "game"    ng      room)
        (mz-broadcast room (mz-game-state-msg room))
        (message "[*] Room %s swapped, first=%s" code first)))))

(defun mz-handle-reset (ws)
  "Handle 'reset' message: start new game, preserve scores."
  (let* ((code (mz-ws-get ws :room))
         (room (and code (gethash code mz-rooms))))
    (when (and room (equal (gethash "state" room) "playing"))
      (let* ((first  (if (gethash "swapped" room) "O" "X"))
             (scores (gethash "scores" (gethash "game" room)))
             (ng     (mz-new-game first)))
        (puthash "scores" scores ng)
        (puthash "game"   ng     room)
        (mz-broadcast room (mz-game-state-msg room))
        (message "[*] Room %s reset" code)))))

(defun mz-on-close (ws)
  "Handle WS disconnection: notify peer and evict room."
  (let* ((key       (mz--ws-key ws))
         (st        (gethash key mz-ws-state))
         (code      (plist-get st :room))
         (my-player (plist-get st :player))
         (room      (and code (gethash code mz-rooms))))
    (when room
      (let ((other (if (equal my-player "X")
                       (gethash "guest" room)
                     (gethash "host"  room))))
        (when other
          (mz-send other '(:type "opponent_left"))))
      (remhash code mz-rooms)
      (message "[-] Room %s closed" code))
    (remhash key mz-ws-state)))

(defun mz-on-message (ws frame)
  "Dispatch an incoming WebSocket FRAME from WS."
  (let* ((raw  (websocket-frame-text frame))
         (msg  (condition-case nil
                   (json-parse-string raw
                                      :object-type 'alist
                                      :null-object  nil
                                      :false-object nil)
                 (error nil)))
         (type (and msg (cdr (assoc 'type msg)))))
    (when type
      (cond
       ((equal type "create") (mz-handle-create ws))
       ((equal type "join")   (mz-handle-join   ws msg))
       ((equal type "move")   (mz-handle-move   ws msg))
       ((equal type "swap")   (mz-handle-swap   ws))
       ((equal type "reset")  (mz-handle-reset  ws))
       ((equal type "leave")  (mz-on-close      ws))
       ((equal type "ping")
        (mz-send ws '(:type "pong")))
       (t
        (message "[?] Unknown message type: %s" type))))))

;; ---------------------------------------------------------------------------
;; Room sweeper
;; ---------------------------------------------------------------------------

(defun mz-sweep-rooms ()
  "Delete rooms idle beyond their TTL.

Waiting rooms expire after 30 min; playing rooms after 2 h."
  (let ((now     (current-time))
        (zombies nil))
    (maphash
     (lambda (code room)
       (let* ((elapsed (float-time
                        (time-subtract now (gethash "created" room))))
              (state   (gethash "state" room)))
         (when (or (and (equal state "waiting") (> elapsed 1800))
                   (and (equal state "playing") (> elapsed 7200)))
           (push code zombies))))
     mz-rooms)
    (dolist (code zombies)
      (when-let ((room (gethash code mz-rooms)))
        (message "[-] Zombie room %s cleaned up" code)
        (mz-broadcast room '(:type "room_closed"))
        (ignore-errors
          (when-let ((h (gethash "host" room))) (websocket-close h)))
        (ignore-errors
          (when-let ((g (gethash "guest" room))) (websocket-close g)))
        (remhash code mz-rooms)))))

;; ---------------------------------------------------------------------------
;; Graceful shutdown
;; ---------------------------------------------------------------------------

(defun mz-shutdown ()
  "Close all rooms and the server process.
Called from `kill-emacs-hook'."
  (message "[*] Shutting down...")
  (maphash
   (lambda (code room)
     (message "[-] Closing room %s" code)
     (mz-broadcast room '(:type "room_closed"))
     (ignore-errors
       (when-let ((h (gethash "host"  room))) (websocket-close h)))
     (ignore-errors
       (when-let ((g (gethash "guest" room))) (websocket-close g))))
   mz-rooms)
  (when mz-server
    (ignore-errors (websocket-server-close mz-server))))

;; ---------------------------------------------------------------------------
;; CLI argument parsing
;; ---------------------------------------------------------------------------

(defun mz-parse-args ()
  "Parse --host, --port, --version, --help from `command-line-args-left'."
  (let ((args (cdr (member "--" command-line-args-left))))
    (cl-loop while args do
      (pcase (car args)
        ("--port"
         (setq mz-port (string-to-number (cadr args)))
         (setq args (cddr args)))
        ("--host"
         (setq mz-host (cadr args))
         (setq args (cddr args)))
        ("--version"
         (message "mizukiri-server (elisp) %s" mz-version)
         (kill-emacs 0))
        ("--help"
         (message
          "Usage: emacs --batch --load server.el [-- [--host H] [--port P]]\n\
Options:\n\
  --host HOST  bind address (default: 127.0.0.1)\n\
  --port PORT  listen port  (default: 8765)\n\
  --version    print version and exit\n\
  --help       print this help and exit")
         (kill-emacs 0))
        (_ (setq args (cdr args)))))))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

(defun mz-main ()
  "Start the 水切り WebSocket server and enter the event loop."
  (mz-parse-args)
  (message "[*] 水切り server (elisp %s) starting on %s:%d"
           mz-version mz-host mz-port)

  (setq mz-server
        (websocket-server
         mz-port
         :on-open    (lambda (_ws) nil)
         :on-message #'mz-on-message
         :on-close   #'mz-on-close
         :on-error   (lambda (_ws _type err)
                       (message "[!] WebSocket error: %s" err))))

  ;; Periodic room cleanup every 10 min
  (run-with-timer 600 600 #'mz-sweep-rooms)

  ;; Register shutdown hook
  (add-hook 'kill-emacs-hook #'mz-shutdown)

  (message "[*] Ready. Send SIGTERM to stop.")
  ;; Event loop — sit-for yields to process events without busy-waiting
  (while t (sit-for 1)))

(unless (bound-and-true-p mz-inhibit-startup)
  (mz-main))

;;; server.el ends here
