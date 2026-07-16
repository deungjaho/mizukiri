;;; test_server.el --- ERT unit tests for server.el

(require 'ert)

;; Load server.el without running mz-main
(setq mz-inhibit-startup t)
(load (expand-file-name "../server.el" (file-name-directory load-file-name)))

;; Helper to check if game hash-tables are equal
(defun mz-test-game-equal (g1 g2)
  (and (equal (gethash "board" g1) (gethash "board" g2))
       (equal (gethash "current" g1) (gethash "current" g2))
       (equal (gethash "winner" g1) (gethash "winner" g2))
       (equal (gethash "winCells" g1) (gethash "winCells" g2))
       (equal (gethash "moveCount" g1) (gethash "moveCount" g2))
       (equal (gethash "gameOver" g1) (gethash "gameOver" g2))))

(ert-deftest test-mz-new-game ()
  (let ((game (mz-new-game "X")))
    (should (equal (gethash "board" game) (make-vector 9 nil)))
    (should (equal (gethash "current" game) "X"))
    (should (equal (gethash "winner" game) nil))
    (should (equal (gethash "winCells" game) nil))
    (should (equal (gethash "moveCount" game) 0))
    (should (equal (gethash "gameOver" game) nil))
    (should (equal (gethash "X" (gethash "scores" game)) 0))
    (should (equal (gethash "O" (gethash "scores" game)) 0))))

(ert-deftest test-mz-new-game-o ()
  (let ((game (mz-new-game "O")))
    (should (equal (gethash "current" game) "O"))))

(ert-deftest test-mz-apply-move-normal ()
  (let ((game (mz-new-game "X")))
    (should (mz-apply-move game 4))
    (should (equal (aref (gethash "board" game) 4) "X"))
    (should (equal (gethash "current" game) "O"))
    (should (equal (gethash "moveCount" game) 1))))

(ert-deftest test-mz-apply-move-fifo-evict ()
  (let ((g (mz-new-game "X")))
    ;; Play moves: X 0, O 8, X 1, O 7, X 6, O 5
    (should (mz-apply-move g 0)) ; X queue [0]
    (should (mz-apply-move g 8)) ; O
    (should (mz-apply-move g 1)) ; X queue [0 1]
    (should (mz-apply-move g 7)) ; O
    (should (mz-apply-move g 6)) ; X queue [0 1 6]
    (should (mz-apply-move g 5)) ; O
    ;; X plays 3 -> queue exceeds capacity, 0 is evicted
    (should (mz-apply-move g 3))
    (should (equal (aref (gethash "board" g) 0) nil))
    (should (equal (aref (gethash "board" g) 3) "X"))))

(ert-deftest test-mz-apply-move-fifo-no-clear ()
  (let ((g (mz-new-game "X")))
    ;; Manually set up a situation where 0 is in queue twice
    (puthash "X" '(0 1 0) (gethash "queues" g))
    (aset (gethash "board" g) 0 "X")
    (aset (gethash "board" g) 1 "X")
    ;; Next move triggers eviction of oldest (0)
    (should (mz-apply-move g 2)) ; X queue becomes '(1 0 2)
    ;; Since 0 is still in queue, it should NOT be cleared from board
    (should (equal (aref (gethash "board" g) 0) "X"))
    (should (equal (aref (gethash "board" g) 2) "X"))))

(ert-deftest test-mz-apply-move-reject-occupied ()
  (let ((game (mz-new-game "X")))
    (should (mz-apply-move game 4))
    (should-not (mz-apply-move game 4))
    (should (equal (aref (gethash "board" game) 4) "X"))))

(ert-deftest test-mz-apply-move-reject-game-over ()
  (let ((game (mz-new-game "X")))
    ;; Build a win for X
    (should (mz-apply-move game 0)) ; X
    (should (mz-apply-move game 3)) ; O
    (should (mz-apply-move game 1)) ; X
    (should (mz-apply-move game 4)) ; O
    (should (mz-apply-move game 2)) ; X wins!
    (should (gethash "gameOver" game))
    ;; Try to move after game over
    (should-not (mz-apply-move game 8))))

(ert-deftest test-mz-check-win-row ()
  (let ((game (mz-new-game "X")))
    (should (mz-apply-move game 0)) ; X
    (should (mz-apply-move game 3)) ; O
    (should (mz-apply-move game 1)) ; X
    (should (mz-apply-move game 4)) ; O
    (should (mz-apply-move game 2)) ; X wins!
    (should (equal (gethash "winner" game) "X"))
    (should (equal (gethash "winCells" game) '(0 1 2)))
    (should (equal (gethash "X" (gethash "scores" game)) 1))))

(ert-deftest test-mz-check-win-diagonal ()
  (let ((game (mz-new-game "X")))
    (should (mz-apply-move game 0)) ; X
    (should (mz-apply-move game 1)) ; O
    (should (mz-apply-move game 4)) ; X
    (should (mz-apply-move game 2)) ; O
    (should (mz-apply-move game 8)) ; X wins!
    (should (equal (gethash "winner" game) "X"))
    (should (equal (gethash "winCells" game) '(0 4 8)))))

(ert-deftest test-mz-invariants ()
  (let ((game (mz-new-game "X"))
        (seq '(4 0 8 2 6 3 5 1 7)))
    (dolist (pos seq)
      (mz-apply-move game pos)
      (should (<= (length (gethash "X" (gethash "queues" game))) 3))
      (should (<= (length (gethash "O" (gethash "queues" game))) 3))
      (when (gethash "gameOver" game)
        (cl-return)))))

