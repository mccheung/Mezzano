;;;; Basic cons-related functions.
;;;; This file is loaded at bootstrap time and once more after the compiler
;;;; is loaded, so it should only contain final versions of the functions.

(in-package "SYSTEM.INTERNALS")

(declaim (inline caar cadr cdar cddr))
(defun caar (x)
  (car (car x)))
(defun cadr (x)
  (car (cdr x)))
(defun cdar (x)
  (cdr (car x)))
(defun cddr (x)
  (cdr (cdr x)))
(defun (setf caar) (value x)
  (funcall #'(setf car) value (car x)))
(defun (setf cadr) (value x)
  (funcall #'(setf car) value (cdr x)))
(defun (setf cdar) (value x)
  (funcall #'(setf cdr) value (car x)))
(defun (setf cddr) (value x)
  (funcall #'(setf cdr) value (cdr x)))

(defun caaar (x)
  (car (car (car x))))
(defun caadr (x)
  (car (car (cdr x))))
(defun cadar (x)
  (car (cdr (car x))))
(defun caddr (x)
  (car (cdr (cdr x))))
(defun cdaar (x)
  (cdr (car (car x))))
(defun cdadr (x)
  (cdr (car (cdr x))))
(defun cddar (x)
  (cdr (cdr (car x))))
(defun cdddr (x)
  (cdr (cdr (cdr x))))
(defun (setf caaar) (value x)
  (funcall #'(setf car) value (car (car x))))
(defun (setf caadr) (value x)
  (funcall #'(setf car) value (car (cdr x))))
(defun (setf cadar) (value x)
  (funcall #'(setf car) value (cdr (car x))))
(defun (setf caddr) (value x)
  (funcall #'(setf car) value (cdr (cdr x))))
(defun (setf cdaar) (value x)
  (funcall #'(setf cdr) value (car (car x))))
(defun (setf cdadr) (value x)
  (funcall #'(setf cdr) value (car (cdr x))))
(defun (setf cddar) (value x)
  (funcall #'(setf cdr) value (cdr (car x))))
(defun (setf cdddr) (value x)
  (funcall #'(setf cdr) value (cdr (cdr x))))

(defun caaaar (x)
  (car (car (car (car x)))))
(defun caaadr (x)
  (car (car (car (cdr x)))))
(defun caadar (x)
  (car (car (cdr (car x)))))
(defun caaddr (x)
  (car (car (cdr (cdr x)))))
(defun cadaar (x)
  (car (cdr (car (car x)))))
(defun cadadr (x)
  (car (cdr (car (cdr x)))))
(defun caddar (x)
  (car (cdr (cdr (car x)))))
(defun cadddr (x)
  (car (cdr (cdr (cdr x)))))
(defun cdaaar (x)
  (cdr (car (car (car x)))))
(defun cdaadr (x)
  (cdr (car (car (cdr x)))))
(defun cdadar (x)
  (cdr (car (cdr (car x)))))
(defun cdaddr (x)
  (cdr (car (cdr (cdr x)))))
(defun cddaar (x)
  (cdr (cdr (car (car x)))))
(defun cddadr (x)
  (cdr (cdr (car (cdr x)))))
(defun cdddar (x)
  (cdr (cdr (cdr (car x)))))
(defun cddddr (x)
  (cdr (cdr (cdr (cdr x)))))
(defun (setf caaaar) (value x)
  (funcall #'(setf car) value (car (car (car x)))))
(defun (setf caaadr) (value x)
  (funcall #'(setf car) value (car (car (cdr x)))))
(defun (setf caadar) (value x)
  (funcall #'(setf car) value (car (cdr (car x)))))
(defun (setf caaddr) (value x)
  (funcall #'(setf car) value (car (cdr (cdr x)))))
(defun (setf cadaar) (value x)
  (funcall #'(setf car) value (cdr (car (car x)))))
(defun (setf cadadr) (value x)
  (funcall #'(setf car) value (cdr (car (cdr x)))))
(defun (setf caddar) (value x)
  (funcall #'(setf car) value (cdr (cdr (car x)))))
(defun (setf cadddr) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr x)))))
(defun (setf cdaaar) (value x)
  (funcall #'(setf cdr) value (car (car (car x)))))
(defun (setf cdaadr) (value x)
  (funcall #'(setf cdr) value (car (car (cdr x)))))
(defun (setf cdadar) (value x)
  (funcall #'(setf cdr) value (car (cdr (car x)))))
(defun (setf cdaddr) (value x)
  (funcall #'(setf cdr) value (car (cdr (cdr x)))))
(defun (setf cddaar) (value x)
  (funcall #'(setf cdr) value (cdr (car (car x)))))
(defun (setf cddadr) (value x)
  (funcall #'(setf cdr) value (cdr (car (cdr x)))))
(defun (setf cdddar) (value x)
  (funcall #'(setf cdr) value (cdr (cdr (car x)))))
(defun (setf cddddr) (value x)
  (funcall #'(setf cdr) value (cdr (cdr (cdr x)))))

(defun first (x)
  (car x))
(defun second (x)
  (car (cdr x)))
(defun third (x)
  (car (cdr (cdr x))))
(defun fourth (x)
  (car (cdr (cdr (cdr x)))))
(defun fifth (x)
  (car (cdr (cdr (cdr (cdr x))))))
(defun sixth (x)
  (car (cdr (cdr (cdr (cdr (cdr x)))))))
(defun seventh (x)
  (car (cdr (cdr (cdr (cdr (cdr (cdr x))))))))
(defun eighth (x)
  (car (cdr (cdr (cdr (cdr (cdr (cdr (cdr x)))))))))
(defun ninth (x)
  (car (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr x))))))))))
(defun tenth (x)
  (car (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr x)))))))))))
(defun (setf first) (value x)
  (funcall #'(setf car) value x))
(defun (setf second) (value x)
  (funcall #'(setf car) value (cdr x)))
(defun (setf third) (value x)
  (funcall #'(setf car) value (cdr (cdr x))))
(defun (setf fourth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr x)))))
(defun (setf fifth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr x))))))
(defun (setf sixth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr (cdr x)))))))
(defun (setf seventh) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr (cdr (cdr x))))))))
(defun (setf eighth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr (cdr (cdr (cdr x)))))))))
(defun (setf ninth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr x))))))))))
(defun (setf tenth) (value x)
  (funcall #'(setf car) value (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr (cdr x)))))))))))

(defun rest (list)
  (cdr list))
(defun (setf rest) (value list)
  (funcall #'(setf cdr) value list))

(defun rplaca (cons object)
  "Replace the car of CONS with OBJECT, returning CONS."
  (funcall #'(setf car) object cons)
  cons)
(defun rplacd (cons object)
  "Replace the cdr of CONS with OBJECT, returning CONS."
  (funcall #'(setf cdr) object cons)
  cons)

(defun atom (object)
  "Returns true if OBJECT is of type atom; otherwise, returns false."
  (not (consp object)))

(defun listp (object)
  "Returns true if OBJECT is of type (OR NULL CONS); otherwise, returns false."
  (or (null object) (consp object)))

(defun list-length (list)
  "Returns the length of LIST if list is a proper list. Returns NIL if LIST is a circular list."
  ;; Implementation from the HyperSpec
  (do ((n 0 (+ n 2))             ; Counter.
       (fast list (cddr fast))   ; Fast pointer: leaps by 2.
       (slow list (cdr slow)))   ; Slow pointer: leaps by 1.
      (nil)
    ;; If fast pointer hits the end, return the count.
    (when (endp fast) (return n))
    (when (endp (cdr fast)) (return (1+ n)))
    ;; If fast pointer eventually equals slow pointer,
    ;;  then we must be stuck in a circular list.
    (when (and (eq fast slow) (> n 0)) (return nil))))

(defun dotted-list-length (list)
  "Returns the length of LIST if list is a proper list. Returns NIL if LIST is a circular list."
  ;; Implementation from the HyperSpec
  (do ((n 0 (+ n 2))             ; Counter.
       (fast list (cddr fast))   ; Fast pointer: leaps by 2.
       (slow list (cdr slow)))   ; Slow pointer: leaps by 1.
      (nil)
    ;; If fast pointer hits the end, return the count.
    (when (atom fast) (return n))
    (when (atom (cdr fast)) (return (1+ n)))
    ;; If fast pointer eventually equals slow pointer,
    ;;  then we must be stuck in a circular list.
    (when (and (eq fast slow) (> n 0)) (return nil))))

(defun last (list)
  (do ((i list (cdr i)))
      ((null (cdr i))
       i)))

(defun butlast (list)
  (do* ((result (cons nil nil))
	(tail result (cdr tail))
	(itr list (cdr itr)))
       ((null itr)
	(cdr result))
    (funcall #'(setf cdr) (cons (car itr) nil) tail)))

(defun nthcdr (n list)
  (dotimes (i n list)
    (setq list (cdr list))))

(defun nth (n list)
  (car (nthcdr n list)))

(defun (setf nth) (value n list)
  (funcall #'(setf car) value (nthcdr n list)))

(defun append (&rest lists)
  (do* ((head (cons nil nil))
	(tail head)
	(i lists (cdr i)))
       ((null (cdr i))
	(funcall #'(setf cdr) (car i) tail)
	(cdr head))
    (dolist (elt (car i))
      (funcall #'(setf cdr) (cons elt nil) tail)
      (setq tail (cdr tail)))))

(defun nconc (&rest lists)
  (let ((start (do ((x lists (cdr x)))
		   ((or (null x) (car x)) x))))
    (when start
      (do ((list (last (car start)) (last list))
	   (i (cdr start) (cdr i)))
	  ((null (cdr i))
	   (funcall #'(setf cdr) (car i) list)
	   (car start))
	(funcall #'(setf cdr) (car i) list)))))

(defun reverse (sequence)
  (let ((result '()))
    (dolist (elt sequence result)
      (setq result (cons elt result)))))

(defun nreverse (sequence)
  (reverse sequence))

;; The following functional equivalences are true, although good implementations
;; will typically use a faster algorithm for achieving the same effect:
(defun revappend (list tail)
  (nconc (reverse list) tail))
(defun nreconc (list tail)
  (nconc (nreverse list) tail))

(defun single-mapcar (function list)
  (do* ((result (cons nil nil))
	(tail result (cdr tail))
	(itr list (cdr itr)))
       ((null itr)
	(cdr result))
    (funcall #'(setf cdr) (cons (funcall function (car itr)) nil) tail)))

(defun mapcar (function list &rest more-lists)
  (if more-lists
      (do* ((lists (cons list more-lists))
	    (result (cons nil nil))
	    (tail result (cdr tail)))
	   (nil)
	(do* ((call-list (cons nil nil))
	      (call-tail call-list (cdr call-tail))
	      (itr lists (cdr itr)))
	     ((null itr)
	      (funcall #'(setf cdr) (cons (apply function (cdr call-list)) nil) tail))
	  (when (null (car itr))
	    (return-from mapcar (cdr result)))
	  (funcall #'(setf cdr) (cons (caar itr) nil) call-tail)
	  (funcall #'(setf car) (cdar itr) itr)))
      (single-mapcar function list)))

(defun mapc (function list &rest more-lists)
  (apply 'mapcar function list more-lists)
  list)

(defun maplist (function list &rest more-lists)
  (when (null list)
    (return-from maplist nil))
  (dolist (l more-lists)
    (when (null l)
      (return-from maplist nil)))
  (do* ((lists (cons list more-lists))
	(result (cons nil nil))
	(tail result (cdr tail)))
       (nil)
    (funcall #'(setf cdr) (cons (apply function lists) nil) tail)
    (do ((itr lists (cdr itr)))
	((null itr))
      (funcall #'(setf car) (cdar itr) itr)
      (when (null (car itr))
	(return-from maplist (cdr result))))))

(defun mapcan (function list &rest more-lists)
  (do* ((lists (cons list more-lists))
	(result (cons nil nil))
	(tail result (last tail)))
       (nil)
    (do* ((call-list (cons nil nil))
	  (call-tail call-list (cdr call-tail))
	  (itr lists (cdr itr)))
	 ((null itr)
	  (funcall #'(setf cdr) (apply function (cdr call-list)) tail))
      (when (null (car itr))
	(return-from mapcan (cdr result)))
      (funcall #'(setf cdr) (cons (caar itr) nil) call-tail)
      (funcall #'(setf car) (cdar itr) itr))))

(defun getf (plist indicator &optional default)
  (do ((i plist (cddr i)))
      ((null i) default)
    (when (eq (car i) indicator)
      (return (cadr i)))))

(defun get (symbol indicator &optional default)
  (getf (symbol-plist symbol) indicator default))

;; Note - can't use setf of getf because setf hasn't been loaded yet.
(defun (setf get) (new-value symbol indicator &optional default)
  ;;(declare (ignore default))
  (do ((i (symbol-plist symbol) (cddr i)))
      ((null i)
       (funcall #'(setf symbol-plist) (list* indicator new-value (symbol-plist symbol)) symbol)
       new-value)
    (when (eq (car i) indicator)
      (funcall #'(setf cadr) new-value i)
      (return new-value))))

(declaim (inline assoc))
(defun assoc (item alist &key key test test-not)
  (when (and test test-not)
    (error "TEST and TEST-NOT specified."))
  (when test-not
    (setq test (complement test)))
  (unless test
    (setq test 'eql))
  (unless key
    (setq key 'identity))
  (dolist (i alist)
    (when (funcall test item (funcall key (car i)))
      (return i))))

(declaim (inline member))
(defun member (item list &key key test test-not)
  (when (and test test-not)
    (error "TEST and TEST-NOT specified."))
  (when test-not
    (setq test (complement test)))
  (unless test
    (setq test 'eql))
  (unless key
    (setq key 'identity))
  (do ((i list (cdr i)))
      ((endp i))
    (when (funcall test item (funcall key (car i)))
      (return i))))

(defun get-properties (plist indicator-list)
  (do ((i plist (cddr i)))
      ((null i)
       (values nil nil nil))
    (when (member (car i) indicator-list)
      (return (values (first i) (second i) i)))))

(defun list* (object &rest objects)
  (if objects
      (do* ((i objects (cdr i))
	    (result (cons object nil))
	    (tail result))
	   ((null (cdr i))
	    (setf (cdr tail) (car i))
	    result)
	(setf (cdr tail) (cons (car i) nil)
	      tail (cdr tail)))
      object))

(defun make-list (size &key initial-element)
  (unless (zerop size)
    (cons initial-element (make-list (1- size)))))
