;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8 -*-

(in-package #:cl-num-utils)

(defclass ix ()
  ((keys :reader ix-keys :initarg :keys)
   (cum-indexes :initarg :cum-indexes)
   (specs :reader ix-specs :initarg :specs)))

(defun ix-size (ix)
  "Number of elements addressed by an IX specification."
  (etypecase ix
    (null 1)
    (fixnum ix)
    (vector (reduce #'* ix))
    (ix (with-slots (cum-indexes) ix
          (aref cum-indexes (1- (length cum-indexes)))))))

(defmethod print-object ((ix ix) stream)
  (labels ((spec->list (key spec)
             (etypecase spec
               (null key)
               ((or fixnum vector) (list key spec))
               (ix (list key (ix->list spec)))))
           (ix->list (ix)
             (map 'list #'spec->list (ix-keys ix) (ix-specs ix))))
    (print-unreadable-object (ix stream :type t)
      (princ (ix->list ix) stream))))

(defun make-ix (key-spec-pairs)
  "Create index.  KEY-SPEC-PAIRS is a list of the following: KEY for
singletons, (KEY LENGTH) or (KEY DIMENSIONS-VECTOR) for vector or
row-major-array indexing, (KEY IX-INSTANCE), or a list of these which
is interpreted recursively."
  (iter
    (with cum-index := 0)
    (for key-spec :in key-spec-pairs)
    (bind (((:values key spec)
            (if (atom key-spec)
                (progn
                  (check-type key-spec symbol)
                  (values key-spec nil 1))
                (bind (((key spec) key-spec))
                  (check-type key symbol)
                  (values key
                          (typecase spec
                            (fixnum spec)
                            (vector (coerce spec 'simple-fixnum-vector))
                            (ix spec)
                            (list (make-ix spec)))))))
           (size (ix-size spec)))
      (collecting key :into keys :result-type vector)
      (collecting spec :into specs :result-type vector)
      (when (first-iteration-p)
        (collecting 0 :into cum-indexes :result-type simple-fixnum-vector))
      (incf cum-index size))
      (collecting cum-index :into cum-indexes :result-type simple-fixnum-vector)
    (finally
     (return (make-instance 'ix :specs specs :cum-indexes cum-indexes :keys keys)))))

(defun ix (ix &rest keys-and-indexes)
  "Resolve KEYS-AND-INDEXES in IX.  Return either a range
specification (eg (CONS START END)) or a single index."
  (labels ((resolve (ix keys-and-indexes acc)
             (etypecase ix
               (null
                  (assert (null keys-and-indexes))
                  acc)
               (fixnum
                  (if keys-and-indexes
                      (bind (((key) keys-and-indexes))
                        (assert (within? 0 key ix))
                        (+ acc key))
                      (cons acc (+ acc ix))))
               (vector
                  (error "not implemented yet"))
               (ix
                  (if keys-and-indexes
                      (bind (((:slots-r/o keys cum-indexes specs) ix)
                             ((key . rest) keys-and-indexes)
                             (position (position key keys :test #'eq)))
                        (resolve (aref specs position) rest 
                                 (+ acc (aref cum-indexes position))))
                      (cons acc (+ acc (ix-size ix))))))))
    (resolve ix keys-and-indexes 0)))

;; (defparameter *ix* (make-ix '((foo 3) (bar 8) baz)))
;; (ix *ix* 'foo)
;; (ix *ix* 'bar 4)
;; (ix *ix* 'baz)
