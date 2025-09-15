;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((indent-tabs-mode . nil)
         (fill-column . 72)))

 (""   . ((eval . (git-commit-mode-setup)))) ; Auto-setup commit message template

 (sh-mode . ((flycheck-checker . 'sh-shellcheck)
             (sh-basic-offset . 2)
             (sh-indentation . 2)))

 (org-mode . ((org-confirm-babel-evaluate . nil))))
