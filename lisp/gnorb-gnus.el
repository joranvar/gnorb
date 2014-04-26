;;; gnorb-gnus.el --- The gnus-centric fuctions of gnorb

;; Copyright (C) 2014  Eric Abrahamsen

;; Author: Eric Abrahamsen <eric@ericabrahamsen.net>
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; 

;;; Code:

(require 'gnorb-utils)

(defgroup gnorb-gnus nil
  "The Gnus bits of Gnorb."
  :tag "Gnorb Gnus"
  :group 'gnorb)


(defcustom gnorb-gnus-mail-search-backends
  '((notmuch (lambda (terms)
	       (mapconcat
		(lambda (m)
		  (replace-regexp-in-string "\\." "\\\\." m))
		terms " OR "))
	     notmuch-search)
    (mairix (lambda (terms)
	      (mapconcat 'identity
			 terms ","))
	    mairix-search)
    (namazu (lambda (terms)
	      (mapconcat 'identity
			 terms " or "))
	    namazu-search))
  "Various backends for mail search.

An alist of backends, where each element consists of three parts:
the symbol name of the backend, a lambda form which receives a
list of email addresses and returns a properly-formatted search
string, and the symbol name of the function used to initiate the
search."
  :group 'gnorb-bbdb
  :type 'list)

(defcustom gnorb-gnus-mail-search-backend nil
  "Mail search backend currently in use."
  :group 'gnorb-bbdb
  :type 'symbol)

(defcustom gnorb-gnus-capture-always-attach nil
  "Always prompt about attaching attachments when capturing from
  a Gnus message, even if the template being used hasn't
  specified the :gnus-attachments key.

Basically behave as if all attachments have \":gnus-attachments t\".")

;;; What follows is a very careful copy-pasta of bits and pieces from
;;; mm-decode.el and gnus-art.el. Voodoo was involved.

(defvar gnorb-gnus-capture-attachments nil
  "Holding place for attachment names during the capture
  process.")

(defun gnorb-gnus-article-org-attach (n)
  "Save MIME part N, which is the numerical prefix, of the
  article under point as an attachment to the specified org
  heading."
  (interactive "P")
  (gnus-article-part-wrapper n 'gnorb-gnus-attach-part))

(defun gnorb-gnus-mime-org-attach ()
  "Save the MIME part under point as an attachment to the
  specified org heading."
  (interactive)
  (gnus-article-check-buffer)
  (let ((data (get-text-property (point) 'gnus-data)))
    (when data
      (gnorb-gnus-attach-part data))))

(defun gnorb-gnus-attach-part (handle &optional org-heading)
  "Attach HANDLE to an existing org heading."
  (let ((filename (gnorb-gnus-save-part handle))
	(org-heading (or org-heading
			 (org-refile-get-location "Attach part to" nil t))))
    (require 'org-attach)
    (save-window-excursion
      (find-file (nth 1 org-heading))
      (goto-char (nth 3 org-heading))
      (org-attach-attach filename nil 'mv))))

(defun gnorb-gnus-save-part (handle)
  (let ((filename (or (mail-content-type-get
		       (mm-handle-disposition handle) 'filename)
		      (mail-content-type-get
		       (mm-handle-type handle) 'name))))
    (setq filename
	  (gnus-map-function mm-file-name-rewrite-functions
			     (file-name-nondirectory filename)))
    (setq filename (expand-file-name filename gnorb-tmp-dir))
    (mm-save-part-to-file handle filename)
    filename))

(defun gnorb-gnus-collect-all-attachments (&optional capture-p)
  "Collect all the attachments from the message under point, and
save them into `gnorb-tmp-dir'."
  (save-window-excursion
    (when capture-p
      (set-buffer (org-capture-get :original-buffer)))
    (unless (memq major-mode '(gnus-summary-mode gnus-article-mode))
	(error "Only works in Gnus summary or article buffers"))
    (let ((article (gnus-summary-article-number)) 
	  mime-handles)
      (when (or (null gnus-current-article)
		(null gnus-article-current)
		(/= article (cdr gnus-article-current))
		(not (equal (car gnus-article-current) gnus-newsgroup-name)))
	(gnus-summary-display-article article))
      (gnus-eval-in-buffer-window gnus-article-buffer
	(setq mime-handles (cl-remove-if-not
			    (lambda (h) (equal "attachment" (car (nth 5 h))))
			    gnus-article-mime-handle-alist) ))
      (when mime-handles
	(dolist (h mime-handles)
	  (let ((filename
		 (gnorb-gnus-save-part (cdr h))))
	    (when capture-p
	      (push filename gnorb-gnus-capture-attachments))))))))

;;; Make the above work in the capture process

(defun gnorb-gnus-capture-attach ()
  (when (and (or gnorb-gnus-capture-always-attach
		 (org-capture-get :gnus-attachments))
	     (with-current-buffer
		 (org-capture-get :original-buffer)
	       (memq major-mode '(gnus-summary-mode gnus-article-mode))))
    (require 'org-attach)
    (setq gnorb-gnus-capture-attachments nil)
    (gnorb-gnus-collect-all-attachments t)
    (map-y-or-n-p
     (lambda (a)
       (format "Attach %s to capture heading? "
	       (file-name-nondirectory a)))
     (lambda (a) (org-attach-attach a nil 'mv))
     gnorb-gnus-capture-attachments
     '("file" "files" "attach"))))

(add-hook 'org-capture-mode-hook 'gnorb-gnus-capture-attach)

(defun gnorb-gnus-capture-abort-cleanup ()
  (when (and org-note-abort
	     (org-capture-get :gnus-attachments))
    (condition-case error
	(progn (org-attach-delete-all)
	       (setq abort-note 'clean))
      ((error
	(setq abort-note 'dirty))))))

(add-hook 'org-capture-prepare-finalize-hook
	  'gnorb-gnus-capture-abort-cleanup)

;;; Storing, removing, and acting on Org headers in messages.

(defcustom gnorb-gnus-org-header "X-Org-ID"
  "Name of the mail header used to store the ID of a related Org
  heading. Only used locally: always stripped when the mail is
  sent."
  :group 'gnorb-gnus
  :type 'string)

;;; this is just ghastly, but the value of this var is single regexp
;;; group containing various header names, and we want our value
;;; inside that group.
(eval-after-load "message"
  (let ((ign-headers-list
	 (org-split-string message-ignored-mail-headers
			   "|"))
	(our-val (concat gnorb-org-mail-header "\\")))
    (unless (member our-val ign-headers-list)
      (setq ign-headers-list
	    `(,@(butlast ign-headers-list 1) ,our-val
	      ,@(last ign-headers-list 1)))
      (setq message-ignored-mail-headers
	    (mapconcat
	     'identity ign-headers-list "|")))))

(defun gnorb-gnus-check-org-header ()
  "Return the value of the `gnorb-gnus-org-header' for the
current message; multiple header values returned as a string."
  (save-restriction
    (message-narrow-to-headers)
    (let ((org-ids (mail-fetch-field gnorb-gnus-org-header nil nil t)))
      (if org-ids
	  (setq gnorb-message-org-ids org-ids)
	(setq gnorb-message-org-ids nil)))))

(add-hook 'message-send-hook 'gnorb-gnus-check-org-header)

(provide 'gnorb-gnus)
;;; gnorb-gnus.el ends here
