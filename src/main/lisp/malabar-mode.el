;;; malabar-mode.el --- A better Java mode for Emacs
;;
;; Copyright (c) 2009 Espen Wiborg <espenhw@grumblesmurf.org>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301 USA.
;;
(require 'semantic-load)
(require 'semantic-ctxt)
(require 'semantic-find)
(require 'semantic-wisent)
(require 'wisent-malabar-java-wy)
(require 'cl)
(require 'thingatpt)

(require 'malabar-groovy)
(require 'malabar-annotations)
(require 'malabar-abbrevs)

(define-mode-local-override semantic-get-local-variables
  malabar-mode ()
  "Get local variable declarations from the current context."
  (let (result
        ;; Ignore funny syntax while doing this.
        semantic-unmatched-syntax-hook)
    (while (not (semantic-up-context (point) 'function))
      (save-excursion
        (forward-char 1)
        (let ((these-blocks (semantic-parse-region
                             (point)
                             (save-excursion (semantic-end-of-context) (point))
                             ;; See this production in wisent-java.wy.
                             'block_statements
                             nil t)))
          (dolist (block these-blocks)
            (when (semantic-tag-type-members block)
              (push (remove-if-not (lambda (tag)
                                     (semantic-tag-of-class-p tag 'variable))
                                   (semantic-tag-type-members block))
                    result))))))
    (apply 'append result)))

(defvar malabar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [?\C-c ?\C-v ?\C-b] 'malabar-install-project)
    (define-key map [?\C-c ?\C-v ?\C-c] 'malabar-compile-file)
    (define-key map [?\C-c ?\C-v t] 'malabar-run-test)
    (define-key map [?\C-c ?\C-v ?\C-t] 'malabar-run-junit-test-no-maven)
    (define-key map [?\C-c ?\C-v ?\C-z] 'malabar-import-one-class)
    (define-key map [?\C-c ?\C-v ?\C-o] 'malabar-override-method)
    map)
  "Keymap for Malabar mode.")

(define-derived-mode malabar-mode java-mode "malabar"
  "A new, better, Java mode."
  ;; Funky stuff here
  (add-hook 'semantic-init-hooks #'malabar-semantic-setup)
  (setq semantic-lex-depth 10)
  (setq semantic-lex-analyzer 'wisent-malabar-java-lexer)
  (wisent-malabar-java-wy--install-parser)
  ;; Set up indentation of Java annotations.
  (malabar-annotations-setup)
  (malabar-abbrevs-setup)
  )

(remove-hook 'java-mode-hook 'wisent-java-default-setup)

(defun malabar-semantic-setup ()
  ;; Nasty hardcode
  (remove-hook 'semantic-init-hooks 'malabar-semantic-setup)
  (semantic-idle-scheduler-mode 1))

(defun malabar-type-token-candidates ()
  (remove nil (mapcar (lambda (token)
                        (when (eq (car token) 'IDENTIFIER)
                          (buffer-substring-no-properties (cadr token) (cddr token))))
                      (semantic-lex-buffer 1000))))

(defun malabar-type-token-p (token)
  (let ((case-fold-search nil))
    (and (> (length token) 1)
         (some (lambda (re)
                 (string-match (concat "^" re "$") token))
               java-font-lock-extra-types))))

(defun malabar-class-defined-in-buffer-p (classname &optional buffer)
  (let ((tags (semantic-find-tags-by-class 'type (or buffer (current-buffer)))))
    (find classname tags
          :key #'semantic-tag-name
          :test #'equal)))

(defun malabar-find-imported-class (classname &optional buffer)
  (let ((tags (semantic-find-tags-by-class 'include (or buffer (current-buffer)))))
    (let ((import-tag (find classname tags
                            :key (lambda (tag)
                                   (malabar-get-package-of (semantic-tag-name tag)))
                            :test #'equal)))
      (or (and import-tag
               (semantic-tag-name import-tag))
          (malabar-find-imported-class-from-wildcard-imports classname buffer)
          (find (concat "java.lang." classname)
                (malabar-qualify-class-name classname buffer)
                :test #'equal)))))

(defun malabar-find-imported-class-from-wildcard-imports (class &optional buffer)
  (let ((tags (semantic-find-tags-by-class 'include (or buffer (current-buffer))))
        (classes (malabar-qualify-class-name class buffer)))
    (some (lambda (tag)
            (find (concat (malabar-get-package-of (semantic-tag-name tag)) "." class)
                  classes
                  :test #'equal))
          tags)))

(defun malabar-import-candidates ()
  (let ((type-tokens (remove-if-not #'malabar-type-token-p (malabar-type-token-candidates))))
    (remove-duplicates
     (remove-if (lambda (token)
                  (or (malabar-class-defined-in-buffer-p token)
                      (malabar-find-imported-class token)))
                type-tokens)
     :test #'equal)))

(defvar malabar-import-excluded-classes-regexp-list
  '("^java\\.lang\\.[^.]+$"                 ;; Always imported
    "^sun\\."                               ;; Implementation internals
    "^com\\.sun\\.xml\\.internal\\."        ;; ...
    "\\$"                                   ;; If you want to import
                                            ;; an inner class, do it
                                            ;; yourself
    ))

(defun malabar-import-current-package-p (qualified-class)
  (let ((package (malabar-get-package-name)))
    (when package
      (string-match (concat "^" (regexp-quote package) "\\.[^.]+$") qualified-class))))

(defun malabar-import-exclude (qualified-class)
  (or (some (lambda (re)
              (string-match re qualified-class))
            malabar-import-excluded-classes-regexp-list)
      (malabar-import-current-package-p qualified-class)))

(defvar malabar-import-precedence-order
  '("java.util"
    "java.io"
    "java.net"
    "java.lang.reflect"
    "java.sql"
    "java.text"
    "javax.swing")
  "Sort order by package for classes to import.  A class from a
package not in this list will sort after a class from any package
in the list")

(defun malabar-get-package-of (classname)
  (let ((lastdot (position ?. classname :from-end t)))
    (if lastdot
        (substring classname 0 lastdot)
      "")))

(defun malabar-import-sort-by-precedence (class-a class-b)
  (let ((a-package (malabar-get-package-of class-a))
        (b-package (malabar-get-package-of class-b)))
    (let ((a-package-successors (member a-package malabar-import-precedence-order))
          (b-package-successors (member b-package malabar-import-precedence-order)))
      (or (member b-package a-package-successors)
          (and a-package-successors
               (null b-package-successors))))))

(defun malabar-qualify-class-name (unqualified &optional buffer)
  (malabar-groovy-eval-and-lispeval
   (format "Project.makeProject('%s').%s.getClasses('%s')"
           (malabar-maven-find-project-file buffer)
           (malabar-classpath-of-buffer buffer)
           unqualified)))

(defun malabar-classpath-of-buffer (&optional buffer)
  (if (malabar-test-class-buffer-p (or buffer (current-buffer)))
      "testClasspath"
    "compileClasspath"))

(defun malabar-import-find-import (unqualified)
  (let* ((possible-classes
          (sort (remove-if #'malabar-import-exclude
                           (malabar-qualify-class-name unqualified))
                #'malabar-import-sort-by-precedence)))
    (when possible-classes
      (if (= 1 (length possible-classes))
          (car possible-classes)
        (malabar-choose (format "%d classes named '%s', pick one: "
                                (length possible-classes)
                                unqualified)
                        possible-classes
                        (car possible-classes))))))

(defun malabar-import-all ()
  (interactive)
  (let ((imports (remove nil
                         (mapcar #'malabar-import-find-import
                                 (malabar-import-candidates)))))
    (when imports
      (malabar-import-insert-imports imports))))

(defun malabar-import-one-class (unqualified)
  (interactive (list (read-from-minibuffer "Class: " (thing-at-point 'symbol))))
  (if (or (malabar-class-defined-in-buffer-p unqualified)
          (malabar-find-imported-class unqualified))
      (message "Class %s does not need to be imported" unqualified)
    (let ((class-to-import (malabar-import-find-import unqualified)))
      (unless (null class-to-import)
        (malabar-import-insert-imports (list class-to-import))))))

(defun malabar-choose (prompt choices &optional default)
  (let ((res (completing-read prompt (if (consp (car choices))
                                         (mapcar #'car choices)
                                       choices) nil t default)))
    (unless (equal "" res)
      (if (consp (car choices))
          (cdr (assoc res choices))
        res))))

(defun malabar-import-insert-imports (qualified-classes)
  (when qualified-classes
    (let* ((tags (semantic-fetch-tags))
           (last-import-tag (car (last (semantic-brute-find-tag-by-class 'include tags))))
           (package-tag (car (semantic-brute-find-tag-by-class 'package tags)))
           (class-tag (car (semantic-brute-find-tag-by-class 'type tags)))
           insertion-point)
      (cond (last-import-tag
             (setq insertion-point (1+ (semantic-tag-end last-import-tag))))
            (package-tag
             (save-excursion
               (goto-char (semantic-tag-end package-tag))
               (forward-line)
               (insert "\n")
               (setq insertion-point (point))))
            (class-tag
             (setq insertion-point
                   (let ((class-doc (semantic-documentation-for-tag class-tag 'lex)))
                     (if class-doc
                         (semantic-lex-token-start class-doc)
                       (semantic-tag-start class-tag)))))
            (t
             (setq insertion-point (point-min))))
      (save-excursion
        (goto-char insertion-point)
        (unless (and (bolp) (eolp))
          (insert "\n"))
        (goto-char insertion-point)
        (dolist (qualified-class qualified-classes)
          (when (> (length qualified-class) 0)
            (insert "import " qualified-class ";\n")
            (message "Imported %s" qualified-class)))))))

(defun malabar-maven-find-project-file (&optional buffer)
  (let ((dir (locate-dominating-file (buffer-file-name (or buffer (current-buffer)))
                                     "pom.xml")))
    (when dir
      (expand-file-name "pom.xml" dir))))

(defun malabar-maven-define-project (pom-file)
  (malabar-groovy-eval (format "Project.makeProject('%s')" pom-file)))

(defun malabar-make-project ()
  (let ((project-file (malabar-maven-find-project-file)))
    (when project-file
      (let ((result (malabar-maven-define-project project-file)))
        (when (equal "null" (cdr result))
          (eval (car (read-from-string (car result)))))))))

(defun malabar-build-project (goals)
  (malabar-setup-compilation-buffer)
  (display-buffer malabar-groovy-compilation-buffer-name t)
  (malabar-groovy-eval-as-compilation
   (concat (format "MvnServer.INSTANCE.run('%s', "
                   (malabar-maven-find-project-file))
           (mapconcat (lambda (s) (format "'%s'" s))
                      (if (atom goals)
                          (list goals)
                        goals)
                      ",")
           ")")))

(defvar malabar-compilation-project-file nil)

(defun malabar-setup-compilation-buffer ()
  (setq malabar-compilation-project-file (malabar-maven-find-project-file))
  (with-current-buffer (get-buffer-create malabar-groovy-compilation-buffer-name)
    (setq buffer-read-only nil)
    (buffer-disable-undo (current-buffer))
    (erase-buffer)
    (buffer-enable-undo (current-buffer))
    (compilation-mode)
    (setq buffer-read-only nil)))

(defun malabar-install-project ()
  (interactive)
  (malabar-build-project 'install))

(defun malabar-compile-file ()
  (interactive)
  (malabar-setup-compilation-buffer)
  (display-buffer malabar-groovy-compilation-buffer-name t)
  (malabar-groovy-eval-as-compilation
   (concat (format "Project.makeProject('%s').compiler.compile('%s')"
                   (malabar-maven-find-project-file)
                   (buffer-file-name (current-buffer))))))

(defun malabar-get-package-name (&optional buffer)
  (let ((package (car (semantic-brute-find-tag-by-class 'package (or buffer
                                                                     (current-buffer))))))
    (when package
      (semantic-tag-name package))))

(defun malabar-unqualified-class-name-of-buffer (&optional buffer)
  (file-name-sans-extension
   (file-name-nondirectory
    (buffer-file-name (or buffer (current-buffer))))))

(defun malabar-qualified-class-name-of-buffer (&optional buffer)
  (let ((class (malabar-unqualified-class-name-of-buffer buffer)))
    (malabar-qualify-class-name-in-buffer class buffer)))

(defun malabar-qualify-class-name-in-buffer (class &optional buffer)
  (let* ((buffer (or buffer (current-buffer)))
         (package (malabar-get-package-name buffer))
         (imported-class (malabar-find-imported-class class buffer)))
    (or imported-class
        (if package
            (concat package "." class)
          class))))

(defun malabar-test-class-buffer-p (buffer)
  (let* ((type-tag (car (semantic-brute-find-tag-by-class 'type buffer)))
         (superclasses (semantic-tag-type-superclasses type-tag)))
    (or (member "TestCase" superclasses)
        (member "junit.framework.TestCase" superclasses)
        (member "TestSuite" superclasses)
        (member "junit.framework.TestSuite" superclasses)
        (some (lambda (member-tag)
                (remove-if-not (lambda (m)
                                 (and (string= "@" (substring m 0 1))
                                      (string-ends-with m "Test")))
                               (semantic-tag-modifiers member-tag)))
              (semantic-tag-type-members type-tag)))))

(defun malabar-project-test-source-directories (project-file)
  (malabar-groovy-eval-and-lispeval
   (format "Utils.printAsLispList(Project.makeProject('%s').testSrcDirectories)"
           project-file)))

(defvar malabar-compilation-project-test-source-directories nil)

(defun malabar-class-name-to-filename (class-name)
  (concat (replace-regexp-in-string "\\." "/" class-name)
          ".java"))

(defun malabar-find-test-class-from-error ()
  (let* ((class-name (match-string-no-properties 2))
         (class-file (malabar-class-name-to-filename class-name)))
    (list
     (malabar-locate-file
      class-file
      malabar-compilation-project-test-source-directories))))

(defun malabar-locate-file (file directories)
  (locate-file file directories))

(defvar malabar-test-class-suffix "Test")

(defun malabar-corresponding-test-class-name (buffer)
  (let ((package (malabar-get-package-name buffer))
        (type-tag (car (semantic-brute-find-tag-by-class 'type buffer))))
    (let ((class (concat (semantic-tag-name type-tag) malabar-test-class-suffix)))
      (if package
          (concat package "." class)
        class))))

(defun malabar-visit-corresponding-test (&optional buffer silent)
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (if (malabar-test-class-buffer-p buffer)
        buffer
      (let ((class-file (malabar-class-name-to-filename
                         (malabar-corresponding-test-class-name buffer)))
            (test-source-directories (malabar-project-test-source-directories
                                      (malabar-maven-find-project-file buffer))))
        (funcall
         (if silent #'find-file-noselect #'find-file)
         (or (malabar-locate-file class-file test-source-directories)
             (expand-file-name class-file (car test-source-directories))))))))

(defun malabar-run-test-internal (test-starter)
  (with-current-buffer (malabar-visit-corresponding-test (current-buffer) t)
    (malabar-setup-compilation-buffer)
    (setq malabar-compilation-project-test-source-directories
          (malabar-project-test-source-directories malabar-compilation-project-file))
    (display-buffer malabar-groovy-compilation-buffer-name t)
    (malabar-groovy-eval-as-compilation
     (format test-starter
             (malabar-qualified-class-name-of-buffer (current-buffer))))))

(defun malabar-run-junit-test-no-maven ()
  (interactive)
  (malabar-run-test-internal 
   (format "Project.makeProject('%s').runJunit('%%s')"
           (malabar-maven-find-project-file))))

(defun malabar-run-test ()
  (interactive)
  (malabar-run-test-internal
   (format "Project.makeProject('%s').runtest('%%s')"
           (malabar-maven-find-project-file))))

(defvar malabar-failed-test-re "^  \\([[:alnum:]]+\\)(\\([[:alnum:].]+\\))$")

(add-to-list 'compilation-error-regexp-alist
             (list malabar-failed-test-re                ;; RE
                   'malabar-find-test-class-from-error)) ;; FILE

(defun malabar-get-members (classname &optional buffer)
  (let ((buffer (or buffer (current-buffer))))
    (malabar-groovy-eval-and-lispeval
     (format "Project.makeProject('%s').%s.getMembers('%s')"
             (malabar-maven-find-project-file buffer)
             (malabar-classpath-of-buffer buffer)
             classname))))

(defun malabar-get-abstract-members (classname)
  (remove-if-not (lambda (m)
                   (and (eq 'method (car m))
                        (member 'abstract (getf (cdr m) :modifiers))))
                 (malabar-get-members classname)))

(defun malabar-create-simplified-method-signature (method-spec)
  (assert (eq 'method (car method-spec)))
  (let* ((spec (cdr method-spec))
         (modifiers (remove 'native (remove 'abstract (getf spec :modifiers))))
         (return-type (getf spec :return-type))
         (name (getf spec :name))
         (arguments (getf spec :arguments)))
    (concat name "("
            (mapconcat (lexical-let ((counter -1))
                         (lambda (arg)
                           (or (getf arg :name)
                               (format "%s arg%s"
                                       (getf arg :type)
                                       (incf counter)))))
                       arguments
                       ", ")
            ") : " return-type
            " (" (mapconcat #'symbol-name modifiers " ") ")")))
            
(defun malabar-create-method-signature (method-spec &optional include-throws)
  (assert (eq 'method (car method-spec)))
  (let* ((spec (cdr method-spec))
         (modifiers (remove 'native (remove 'abstract (getf spec :modifiers))))
         (type-parameters (getf spec :type-parameters))
         (return-type (getf spec :return-type))
         (name (getf spec :name))
         (arguments (getf spec :arguments))
         (throws (getf spec :throws)))
    (concat (mapconcat #'symbol-name modifiers " ")
            " "
            (if type-parameters
                (concat "<" (mapconcat #'identity type-parameters ", ") "> ")
              "")
            return-type " "
            name
            "("
            (mapconcat (lexical-let ((counter -1))
                         (lambda (arg)
                           (or (getf arg :name)
                               (format "%s arg%s"
                                       (getf arg :type)
                                       (incf counter)))))
                       arguments
                       ", ")
            ")"
            (if (and throws include-throws)
                (concat " throws "
                        (mapconcat #'identity throws ", "))
              ""))))

(defun malabar-get-superclass-at-point ()
  (malabar-qualify-class-name-in-buffer
   (or (car (semantic-tag-type-superclasses (malabar-get-class-tag-at-point)))
       "Object")))

(defun malabar-override-method-make-choose-spec (method-spec)
  (cons (malabar-create-simplified-method-signature method-spec)
        method-spec))

(defun malabar-get-class-tag-at-point ()
  (or (semantic-current-tag-of-class 'type)
      (car (semantic-find-tags-by-class 'type (current-buffer)))))

(defun malabar-goto-end-of-class ()
  (interactive)
  (let ((class-tag (malabar-get-class-tag-at-point)))
    (goto-char (1- (semantic-tag-end class-tag)))))

(defun malabar-find-method-in-current-class (method-spec)
  (let ((class-tag (malabar-get-class-tag-at-point))
        (method-name (getf (cdr method-spec) :name))
        (method-argument-types
         (mapcar (lambda (arg)
                   (malabar-qualify-class-name-in-buffer (getf arg :type)))
                 (getf (cdr method-spec) :arguments))))
    (some (lambda (tag)
            (and (equal method-name
                        (semantic-tag-name tag))
                 (equal method-argument-types 
                        (mapcar (lambda (arg-tag)
                                  (malabar-qualify-class-name-in-buffer
                                   (semantic-tag-type arg-tag)))
                                (semantic-tag-function-arguments tag)))
                 tag))
          (semantic-tag-type-members class-tag))))

(defun malabar-overridable-method-p (method-spec)
  (let ((modifiers (getf (cdr method-spec) :modifiers)))
    (and (not (member 'final modifiers))
         (not (malabar-find-method-in-current-class method-spec))
         (or (member 'protected modifiers)
             (member 'public modifiers)
             (equal (malabar-get-package-name)
                    (malabar-get-package-of (getf (cdr method-spec)
                                                  :declaring-class)))))))

(defun malabar-override-method (&optional method-spec)
  (interactive)
  (let ((overridable-methods (remove-if-not (lambda (spec)
                                              (and (eq (car spec) 'method)
                                                   (malabar-overridable-method-p spec)))
                                            (malabar-get-members
                                             (malabar-get-superclass-at-point)))))
    (unless method-spec
      (setq method-spec
            (malabar-choose "Method to override: "
                            (mapcar 'malabar-override-method-make-choose-spec
                                    overridable-methods))))
    (when method-spec
      (malabar-goto-end-of-class)
      (insert "\n" "@Override\n" (malabar-create-method-signature method-spec t) " {\n"
              "// TODO: Stub\n"
              (if (equal (getf (cdr method-spec) :return-type) "void")
                  ""
                (concat "return "
                        (malabar-default-return-value (getf (cdr method-spec) :return-type))
                        ";\n"))
              "}\n")
      (forward-line -2)
      (c-indent-defun)
      (back-to-indentation)
      (let ((equals-spec (find-if (lambda (spec)
                                    (and (equal (getf (cdr spec) :name) "equals")
                                         (equal (getf (cdr spec) :declaring-class)
                                                "java.lang.Object")))
                                  overridable-methods))
            (hashcode-spec (find-if (lambda (spec)
                                      (and (equal (getf (cdr spec) :name) "hashCode")
                                           (equal (getf (cdr spec) :declaring-class)
                                                  "java.lang.Object")))
                                    overridable-methods)))
        (cond ((and (equal method-spec equals-spec)
                    hashcode-spec)
               (malabar-override-method hashcode-spec))
              ((and (equal method-spec hashcode-spec)
                    equals-spec)
               (malabar-override-method equals-spec)))))))
                              
(defun malabar-default-return-value (type)
  (cond ((member type '("byte" "short" "int" "long"))
         "-1")
        ((member type '("float" "double"))
         "-1.0")
        ((equal type "char")
         "'\\0'")
        ((equal type "boolean")
         "false")
        (t "null")))

(provide 'malabar-mode)
