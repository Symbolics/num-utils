;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8 -*-

(in-package #:cl-num-utils)

;;; Interface to EMAP (EMAP-DIMENSIONS also used by STACK, see default method
;;; for STACK-DIMENSIONS).  These functions need to be defined for objects
;;; that emap should understand.

(defgeneric emap-dimensions (object)
  (:documentation "Return dimensions of OBJECT, in a format that is understood
  by EMAP-UNIFY-DIMENSIONS (see its documentation).")
  (:method ((array array))
    (array-dimensions array))
  (:method ((sequence sequence))
    (list (length sequence)))
  (:method (object)
    nil))

(defgeneric emap-next (object dimensions)
  (:documentation "Return a closure that returns successive elements of
OBJECT, in row-major order.  DIMENSIONS is used for objects with adaptive
dimensions, it is by construction compatible with the dimensions returned by
EMAP-DIMENSIONS and does not need to be checked, only provided for filling in
adaptive dimensions.")
  (:method ((array array) dimensions)
    (let ((index 0))
      (lambda ()
        (prog1 (row-major-aref array index)
          (incf index)))))
  (:method ((list list) dimensions)
    (lambda ()
      (prog1 (car list)
        (setf list (cdr list)))))
  (:method ((sequence sequence) dimensions)
    (let ((index 0))
      (lambda ()
        (prog1 (nth index sequence)
          (incf index)))))
  (:method (object dimensions)
    (constantly object)))

;;; objects with adaptive dimensions

(defgeneric recycle (object specifications)
  (:documentation "Recycle OBJECT according to SPECIFICATIONS.  For use in
  calling EMAP and STACK."))

(defun vector-direction-horizontal? (direction)
  "Interpret vector direction, allowing for synonyms."
  (ecase direction
    ((:h :horizontal) t)
    ((:v :vertical) nil)))

(defstruct recycled-vector
  "A vector is repeated vertically or horizontally."
  (horizontal? nil :type symbol :read-only t)
  (vector nil :type vector :read-only t))

(defmethod recycle ((vector vector) specifications)
  (make-recycled-vector
   :horizontal? (vector-direction-horizontal? specifications)
   :vector vector))

(defmethod emap-dimensions ((rv recycled-vector))
  (bind (((:structure recycled-vector- vector horizontal?) rv)
         (length (length vector)))
    (if horizontal?
        (list nil length)
        (list length nil))))

(defmethod emap-next ((rv recycled-vector) dimensions)
  (bind (((:structure recycled-vector- vector horizontal?) rv)
         ((nil ncol) dimensions)
         (index 0))
    (if horizontal?
        (lambda ()
          (prog1 (aref vector (mod index ncol))
            (incf index)))
         (lambda ()
          (prog1 (aref vector (floor index ncol))
            (incf index))))))

;;; emap

(defun emap-unify-dimension (d1 d2)
  "Unify two dimensions, which can be positive integers or NIL."
  (cond
    ((and d1 d2)
     (assert (= d1 d2) ()
             "Dimension mismatch between ~A and ~A."
             d1 d2)
     d1)
    (d1 d1)
    (t d2)))

(defun emap-unify-dimensions (dimensions1 dimensions2)
  "Unify dimensions or signal an error.  Currently understood dimension
specifications:
  list - list of dimensions, determines rank
         each element can be NIL (flexible) or an integer
  nil - matches any rank (eg a constant)"
  (cond
    ((and dimensions1 dimensions2)
     (assert (common-length dimensions1 dimensions2) ()
             "Rank mismatch between dimensions ~A and ~A."
             dimensions1 dimensions2)
     (mapcar #'emap-unify-dimension dimensions1 dimensions2))
    (dimensions1 dimensions1)
    (t dimensions2)))



(defun emap (element-type function &rest objects)
  "Map OBJECTS elementwise using FUNCTION.  If the result is an array, it has
the given ELEMENT-TYPE."
  (bind ((dimensions (reduce #'emap-unify-dimensions objects
                             :key #'emap-dimensions))
         (next-functions (mapcar (rcurry #'emap-next dimensions) objects))
         ((:flet next-result ())
          (apply function (mapcar #'funcall next-functions))))
    (if dimensions
        (aprog1 (make-array dimensions :element-type element-type)
          (dotimes (index (array-total-size it))
            (setf (row-major-aref it index) (next-result))))
        (next-result))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro define-emap-common-numeric-type 
      (&optional (real-float-types '(single-float double-float)))
    "Given REAL-FLOAT-TYPES in order of increasing precision (this is
important), keep those which are available as array element types, and define
a lookup table and a function for determining the narrowest common numeric
type amoung floats, also allowing for complex versions of these types.  If no
such float type can be found in the list, return T."
    (let* ((real-float-types 
            (remove-if (complement #'array-element-type-available)
                       real-float-types))
           (n (length real-float-types))
           (2n (* 2 n))
           (all-float-types (concatenate 'vector real-float-types 
                                         (mapcar (curry #'list 'complex)
                                                 real-float-types)))
           (matrix (make-array (list 2n 2n) :element-type 'fixnum)))
      ;; fill matrix
      (dotimes (a 2n)
        (dotimes (b 2n)
          (bind (((:values a-complex a-i) (floor a n))
                 ((:values b-complex b-i) (floor b n)))
            (setf (aref matrix a b) (+ (* (max a-complex b-complex) n)
                                       (max a-i b-i))))))
      ;; define function
      `(defun emap-common-numeric-type (type-a type-b)
         (bind (((:flet type-id (type))
                 (cond
                   ,@(loop for id :from 0
                           for float-type :across all-float-types
                           collect `((subtypep type ',float-type) ,id))
                   ((subtypep type 'integer) :integer)
                   (t nil)))
                (a-id (type-id type-a))
                (b-id (type-id type-b))
                (float-types (load-time-value ,all-float-types))
                (matrix (load-time-value ,matrix)))
           ;; !! should be extended to handle integers, integer & float
           ;; combinations
           (if (and a-id b-id)
               (cond
                 ((and (eq a-id :integer) (eq b-id :integer))
                  (load-time-value (upgraded-array-element-type 'integer)))
                 ((eq a-id :integer) (aref float-types b-id))
                 ((eq b-id :integer) (aref float-types a-id))
                 (t (aref float-types (aref matrix a-id b-id))))
               t)))))
  (define-emap-common-numeric-type))

(defun emap-common-type (&rest objects)
  "Return the type that all OBJECTS can be coerced to."
  (reduce #'emap-common-numeric-type objects :key #'emap-type-of))

(defun emap-type-of (object)
  (typecase object
    (array (array-element-type object))
    (otherwise (type-of object))))

(defmacro define-elementwise-operation
    (function arglist docstring elementwise-function)
  "Define elementwise operation FUNCTION with ARGLIST (should be a flat list
of arguments, no optional, key, rest etc)."
  ;; !! implementation note: this is the place to optimize, not done at all at
  ;; !! the moment,
  `(defgeneric ,function ,arglist
     (:documentation ,docstring)
     (:method ,arglist
       (emap (emap-common-type ,@arglist) #',elementwise-function
             ,@arglist))))

(defmacro define-elementwise-reducing-operation
    (function bivariate-function elementwise-function documentation-verb 
     &key univariate-function)
  (check-type documentation-verb string)
  (check-types (function bivariate-function elementwise-function) symbol)
  `(progn
     (define-elementwise-operation ,bivariate-function (a b)
       ,(format nil "~:(~A~) A and B elementwise." documentation-verb)
       ,elementwise-function)
     (defun ,function (&rest objects)
       ,(format nil "~:(~A~) objects elementwise." documentation-verb)
       (assert objects () "Need at least one object.")
       (if (cdr objects)
           (reduce #',bivariate-function objects)
           ,(if univariate-function
                `(,univariate-function (car objects))
                '(car objects))))))

(define-elementwise-reducing-operation e+ e2+ + "add")
(define-elementwise-reducing-operation e* e2* * "multiply")

(define-elementwise-operation e1- (object) "Negate object elementwise." -)
(define-elementwise-reducing-operation e- e2- - "subtract"
  :univariate-function e1-)

(define-elementwise-operation e1/ (x) "Invert object elementwise." /)
(define-elementwise-reducing-operation e/ e2/ / "divide"
  :univariate-function e1/)

(define-elementwise-operation eexpt (base power) "Elementwise EXPT." expt)

(define-elementwise-operation eexp (arg) "Elementwise EXP." exp)

(define-elementwise-operation elog (arg) "Elementwise LOG." log)

(define-elementwise-operation esqrt (arg) "Elementwise SQRT." sqrt)

(define-elementwise-operation econjugate (arg)
  "Elementwise CONJUGATE." conjugate)

(defgeneric ereduce (function object &key key)
  (:documentation "Elementwise reduce, traversing in row-major order.")
  (:method (function (array array) &key key)
    (reduce function (flatten-array array) :key key))
  (:method (function (sequence sequence) &key key)
    (reduce function sequence :key key))
  (:method (function object &key key)
    (reduce function (as-array object :copy? nil) :key key)))

(defmacro define-elementwise-reduction 
    (name function 
     &optional (docstring (format nil "Elementwise ~A." function)))
  `(defun ,name (object)
     ,docstring
     (ereduce #',function object)))

(define-elementwise-reduction emax max)
(define-elementwise-reduction emin min)


;;; stack
;;; 
;;; In order to extend STACK for other objects, define methods for
;;; STACK-DIMENSIONS (or EMAP-DIMENSIONS) and STACK-INTO.

(defgeneric stack-dimensions (h? object)
  (:documentation "Return (cons unified-dimension other-dimension), where
  unified-dimension can be NIL.  If H?, stacking is horizontal, otherwise
  vertical.")
  (:method (h? (vector vector))
    (declare (ignore h?))
    (cons (length vector) 1))
  (:method (h? object)
    (aetypecase (emap-dimensions object)
      (null (cons nil 1))
      (list (bind (((nrow ncol) it))
              (if h?
                  (cons nrow ncol)
                  (cons ncol nrow)))))))

(defgeneric stack-into (object h? result cumulative-index)
  (:documentation "Used by STACK to copy OBJECT to RESULT, starting at
  CUMULATIVE-INDEX (if H?, this is the column index, otherwise the vector
  index).")
  ;; atom
  (:method (atom (h? (eql nil)) result cumulative-index)
    ;; stack vertically
    (loop
      with atom = (coerce atom (array-element-type result)) 
      for result-index from (array-row-major-index result cumulative-index 0)
      repeat (array-dimension result 1)
      do (setf (row-major-aref result result-index) atom)))
  (:method (atom (h? (eql t)) result cumulative-index)
    ;; stack horizontally
    (bind ((atom (coerce atom (array-element-type result)))
           ((nrow ncol) (array-dimensions result)))
      (loop
        for result-index :from
                         (array-row-major-index result 0 cumulative-index) 
          by ncol
        repeat nrow
        do (setf (row-major-aref result result-index) atom))))
  ;; vector
  (:method ((vector vector) (h? (eql nil)) result cumulative-index)
    ;; stack vertically
    (loop
      with element-type = (array-element-type result)
      for result-index from (array-row-major-index result cumulative-index 0)
      for v across vector
      repeat (array-dimension result 1)
      do (setf (row-major-aref result result-index) (coerce v element-type))))
  (:method ((vector vector) (h? (eql t)) result cumulative-index)
    ;; stack horizontally
    (bind ((element-type (array-element-type result))
           ((nrow ncol) (array-dimensions result)))
      (loop
        for result-index :from
                         (array-row-major-index result 0 cumulative-index) 
          by ncol
        for v across vector
        repeat nrow
        do (setf (row-major-aref result result-index)
                 (coerce v element-type)))))
  ;; array
  (:method ((array array) (h? (eql nil)) result cumulative-index)
    ;; stack vertically
    (let* ((element-type (array-element-type result)))
      (loop
        for result-index :from
                         (array-row-major-index result  cumulative-index 0)
        for array-index :from 0 :below (array-total-size array)
        do (setf (row-major-aref result result-index)
                 (coerce (row-major-aref array array-index) element-type)))))
  (:method ((array array) (h? (eql t)) result cumulative-index)
    ;; stack horizontally
    (bind ((element-type (array-element-type result))
           ((nrow ncol) (array-dimensions array))
           (offset (- (array-dimension result 1) ncol))
           (result-index (array-row-major-index result 0 cumulative-index))
           (array-index 0))
      (loop repeat nrow do
        (loop repeat ncol do
          (setf (row-major-aref result result-index)
                (coerce (row-major-aref array array-index) element-type))
          (incf result-index)
          (incf array-index))
        (incf result-index offset)))))

(defun stack (element-type direction &rest objects)
  "Stack OBJECTS into an array with given ELEMENT-TYPE (NIL means figuring out
the type automatically).  Directions can be :VERTICAL (:V)
or :HORIZONTAL (:H)."
  (declare (optimize debug))
  (let* ((h? (vector-direction-horizontal? direction))
         (dimensions (mapcar (curry #'stack-dimensions h?) objects))
         (unified-dimension (reduce #'emap-unify-dimension dimensions
                                    :key #'car))
         (other-dimension (reduce #'+ dimensions :key #'cdr))
         (element-type (aif element-type 
                            it 
                            (apply #'emap-common-type objects)))
         (result (make-array (if h?
                                 (list unified-dimension other-dimension)
                                 (list other-dimension unified-dimension))
                             :element-type element-type))
         (cumulative-index 0))
    (loop
      for object :in objects
      for dimension :in dimensions
      do (stack-into object h? result cumulative-index)
         (incf cumulative-index (cdr dimension)))
    result))
