;;; braille.el -- Braille drawing minor mode  -*- lexical-binding: t; -*-

;; 2026-02-10 07:04
;; Author: plu5
;; Keywords: mouse
;; URL: https://github.com/plu5/braille.el

;; This file is not part of GNU Emacs.

;;; Commentary:
;; M-x braille-mode
;; create canvas with C-c v (braille-create-canvas-at-point)
;; left click to draw
;; hold ctrl while drawing to erase

;;; Code:

(defgroup braille nil
  "Minor mode for drawing with braille dots."
  :group 'mouse)

(defcustom braille-use-blank-grid nil
  "Whether to use the blank grid character '⠀' instead of space.
This can be useful if you intend to use your artwork in an environment that
is not going to display it a monospace font.
See `braille-convert-spacing-in-region' to convert existing canvases."
  :type 'boolean
  :group 'braille)

(defcustom braille-consider-text-out-of-bounds t
  "Avoid drawing on characters that are not either braille or space."
  :type 'boolean
  :group 'braille)

(defcustom braille-consider-space-out-of-bounds nil
  "Avoid drawing on space.
Expected to be used in combination with `braille-use-blank-grid' t."
  :type 'boolean
  :group 'braille)

(defcustom braille-default-canvas-size "0x0"
  "Canvas size in the format WxH to use as default dimensions.
Used in `braille-create-canvas-at-point-without-asking' and in
`braille-create-canvas-at-point' as the default value.
The unit of W and H is number of characters. 0 means auto."
  :type 'string
  :group 'braille)

(defcustom braille-inhibit-modification-hooks t
  "Whether to set `inhibit-modification-hooks' to t while drawing.
This improves performance at the cost of ignoring
`before-change-functions', 'after-change-functions', hooks attached to
text properties and overlays, file locks and related checks, and
handling of the active region per `select-active-regions'."
  :type 'boolean
  :group 'braille)

(defcustom braille-pointer x-pointer-crosshair
  "Mouse pointer in `braille-mode'.
`braille-mode' sets `x-pointer-shape' to this value when activated, and
back to what it was set to before when deactivated. For possible values
see `x-pointer-*' variables like `x-pointer-arrow',
`x-pointer-crosshair', `x-pointer-dot', `x-pointer-circle'. Set this to
nil to not change the pointer."
  :type 'natnum
  :group 'braille)

(defcustom braille-mouse-color "red"
  "Color to give `set-mouse-color'.
It is used to make `x-pointer-shape' update without having to create a
new frame. This only changes the color with some pointer shapes."
  :type 'string
  :group 'braille)

(defvar braille-prev-pointer nil
  "Storage for previous value of `x-pointer-shape'.")
(defvar braille-prev-mouse-color nil
  "Storage for previous value of mouse color in `frame-parameters'.")
(defvar braille-needs-to-reset-pointer-flag nil
  "Whether the pointer had been changed by braille.el and not yet reset.")

(defconst braille-base #x2800 "Start of unicode braille block")
(defconst braille-nrows 4 "Number of rows in the braille grid")
(defconst braille-ncols 2 "Number of columns in the braille grid")

(defun braille-set-pointer ()
  "Set `x-pointer-shape' to `braille-pointer', saving its previous value.
Mouse color is changed as well because it's required for it to update."
  (setq braille-prev-pointer x-pointer-shape)
  (setq x-pointer-shape braille-pointer)
  (setq braille-needs-to-reset-pointer-flag t)
  (setq braille-prev-mouse-color (frame-parameter nil 'mouse-color))
  (set-mouse-color braille-mouse-color))

(defun braille-reset-pointer ()
  "Reset `x-pointer-shape' and mouse color.
Using `braille-prev-pointer' and `braille-prev-mouse-color'."
  (setq x-pointer-shape braille-prev-pointer) ; nil is a valid value
  (setq braille-prev-pointer nil)
  (setq braille-needs-to-reset-pointer-flag nil)
  ;; we have to always set it, even if it's nil, as otherwise the
  ;; pointer will not update. but even on emacs -Q it's not nil, it's
  ;; "black"
  (set-mouse-color braille-prev-mouse-color)
  (setq braille-prev-mouse-color nil))

(defun braille-inhibit-modification-hooks-p ()
  "Return value `inhibit-modification-hooks' should be set to while drawing."
  (if braille-inhibit-modification-hooks t inhibit-modification-hooks))

(defun braille-empty-char ()
  "Return the character used for empty canvas in braille.
Either space or the blank grid character '⠀', according to the value of
`braille-use-blank-grid'."
  (if braille-use-blank-grid braille-base ?\s))

(defun braille-char-name-or-char (c)
  "Return description for space and blank braille grid if c is one of them.
Otherwise, return c as a string."
  (cond
   ((eq c ?\s) "space")
   ((eq c braille-base) "blank braille grid")
   (t (char-to-string c))))

(defun braille-or0 (v default)
  "Return V if V is nonzero, DEFAULT otherwise."
  (if (and (numberp v) (zerop v))
      default
    v))

(defun braille-create-canvas-at-point (size)
  "Create an area of whitespace with given dimensions."
  (interactive
   (list (split-string
          (read-string "Canvas size (0=auto): " braille-default-canvas-size)
          "x")))
  (unless (= (length size) 2)
    (user-error "Expected canvas size format: WxH (ex. 50x20)"))
  (let ((w (braille-or0 (string-to-number (car size)) (window-width)))
        (h (braille-or0 (string-to-number (cadr size)) (window-height)))
        (c (braille-empty-char)))
    (dotimes (i h)
      (insert (make-string w c) "\n"))
    (message "Created %sx%s canvas with %s character" w h
             (braille-char-name-or-char c))))

(defun braille-create-canvas-at-point-unprompted ()
  "Create an area of whitespace with default dimensions.
As defined in `braille-default-canvas-size'."
  (interactive)
  (braille-create-canvas-at-point
   (split-string braille-default-canvas-size "x")))

(defun braille-convert-spacing-in-region (beg end)
  "Convert characters in region from braille blank grid to space or vice versa.
If a braille blank grid character is found in region, convert braille
blank grid characters to spaces, otherwise convert spaces to braille
blank grid characters."
  (interactive "*r")
  (save-restriction
    (narrow-to-region beg end)
    (let* ((grd (char-to-string braille-base))
           (spc " ")
           (old (if (save-excursion (search-forward grd nil t 1)) grd spc))
           (new (if (eq old grd) spc grd)))
      (goto-char (point-min))
      (while (search-forward old nil t 1)
        (replace-match new))
      (message "Converted [%s] (%s) to [%s] (%s) in region %s to %s"
               old (braille-char-name-or-char (string-to-char old))
               new (braille-char-name-or-char (string-to-char new)) beg end))))

(defun braille-colrow-from-posn (posn)
    "Calculate colrow of appropriate braille point given POSN.
(col . row) where col = 0/1 and row = 0/1/2/3."
  (let* ((rel-xy (posn-object-x-y posn))
         (rel-wh (posn-object-width-height posn))
         (col (min (1- braille-ncols)
                   ;; x / w / ncols
                   (/ (car rel-xy) (/ (car rel-wh) braille-ncols))))
         (row (min (1- braille-nrows)
                   ;; y / h / nrows
                   (/ (cdr rel-xy) (/ (cdr rel-wh) braille-nrows)))))
    (cons col row)))

(defun braille-bit-from-colrow (colrow)
  "Get braille dot bit at COLROW.
COLROW is (col . row) for the dot position in the 2x4 braille grid, 0-based."
  ;; unfortunately this can't be a simple data structure because
  ;; the order in braille is 1237 4568
  (let ((col (car colrow))
        (row (cdr colrow)))
    (cond
     ;; left
     ((and (= col 0) (= row 0)) #b00000001)
     ((and (= col 0) (= row 1)) #b00000010)
     ((and (= col 0) (= row 2)) #b00000100)
     ((and (= col 0) (= row 3)) #b01000000)
     ;; right
     ((and (= col 1) (= row 0)) #b00001000)
     ((and (= col 1) (= row 1)) #b00010000)
     ((and (= col 1) (= row 2)) #b00100000)
     ((and (= col 1) (= row 3)) #b10000000))))

(defun braille-posn-char-xy (posn)
  "Return char top left pixel coordinates (x . y) given POSN."
  (posn-x-y (posn-at-point (posn-point posn))))

(defun braille-in-bounds-p (posn)
  "If POSN is in bounds for braille drawing return t, nil otherwise."
  (let ((click-xy (posn-x-y posn))
        (char-xy (braille-posn-char-xy posn))
        (rel-wh (posn-object-width-height posn)))
    ;; (message "bounds calc %s %s %s" click-xy char-xy rel-wh)  ; debug
    (and (<= (car click-xy) (+ (car char-xy) (car rel-wh)))
         (<= (cdr click-xy) (+ (cdr char-xy) (cdr rel-wh)))
         (< (posn-point posn) (point-max)))))

(defun braille-e-debug (e)
  "Show information about the input position for debugging purposes.
E should be an input event."
  (interactive "e")
  (let* ((posn (event-start e))
         (char-pos (posn-point posn))
         (rel-xy (posn-object-x-y posn))
         (click-xy (posn-x-y posn))
         (colrow (braille-colrow-from-posn posn))
         (bit (braille-bit-from-colrow colrow))
         (char-posn (posn-at-point char-pos)))
    (message
     "@@ char-pos:%d rel-xy:%s click-xy:%s colrow:%s bit:%s char-xy:%s
in-bounds:%s
p:%s s:%s"
     char-pos rel-xy click-xy colrow bit (posn-x-y char-posn)
     (braille-in-bounds-p posn)
     char-posn (braille-posn-debug posn))))

(defun braille-char-p (char)
  "If CHAR is a braille character return its delta, otherwise return nil."
  (let ((delta (- char braille-base)))
    (if (and (>= delta 0) (< delta 256))
        delta)))

(defun braille-bit-from-posn (posn)
  "Get bit for appropriate dot given POSN."
  (braille-bit-from-colrow
   (braille-colrow-from-posn posn)))

(defun braille-posn-at-xy (xy)
  "Return the posn at XY, where XY is a cons (x . y) of pixel coordinates."
  (posn-at-x-y (car xy) (cdr xy)))

(defun braille-legal-char-p (char)
  "Return t if braille.el is allowed to replace CHAR, nil otherwise."
  (cond
   ((and (eq char ?\n)
         (message "braille: out of bounds (newline character)"))
    nil)
   ((and braille-consider-space-out-of-bounds (eq char ?\s)
         (message "braille: out of bounds (space)"))
    nil)
   ((and braille-consider-text-out-of-bounds
         (null (braille-char-p char)) (not (eq char ?\s))
         (message "braille: out of bounds (text)"))
    nil)
   (t t)))

(defun braille-onto (char-pos dot-bit &optional erase)
  "Replace char at CHAR-POS if legal, adding or erasing dot DOT-BIT from it."
  (save-excursion
    (goto-char char-pos)
    (let ((cur-char (char-after)))
      (if (braille-legal-char-p cur-char)
          (let* ((d (braille-char-p cur-char)) ; delta
                 (new-dot-value (if erase
                                    (if d (logand d (lognot dot-bit)) 0)
                                  (if d (logior d dot-bit) dot-bit)))
                 (new-char (if (and erase (= 0 new-dot-value))
                               (braille-empty-char)
                             (+ braille-base new-dot-value))))
            (delete-char 1)
            (insert new-char))))))

(defun braille-onto-xy (xy &optional erase)
  "Place braille dot at appropriate position based on pixel coordinates XY.
Places the first dot or adds it to the existing dots if character under
point is already a braille character.
XY should be (x . y) where x and y are pixel coordinates.
If ERASE is t, erase the dot instead of placing it."
  (let* ((posn (braille-posn-at-xy xy))
         (char-pos (posn-point posn))
         (dot-bit (braille-bit-from-posn posn)))
    (if (braille-in-bounds-p posn)
        (braille-onto char-pos dot-bit erase)
      (message "braille: out of bounds"))))

(defun braille-e-single (e)
  "Place braille dot at appropriate position based on mouse location.
E should be an input event."
  (interactive "e")
  (braille-onto-xy (posn-x-y (event-start e))))

(defun braille-posn-debug (posn &optional text)
  "Show message with information from POSN.
POSN is the return from `event-start' or `event-end'."
  (let (char-pos click-xy char-posn)
    (setq char-pos (posn-point posn))
    (setq click-xy (posn-x-y posn))
    (setq char-posn (braille-posn-at-xy click-xy))
    (message "%s char-pos:%s | click-xy:%s |\
 char-pos-xy:%s | posn:%s | char-posn:%s"
             (or text "braille-posn-debug") char-pos click-xy
             (posn-x-y char-posn) char-posn posn)))

(defun braille-dot-wh ()
  "Return (width . height) in pixels of a braille dot."
  (let ((dot-w (/ (window-font-width) (float braille-ncols)))
        (dot-h (/ (window-font-height) (float braille-nrows))))
    (cons dot-w dot-h)))

(defun braille-posn-to-dot-xy (posn)
  "Convert POSN to dotspace coordinates (dot-x . dot-y)."
  (let* ((xyn (braille-posn-char-xy posn)) ; top left
         (dot-wh (braille-dot-wh))
         (colrow (braille-colrow-from-posn posn))
         (dot-x (+ (/ (car xyn) (car dot-wh)) (car colrow)))
         (dot-y (+ (/ (cdr xyn) (cdr dot-wh)) (cdr colrow))))
    (cons dot-x dot-y)))

(defun braille-onto-dot-xy (dot-xy &optional erase)
  "Place braille dot at dotspace (dot-x . dot-y).
If ERASE is t, erase the dot instead of placing it."
  (let* ((dot-wh (braille-dot-wh))
         (xy (cons (floor (* (car dot-xy) (car dot-wh)))
                   (floor (* (cdr dot-xy) (cdr dot-wh))))))
    (braille-onto-xy xy erase)))

(defun braille-dot-xy-line (dot-xy0 dot-xy1 &optional erase)
  "Draw a line of braille points from DOT-XY0 to DOT-XY1 in dotspace.
DOT-XY0 and DOT-XY1 should each be a position in dotspace like (dot-x . dot-y)
(dots from the left and dots from the top).
If ERASE is t, erase instead."
  (let* ((dot-wh (braille-dot-wh))
         (x0 (car dot-xy0))
         (y0 (cdr dot-xy0))
         (x1 (car dot-xy1))
         (y1 (cdr dot-xy1))
         (dx (abs (- x1 x0)))
         (dy (abs (- y1 y0)))
         (sx (if (< x0 x1) 1 -1))
         (sy (if (< y0 y1) 1 -1))
         (err (- dx dy)))
    (while (not (and (= x0 x1) (= y0 y1)))
      (braille-onto-dot-xy (cons x0 y0) erase)
      (let ((e2 (* 2 err)))
        (when (> e2 (- dy))
          (setq err (- err dy))
          (setq x0 (+ x0 sx)))
        (when (< e2 dx)
          (setq err (+ err dx))
          (setq y0 (+ y0 sy)))))
    (braille-onto-dot-xy (cons x1 y1) erase)))

(defun braille-xy-line (xy0 xy1)
  "Draw a line of braille points from XY0 to XY1.
XY0 and XY1 should each be a position in pixels like (x . y)"
  (let* ((dot-xy0 (braille-posn-to-dot-xy (braille-posn-at-xy xy0)))
         (dot-xy1 (braille-posn-to-dot-xy (braille-posn-at-xy xy1))))
    (braille-dot-xy-line dot-xy0 dot-xy1)))

(defun braille-e-line (e)
  "Draw a line of braille points.
Interpolates a line from position mouse is pressed to position it is let go.
E should be a mouse down event."
  (interactive "e")
  (undo-boundary)
  (track-mouse
    (let (xy0
          xy1
          (inhibit-modification-hooks (braille-inhibit-modification-hooks-p)))
      (setq xy0 (posn-x-y (event-start e))) ; start xy
      (while (and (setq e (read-event)) (mouse-movement-p e)) ; drag
        (ignore))
      (setq xy1 (posn-x-y (event-end e))) ; end xy
      (braille-xy-line xy0 xy1))))

(defun braille-e-stroke (e &optional erase)
  "Draw braille while mouse is dragged, stopping when it is let go.
E should be a mouse down event.
If ERASE is t, erase instead."
  (interactive "e")
  (undo-boundary)
  (let* ((posn (event-start e))
         (dot-xy-prev (braille-posn-to-dot-xy posn))
         dot-xy-cur
         (inhibit-modification-hooks (braille-inhibit-modification-hooks-p)))
    ;; (message "braille-mouse-draw posn: %s" posn)  ; debug
    (braille-onto-dot-xy dot-xy-prev erase) ; first click
    (track-mouse
      (while (and (setq e (read-event)) (mouse-movement-p e)) ; drag
        (setq dot-xy-cur (braille-posn-to-dot-xy (event-start e)))
        (unless (eq dot-xy-cur dot-xy-prev)
          (braille-dot-xy-line dot-xy-prev dot-xy-cur erase))
        ;; (message "movement %s" dot-xy-cur)  ; debug
        (setq dot-xy-prev dot-xy-cur)))))

(defun braille-e-stroke-erase (e)
  "Erase braille while mouse is dragged, stopping when it is let go.
E should be a mouse down event."
  (interactive "e")
  (braille-e-stroke e t))

(define-minor-mode braille-mode
  "Toggles global braille-mode.
Minor mode for drawing with braille dots."
  :global t
  :lighter " ⣿"
  :keymap
  '(([down-mouse-1] . braille-e-stroke)
    ([mouse-1] . ignore)
    ([drag-mouse-1] . ignore)
    ([C-down-mouse-1] . braille-e-stroke-erase)
    ([C-drag-mouse-1] . ignore)
    ([C-mouse-1] . ignore)
    ([M-mouse-1] . undo-only)
    ([M-down-mouse-1] . ignore)
    ([M-drag-mouse-1] . ignore)
    ([M-S-mouse-1] . undo-redo)
    ([M-S-down-mouse-1] . ignore)
    ([M-S-drag-mouse-1] . ignore)
    ([(control ?c) ?v] . braille-create-canvas-at-point)
    ([(control ?c) (control ?v)] . braille-create-canvas-at-point-unprompted))
  (if braille-mode
      (if braille-pointer (braille-set-pointer))
    (if braille-needs-to-reset-pointer-flag (braille-reset-pointer))))

(provide 'braille)

;;; Debug bindings:
;; (global-set-key [mouse-8] #'braille-e-debug)
;; (global-set-key [down-mouse-1] #'braille-e-line)

;; (braille-mode 'toggle)
;; braille-prev-pointer
;; braille-prev-mouse-color

;;; Demo:
;; (progn (eval-buffer) (braille-mode))

;;; braille.el ends here
