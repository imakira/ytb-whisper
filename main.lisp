#!/usr/bin/env -S sbcl --script 

(require :asdf)
(eval-when 
    (:compile-toplevel  
     :load-toplevel                                             
     :execute)          
  (declaim (optimize (speed 0) (space 0) (debug 3)))
  (load (sb-ext:posix-getenv "ASDF"))
  (let ((*error-output* (make-broadcast-stream)))
    (asdf:load-system :defmain :verbose nil)
    (asdf:load-system :alexandria)
    (asdf:load-system :arrow-macros)
    (asdf:load-system :serapeum)))

(defpackage :ytb-whisper
  (:use :cl :alexandria :arrow-macros)
  (:local-nicknames  (:sp :serapeum)))

(in-package :ytb-whisper)

(defparameter *tmp-dir* "/tmp/ytp-whisper")

(defun assert-true (value message)
  (when (not value)
    (uiop:println message *error-output*)
    (uiop:quit 1)))

(defun quote-arg (str)
  (sp:concat "'" (sp:string-replace-all "'" str "'\\''")
             "'"))

(defun shell (command &rest args)
  (let* ((args (concatenate 'list
                            (list
                             :wait nil
                             :error
                             (if (eq (getf args :error)
                                     t)
                                 *error-output*
                                 (or (getf args :error) *error-output*)) 
                             :output
                             (if (eq (getf args :output)
                                     t)
                                 *standard-output*
                                 (or (getf args :output) *standard-output*)))
                            args))
         (proc (apply #'sb-ext:run-program "/usr/bin/env" (list "bash" "-c" command)
                      args)))
    (unwind-protect (sb-ext:process-wait proc)
      (when (sb-ext:process-alive-p proc)
        (sb-ext:process-kill proc 2)))
    (when (not (= (sb-ext:process-exit-code proc)
                  0))
      (error "Process exit with non zero code"))
    proc))

(defun shell-to-string (command &rest args)
  (sp:trim-whitespace (with-output-to-string (out)
                        (apply #'shell command :output out args))))

(defun path-basename (pathname)
  (last-elt (split-sequence:split-sequence #\/ pathname)))

(defun exe-exist? (exe)
  (not (emptyp (shell-to-string (sp:concat "command -v " exe)))))

(defun download-video (url)
  (shell-to-string (sp:string-join
                    (list "yt-dlp --print after_move:filepath \\"
                          "--embed-thumbnail \\"
                          "--quiet \\"
                          "--no-simulate \\"
                          "--embed-chapters \\"
                          url)
                    #\newline)))

(defun generate-subtitle (whisper tmp-audio-path subtitle-path model lang)
  (shell (sp:concat whisper " -m " model " "
                    (quote-arg tmp-audio-path)
                    " -osrt " (quote-arg subtitle-path) " "
                    " -l " lang
                    " -t " (prin1-to-string (min (ceiling (sp:count-cpus :online t) 4)
                                                 4))))
  (shell (format nil "mv ~A ~A"
                 (quote-arg (sp:concat tmp-audio-path ".srt"))
                 (quote-arg subtitle-path))))

(defun -main (model lang whisper url)
  (let* ((video-path (download-video url))
         (tmp-audio-path (sp:concat
                          *tmp-dir*
                          "/"
                          (path-basename video-path)
                          ".wav"))
         (subtitle-path (sp:concat
                         video-path
                         ".srt")))
    (when (not (uiop:directory-exists-p *tmp-dir*))
      (shell (serapeum:concat "mkdir " *tmp-dir*)))
    (shell (format nil "ffmpeg -y -i ~A -acodec pcm_s16le -ac 1 -ar 16000 ~A"
                   (quote-arg video-path)
                   (quote-arg tmp-audio-path)))
    (generate-subtitle whisper tmp-audio-path subtitle-path model lang)
    (shell (sp:concat "vlc --sub-file "
                      (quote-arg subtitle-path)
                      " "
                      (quote-arg video-path)))))

(defmain:defmain (main) ((model "Path to the model file"
                                :short "m")
                         (lang "Language for the video"
                               :short "l"
                               :default "auto")
                         (whisper "Path to whisper.cpp executable"
                                  :short "w"
                                  :default (or (uiop:getenv "WHISPER_CPP") "whisper-cpp"))
                         &rest rest)
  (let ((model (or model (uiop:getenv "WHISPER_MODEL"))))
    (let ((url (first rest)))
      (cond ((not url)
             (defmain:print-help))
            (t
             (assert-true (and model (uiop:file-exists-p model))
                          "model path lacking or model file doesn't exist")
             (assert-true (exe-exist? "ffmpeg")
                          "ffmeg isn't installed or can't be found")
             (assert-true (exe-exist? "yt-dlp")
                          "yt-dlp isn't installed or can't be found")
             (assert-true (exe-exist? whisper)
                          "whisper.cpp isn't installed or can't be found")
             (-main model lang whisper url))))))

(apply #'main uiop:*command-line-arguments*)
