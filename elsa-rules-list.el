(require 'dash)

(require 'elsa-reader)
(require 'elsa-error)
(require 'elsa-check)
(require 'elsa-scope)
(require 'elsa-state)

(defclass elsa-check-if (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-if) form scope state)
  (elsa-form-function-call-p form 'if))

(defclass elsa-check-if-useless-condition (elsa-check-if) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-if-useless-condition) form scope state)
  (or (elsa-form-function-call-p form 'if)
      (elsa-form-function-call-p form 'when)
      (elsa-form-function-call-p form 'unless)))

(cl-defmethod elsa-check-check ((_ elsa-check-if-useless-condition) form scope state)
  (let ((condition (cadr (oref form sequence))))
    (if (not (elsa-type-accept (oref condition type) (elsa-type-nil)))
        (elsa-state-add-message state
          (elsa-make-warning condition "Condition always evaluates to non-nil."))
      (when (elsa-type-accept (elsa-type-nil) (oref condition type))
        (elsa-state-add-message state
          (elsa-make-warning condition "Condition always evaluates to nil."))))))

(defclass elsa-check-if-useless-then-progn (elsa-check-if) ())

(cl-defmethod elsa-check-check ((_ elsa-check-if-useless-then-progn) form scope state)
  (let ((then-body (nth 2 (oref form sequence))))
    (when (and (eq (elsa-get-name then-body) 'progn)
               (= 2 (length (oref then-body sequence))))
      (elsa-state-add-message state
        (elsa-make-notice (elsa-car then-body) "Useless `progn' around body of then branch.")))))

(defclass elsa-check-if-useless-else-progn (elsa-check-if) ())

(cl-defmethod elsa-check-check ((_ elsa-check-if-useless-else-progn) form scope state)
  (let ((else-body (nth 3 (oref form sequence))))
    (when (eq (elsa-get-name else-body) 'progn)
      (elsa-state-add-message state
        (elsa-make-notice (elsa-car else-body) "Useless `progn' around body of else branch.")))))

(defclass elsa-check-if-to-when (elsa-check-if) ())

(cl-defmethod elsa-check-check ((_ elsa-check-if-to-when) form scope state)
  (let ((then-body (nth 2 (oref form sequence)))
        (else-body (nth 3 (oref form sequence))))
    (unless else-body
      (when (eq (elsa-get-name then-body) 'progn)
        (elsa-state-add-message state
          (elsa-make-notice (elsa-car form) "Rewrite `if' as `when' and unwrap the `progn' which is implicit."))))))

(defclass elsa-check-symbol (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-symbol) form scope state)
  (elsa-form-symbol-p form))

(defclass elsa-check-symbol-naming (elsa-check-symbol) ())

(cl-defmethod elsa-check-check ((_ elsa-check-symbol-naming) form scope state)
  (let ((name (symbol-name (elsa-get-name form))))
    (when (string-match-p ".+_" name)
      (elsa-state-add-message state
        (elsa-make-notice form "Use lisp-case for naming symbol instead of snake_case.")))
    (let ((case-fold-search nil))
      (when (string-match-p ".+[a-z][A-Z]" name)
        (elsa-state-add-message state
          (elsa-make-notice form "Use lisp-case for naming symbol instead of camelCase."))))))

(defclass elsa-check-error-message (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-error-message) form scope state)
  (elsa-form-function-call-p form 'error))

(cl-defmethod elsa-check-check ((_ elsa-check-error-message) form scope state)
  (let ((error-message (nth 1 (oref form sequence))))
    (when (elsa-form-string-p error-message)
      (let ((msg (oref error-message sequence)))
        (when (equal (substring msg -1) ".")
          (elsa-state-add-message state
            (elsa-make-notice (elsa-car form) "Error messages should not end with a period.")))
        (let ((case-fold-search nil))
          (unless (string-match-p "[A-Z]" msg)
            (elsa-state-add-message state
              (elsa-make-notice (elsa-car form) "Error messages should start with a capital letter."))))))))

(defclass elsa-check-unbound-variable (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-unbound-variable) form scope state)
  (and (elsa-form-symbol-p form)
       (not (elsa-form-keyword-p form))))

(cl-defmethod elsa-check-check ((_ elsa-check-unbound-variable) form scope state)
  (let* ((name (elsa-get-name form))
         (var (elsa-scope-get-var scope name)))
    (unless (or (eq name 't)
                (eq name 'nil)
                var
                ;; global variable defined in emacs core as a `defvar'
                ;; FIXME: this actually includes the variables bound
                ;; during analysis, so this is not the proper way to
                ;; check.
                (get name 'elsa-type-var)
                (boundp name))
      (elsa-state-add-message state
        (elsa-make-error form
          "Reference to free variable `%s'." (symbol-name name))))))

(defclass elsa-check-cond-useless-condition (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-cond-useless-condition) form scope state)
  (elsa-form-function-call-p form 'cond))

(cl-defmethod elsa-check-check ((_ elsa-check-cond-useless-condition) form scope state)
  (let* ((branches (cdr (oref form sequence)))
         (total (length branches)))
    (-each-indexed branches
      (lambda (index branch)
        (-when-let* ((sequence (elsa-form-sequence branch))
                     (first-item (-first-item sequence)))
          (if (and (not (elsa-type-accept (oref first-item type) (elsa-type-nil)))
                   (< index (1- total)))
              (elsa-state-add-message state
                (elsa-make-warning first-item "Condition always evaluates to non-nil."))
            (when (elsa-type-accept (elsa-type-nil) (oref first-item type))
              (elsa-state-add-message state
                (elsa-make-warning first-item "Condition always evaluates to nil.")))))))))

(defclass elsa-check-lambda-eta-conversion (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-lambda-eta-conversion) form scope state)
  (elsa-form-function-call-p form 'lambda))

(cl-defmethod elsa-check-check ((_ elsa-check-lambda-eta-conversion) form scope state)
  (let* ((seq (oref form sequence))
         (arg-list (elsa-form-sequence (nth 1 seq)))
         (body (nthcdr 2 seq)))
    (when (= 1 (length body))
      (let ((fn-form (car body)))
        (when (elsa-form-list-p fn-form)
          (let ((fn-args (cdr (elsa-form-sequence fn-form))))
            (when (and (= (length arg-list) (length fn-args))
                       (-all-p
                        (-lambda ((lambda-arg . fn-arg))
                          (and (elsa-form-symbol-p fn-arg)
                               (eq (elsa-get-name lambda-arg)
                                   (elsa-get-name fn-arg))))
                        (-zip arg-list fn-args)))
              (elsa-state-add-message state
                (elsa-make-notice (elsa-car form)
                  "You can eta convert the lambda form and use the function `%s' directly"
                  (symbol-name (elsa-get-name fn-form)))))))))))

(defclass elsa-check-or-unreachable-code (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-or-unreachable-code) form scope state)
  (elsa-form-function-call-p form 'or))

(cl-defmethod elsa-check-check ((_ elsa-check-or-unreachable-code) form scope state)
  (let ((args (elsa-cdr form))
        (can-be-nil-p t))
    (-each args
      (lambda (condition)
        (if (not can-be-nil-p)
            (elsa-state-add-message state
              (elsa-make-warning condition "Unreachable expression"))
          (if (not (elsa-type-accept (oref condition type) (elsa-type-nil)))
              (when can-be-nil-p (setq can-be-nil-p nil))
            (when (and (elsa-type-accept (elsa-type-nil) (oref condition type))
                       can-be-nil-p)
              (elsa-state-add-message state
                (elsa-make-warning condition "Condition always evaluates to nil.")))))))))

(defclass elsa-check-public-functions-have-docstring (elsa-check) ())

(cl-defmethod elsa-check-should-run ((_ elsa-check-public-functions-have-docstring) form scope state)
  (and (or (elsa-form-function-call-p form 'defun)
           (elsa-form-function-call-p form 'defmacro)
           (elsa-form-function-call-p form 'cl-defgeneric)
           (elsa-form-function-call-p form 'defsubst))
       (not (string-match-p "--" (symbol-name (elsa-get-name (elsa-nth 1 form)))))))

(cl-defmethod elsa-check-check ((_ elsa-check-public-functions-have-docstring) form scope state)
  (let ((docstring-maybe (elsa-nth 3 form)))
    (unless (elsa-form-string-p docstring-maybe)
      (elsa-state-add-message state
        (elsa-make-notice (elsa-car form) "Public functions should have a docstring.")))))

(provide 'elsa-rules-list)
