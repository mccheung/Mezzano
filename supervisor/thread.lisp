;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

(defvar *global-thread-lock* nil
  "This lock protects the special variables that make up the thread list and run queues.")
(defvar *thread-run-queue-head*)
(defvar *thread-run-queue-tail*)
(defvar *low-priority-thread-run-queue-head*)
(defvar *low-priority-thread-run-queue-tail*)
(defvar *all-threads*)

(defvar *world-stop-lock*)
(defvar *world-stop-cvar*)
(defvar *world-stop-pending*)
(defvar *world-stopper*)
(defvar *pseudo-atomic-thread-count*)

(defvar *pseudo-atomic* nil)

;; FIXME: There must be one idle thread per cpu.
;; The cold-generator creates an idle thread for the BSP.
(defvar sys.int::*bsp-idle-thread*)

(deftype thread ()
  `(satisfies threadp))

(defun threadp (object)
  (sys.int::%object-of-type-p object sys.int::+object-tag-thread+))

;;; Thread locking.
;;;
;;; Each thread has a per-thread spinlock (the thread-lock field), and there is the *GLOBAL-THREAD-LOCK*.

(macrolet ((field (name offset &key (type 't) (accessor 'sys.int::%object-ref-t))
             (let ((field-name (intern (format nil "+THREAD-~A+" (symbol-name name))
                                       (symbol-package name)))
                   (accessor-name (intern (format nil "THREAD-~A" (symbol-name name))
                                          (symbol-package name))))
               `(progn
                  (defconstant ,field-name ,offset)
                  (defun ,accessor-name (thread)
                    (check-type thread thread)
                    (,accessor thread ,field-name))
                  (defun (setf ,accessor-name) (value thread)
                    (check-type thread thread)
                    ,@(when (not (eql type 't))
                        `((check-type value ,type)))
                    (setf (,accessor thread ,field-name) value)))))
          (reg-field (name offset)
            (let ((state-name (intern (format nil "STATE-~A" name) (symbol-package name)))
                  (state-name-value (intern (format nil "STATE-~A-VALUE" name) (symbol-package name))))
              `(progn
                 (field ,state-name ,offset :accessor sys.int::%object-ref-signed-byte-64)
                 (field ,state-name-value ,offset :accessor sys.int::%object-ref-t)))))
  ;; The name of the thread, a string.
  (field name                     0 :type string)
  ;; Current state.
  ;;   :active    - the thread is currently running on a core.
  ;;   :runnable  - the thread can be run, but is not currently running.
  ;;   :sleeping  - the thread is waiting for an event and cannot run.
  ;;   :dead      - the thread has exited or been killed and cannot run.
  ;;   :waiting-for-page - the thread is waiting for memory to be paged in.
  ;;   :pager-request - the thread is waiting for a pager RPC call to complete.
  (field state                    1 :type (member :active :runnable :sleeping :dead :waiting-for-page :pager-request))
  ;; Spinlock protecting access to the thread.
  (field lock                     2)
  ;; Stack object for the stack.
  (field stack                    3)
  ;; 4 - magic field used by bootloader.
  ;; If a thread is sleeping, waiting for page or performing a pager-request, this will describe what it's waiting for.
  ;; When waiting for paging to complete, this will be the faulting address.
  ;; When waiting for a pager-request, this will be the called function.
  (field wait-item                5)
  ;; The thread's current special stack pointer.
  ;; Note! The compiler must be updated if this changes and all code rebuilt.
  (field special-stack-pointer    6)
  ;; When true, all registers are saved in the the thread's state save area.
  ;; When false, only the stack pointer and frame pointer are valid.
  (field full-save-p              7)
  ;; The thread object, used to make CURRENT-THREAD fast.
  (field self                     8)
  ;; Next/previous links for run queues and wait queues.
  (field %next                    9)
  (field %prev                   10)
  ;; A list of foothold functions that need to be run.
  (field pending-footholds       11)
  ;; A non-negative fixnum, when 0 footholds are permitted to run.
  ;; When positive, they are deferred.
  (field inhibit-footholds       12)
  (field mutex-stack             13)
  ;; Next/previous links for the *all-threads* list.
  ;; This only contains live (not state = :dead) threads.
  (field global-next             14)
  (field global-prev             15)
  ;; Thread's priority, can be either :normal or :low.
  ;; The pager, disk io, and thread currently stopping the world all
  ;; have higher-than-:normal priority, no matter what the priority field contains.
  (field priority                16 :type (member :low :normal))
  ;; Arguments passed to the pager when performing an RPC.
  (field pager-argument-1        17)
  (field pager-argument-2        18)
  (field pager-argument-3        19)
  ;; Table of active breakpoints.
  (field breakpoint-table        20)
  ;; Sorted simple-vector of breakpoint addresses, used when the thread is running in software-breakpoint mode.
  (field software-breakpoints    21)
  ;; Symbol binding cache hit count.
  (field symbol-cache-hit-count  22)
  ;; Symbol binding cache miss count.
  (field symbol-cache-miss-count 23)
  ;; 24-32 - free
  ;; 32-127 MV slots
  ;;    Slots used as part of the multiple-value return convention.
  ;;    Note! The compiler must be updated if this changes and all code rebuilt.
  (defconstant +thread-mv-slots-start+ 32)
  (defconstant +thread-mv-slots-end+ 128)
  ;; 128-256 Symbol binding cell cache.
  (defconstant +thread-symbol-cache-start+ 128)
  (defconstant +thread-symbol-cache-end+ 256)
  ;; 256-426 free
  ;; 427-446 State save area.
  ;;    Used to save an interrupt frame when the thread has stopped to wait for a page.
  ;;    The registers are saved here, not on the stack, because the stack may not be paged in.
  ;;    This has the same layout as an interrupt frame.
  ;; 447-510 FXSAVE area
  ;;    Unboxed area where the FPU/SSE state is saved.
  (defconstant +thread-interrupt-save-area+ 427)
  (defconstant +thread-fx-save-area+ 447)
  (reg-field r15                427)
  (reg-field r14                428)
  (reg-field r13                429)
  (reg-field r12                430)
  (reg-field r11                431)
  (reg-field r10                432)
  (reg-field r9                 433)
  (reg-field r8                 434)
  (reg-field rdi                435)
  (reg-field rsi                436)
  (reg-field rbx                437)
  (reg-field rdx                438)
  (reg-field rcx                439)
  (reg-field rax                440)
  (reg-field rbp                441)
  (reg-field rip                442)
  (reg-field cs                 443)
  (reg-field rflags             444)
  (reg-field rsp                445)
  (reg-field ss                 446))

;;; Aliases for a few registers.

(defun thread-frame-pointer (thread)
  (thread-state-rbp thread))

(defun (setf thread-frame-pointer) (value thread)
  (setf (thread-state-rbp thread) value))

(defun thread-stack-pointer (thread)
  (thread-state-rsp thread))

(defun (setf thread-stack-pointer) (value thread)
  (setf (thread-state-rsp thread) value))

;;; Locking macros.

(defmacro with-global-thread-lock ((&optional) &body body)
  `(with-symbol-spinlock (*global-thread-lock*)
     ,@body))

(defmacro with-thread-lock ((thread) &body body)
  (let ((sym (gensym "thread")))
    `(let ((,sym ,thread))
       (unwind-protect
            (progn
              (%lock-thread ,sym)
              ,@body)
         (%unlock-thread ,sym)))))

(defun %lock-thread (thread)
  (check-type thread thread)
  (ensure-interrupts-disabled)
  (let ((current-thread (current-thread)))
    (do ()
        ((sys.int::%cas-object thread
                               +thread-lock+
                               :unlocked
                               current-thread))
      (panic "thread lock " thread " held by " (sys.int::%object-ref-t thread +thread-lock+))
      (sys.int::cpu-relax))))

(defun %unlock-thread (thread)
  (assert (eql (sys.int::%object-ref-t thread +thread-lock+)
               (current-thread)))
  (setf (sys.int::%object-ref-t thread +thread-lock+) :unlocked))

;;; Run queue management.

(defun push-run-queue-1 (thread head tail)
  (cond ((null (sys.int::symbol-global-value head))
         (setf (sys.int::symbol-global-value head) thread
               (sys.int::symbol-global-value tail) thread)
         (setf (thread-%next thread) nil
               (thread-%prev thread) nil))
        (t
         (setf (thread-%next (sys.int::symbol-global-value tail)) thread
               (thread-%prev thread) (sys.int::symbol-global-value tail)
               (thread-%next thread) nil
               (sys.int::symbol-global-value tail) thread))))

(defun push-run-queue (thread)
  (when (or (eql thread (sys.int::symbol-global-value '*world-stopper*))
            (eql thread (sys.int::symbol-global-value 'sys.int::*pager-thread*))
            (eql thread (sys.int::symbol-global-value 'sys.int::*disk-io-thread*)))
    (return-from push-run-queue))
  (ecase (thread-priority thread)
    (:normal
     (push-run-queue-1 thread
                       '*thread-run-queue-head*
                       '*thread-run-queue-tail*))
    (:low
     (push-run-queue-1 thread
                       '*low-priority-thread-run-queue-head*
                       '*low-priority-thread-run-queue-tail*))))

(defun pop-run-queue-1 (head tail)
  (let ((thread (sys.int::symbol-global-value head)))
    (when thread
      (cond ((thread-%next (sys.int::symbol-global-value head))
             (setf (thread-%prev (thread-%next (sys.int::symbol-global-value head))) nil)
             (setf (sys.int::symbol-global-value head) (thread-%next (sys.int::symbol-global-value head))))
            (t
             (setf (sys.int::symbol-global-value head) nil
                   (sys.int::symbol-global-value tail) nil)))
      thread)))

(defun pop-run-queue ()
  (or (pop-run-queue-1 '*thread-run-queue-head* '*thread-run-queue-tail*)
      (pop-run-queue-1 '*low-priority-thread-run-queue-head* '*low-priority-thread-run-queue-tail*)))

(defun %update-run-queue ()
  "Possibly return the current thread to the run queue, and
return the next thread to run.
Interrupts must be off, the current thread must be locked."
  (let ((current (current-thread)))
    (with-symbol-spinlock (*global-thread-lock*)
      (cond ((sys.int::symbol-global-value '*world-stopper*)
             ;; World is stopped, the only runnable threads are
             ;; the pager, the disk io thread, the idle thread and the world stopper.
             (unless (or (eql current (sys.int::symbol-global-value '*world-stopper*))
                         (eql current (sys.int::symbol-global-value 'sys.int::*pager-thread*))
                         (eql current (sys.int::symbol-global-value 'sys.int::*disk-io-thread*)))
               (panic "Aiee. %UPDATE-RUN-QUEUE called with bad thread " current))
             (cond ((eql (thread-state (sys.int::symbol-global-value 'sys.int::*pager-thread*)) :runnable)
                    ;; Pager is ready to run.
                    (sys.int::symbol-global-value 'sys.int::*pager-thread*))
                   ((eql (thread-state (sys.int::symbol-global-value 'sys.int::*disk-io-thread*)) :runnable)
                    ;; Disk IO is ready to run.
                    (sys.int::symbol-global-value 'sys.int::*disk-io-thread*))
                   ((eql (thread-state (sys.int::symbol-global-value '*world-stopper*)) :runnable)
                    ;; The world stopper is ready.
                    (sys.int::symbol-global-value '*world-stopper*))
                   (t ;; Switch to idle.
                    (sys.int::symbol-global-value 'sys.int::*bsp-idle-thread*))))
            (t ;; Return the current thread to the run queue and fetch the next thread.
             (when (eql current (sys.int::symbol-global-value 'sys.int::*bsp-idle-thread*))
               (panic "Aiee. Idle thread called %UPDATE-RUN-QUEUE."))
             (when (eql (thread-state current) :runnable)
               (push-run-queue current))
             (or (when (eql (thread-state (sys.int::symbol-global-value 'sys.int::*pager-thread*)) :runnable)
                   ;; Pager is ready to run.
                   (sys.int::symbol-global-value 'sys.int::*pager-thread*))
                 (when (eql (thread-state (sys.int::symbol-global-value 'sys.int::*disk-io-thread*)) :runnable)
                   ;; Disk IO is ready to run.
                   (sys.int::symbol-global-value 'sys.int::*disk-io-thread*))
                 ;; Try taking from the run queue.
                 (pop-run-queue)
                 ;; Fall back on idle.
                 (sys.int::symbol-global-value 'sys.int::*bsp-idle-thread*)))))))

;;; Thread switching.

(defun thread-yield ()
  "Call this to give up the remainder of the current thread's timeslice and possibly switch to another runnable thread."
  (%run-on-wired-stack-without-interrupts (sp fp)
   (let ((current (current-thread)))
     (%lock-thread current)
     (setf (thread-state current) :runnable)
     (%reschedule-via-wired-stack sp fp))))

(defun %reschedule-via-wired-stack (sp fp)
  ;; Switch to the next thread saving minimal state.
  ;; Interrupts must be off and the current thread's lock must be held.
  ;; Releases the thread lock and reenables interrupts.
  (let ((current (current-thread))
        (next (%update-run-queue)))
    ;; todo: reset preemption timer here.
    (when (eql next current)
      ;; Staying on the same thread, unlock and return.
      (%unlock-thread current)
      (%%return-to-same-thread sp fp)
      (panic "unreachable"))
    (when (<= sys.int::*exception-stack-base*
              (thread-stack-pointer next)
              (1- sys.int::*exception-stack-size*))
      (panic "Other thread " next " stopped on exception stack!!!"))
    (%lock-thread next)
    (setf (thread-state next) :active)
    (%%switch-to-thread-via-wired-stack current sp fp next)))

(sys.int::define-lap-function %%return-to-same-thread ()
  (sys.lap-x86:mov64 :rsp :r8)
  (sys.lap-x86:mov64 :rbp :r9)
  (sys.lap-x86:xor32 :ecx :ecx)
  (sys.lap-x86:mov64 :r8 nil)
  (sys.lap-x86:sti)
  (:gc :no-frame)
  (sys.lap-x86:ret))

(sys.int::define-lap-function %%switch-to-thread-via-wired-stack ()
  ;; Save frame pointer.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 (:object nil #.+thread-state-rbp+) :r10)
  ;; Save fpu state.
  (sys.lap-x86:gs)
  (sys.lap-x86:fxsave (:object nil #.+thread-fx-save-area+))
  ;; Save stack pointer.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 (:object nil #.+thread-state-rsp+) :r9)
  ;; Only partial state was saved.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 (:object nil #.+thread-full-save-p+) nil)
  ;; Jump to common function.
  (sys.lap-x86:mov64 :r9 :r11)
  (sys.lap-x86:mov64 :r13 (:function %%switch-to-thread-common))
  (sys.lap-x86:jmp (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8)))))

(defun %reschedule-via-interrupt (interrupt-frame)
  ;; Switch to the next thread saving the full state.
  ;; Interrupts must be off and the current thread's lock must be held.
  ;; Releases the thread lock and reenables interrupts.
  (let ((current (current-thread))
        (next (%update-run-queue)))
    ;; todo: reset preemption timer here.
    ;; Avoid double-locking the thread when returning to the current thread.
    (when (not (eql next current))
      (%lock-thread next))
    (setf (thread-state next) :active)
    (%%switch-to-thread-via-interrupt current interrupt-frame next)))

;;; current-thread interrupt-frame next-thread
;;; Interrupts must be off, current & next must be locked.
(sys.int::define-lap-function %%switch-to-thread-via-interrupt ()
  (:gc :no-frame)
  ;; Save fpu state.
  (sys.lap-x86:gs)
  (sys.lap-x86:fxsave (:object nil #.+thread-fx-save-area+))
  ;; Copy the interrupt frame over to the save area.
  (sys.lap-x86:mov64 :rsi (:object :r9 0))
  (sys.lap-x86:sar64 :rsi #.sys.int::+n-fixnum-bits+)
  (sys.lap-x86:sub64 :rsi #.(* 14 8)) ; 14 registers below the pointer, 6 above.
  (sys.lap-x86:lea64 :rdi (:object :r8 #.+thread-interrupt-save-area+))
  (sys.lap-x86:mov32 :ecx 20) ; 20 values to copy.
  (sys.lap-x86:rep)
  (sys.lap-x86:movs64)
  ;; Full state was saved.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 (:object nil #.+thread-full-save-p+) t)
  ;; Jump to common function.
  (sys.lap-x86:mov64 :r9 :r10) ; next-thread
  (sys.lap-x86:mov64 :r13 (:function %%switch-to-thread-common))
  (sys.lap-x86:jmp (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8)))))

;; (current-thread new-thread)
(sys.int::define-lap-function %%switch-to-thread-common ()
  ;; Old thread's state has been saved, restore the new-thread's state.
  ;; Switch threads.
  (sys.lap-x86:mov32 :ecx #.+msr-ia32-gs-base+)
  (sys.lap-x86:mov64 :rax :r9)
  (sys.lap-x86:mov64 :rdx :r9)
  (sys.lap-x86:shr64 :rdx 32)
  (sys.lap-x86:wrmsr)
  ;; Restore fpu state.
  (sys.lap-x86:gs)
  (sys.lap-x86:fxrstor (:object nil #.+thread-fx-save-area+))
  ;; Drop the locks on both threads. Must be done before touching the thread stack.
  (sys.lap-x86:mov64 :r10 (:constant :unlocked))
  (sys.lap-x86:cmp64 :r9 :r8)
  (sys.lap-x86:je SWITCH-TO-SAME-THREAD)
  (sys.lap-x86:mov64 (:object :r9 #.+thread-lock+) :r10)
  SWITCH-TO-SAME-THREAD
  (sys.lap-x86:mov64 (:object :r8 #.+thread-lock+) :r10)
  ;; Check if the thread is in the interrupt save area.
  (sys.lap-x86:gs)
  (sys.lap-x86:cmp64 (:object nil #.+thread-full-save-p+) nil)
  (sys.lap-x86:jne FULL-RESTORE)
  ;; Restore stack pointer.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 :rsp (:object nil #.+thread-state-rsp+))
  ;; Restore frame pointer.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 :rbp (:object nil #.+thread-state-rbp+))
  ;; Reenable interrupts. Must be done before touching the thread stack.
  (sys.lap-x86:sti)
  (:gc :no-frame)
  ;; Check for pending footholds.
  (sys.lap-x86:gs)
  (sys.lap-x86:cmp64 (:object nil #.+thread-pending-footholds+) nil)
  (sys.lap-x86:jne RUN-FOOTHOLDS)
  ;; No value return.
  NORMAL-RETURN
  (sys.lap-x86:xor32 :ecx :ecx)
  (sys.lap-x86:mov64 :r8 nil)
  ;; Return, restoring RIP.
  (sys.lap-x86:ret)
  RUN-FOOTHOLDS
  (sys.lap-x86:gs)
  (sys.lap-x86:cmp64 (:object nil #.+thread-inhibit-footholds+) 0)
  (sys.lap-x86:jne NORMAL-RETURN)
  ;; Jump to the support function to run the footholds.
  (sys.lap-x86:mov64 :r8 nil)
  (sys.lap-x86:gs)
  (sys.lap-x86:xchg64 (:object nil #.+thread-pending-footholds+) :r8)
  (sys.lap-x86:mov32 :ecx #.(ash 1 sys.int::+n-fixnum-bits+))
  (sys.lap-x86:mov64 :r13 (:function %run-thread-footholds))
  (sys.lap-x86:jmp (:r13 #.(+ (- sys.int::+tag-object+) 8 (* sys.int::+fref-entry-point+ 8))))
  ;; Returning to an interrupted thread. Restore saved registers and stuff.
  ;; TODO: How to deal with footholds here? The stack might be paged out here.
  FULL-RESTORE
  (sys.lap-x86:lea64 :rsp (:object :r9 #.+thread-interrupt-save-area+))
  (sys.lap-x86:pop :r15)
  (sys.lap-x86:pop :r14)
  (sys.lap-x86:pop :r13)
  (sys.lap-x86:pop :r12)
  (sys.lap-x86:pop :r11)
  (sys.lap-x86:pop :r10)
  (sys.lap-x86:pop :r9)
  (sys.lap-x86:pop :r8)
  (sys.lap-x86:pop :rdi)
  (sys.lap-x86:pop :rsi)
  (sys.lap-x86:pop :rbx)
  (sys.lap-x86:pop :rdx)
  (sys.lap-x86:pop :rcx)
  (sys.lap-x86:pop :rax)
  (sys.lap-x86:pop :rbp)
  (sys.lap-x86:iret))

(defun maybe-preempt-via-interrupt (interrupt-frame)
  (let ((current (current-thread)))
    (when (not (or (eql current (sys.int::symbol-global-value '*world-stopper*))
                   (eql current (sys.int::symbol-global-value 'sys.int::*pager-thread*))
                   (eql current (sys.int::symbol-global-value 'sys.int::*snapshot-thread*))
                   (eql current (sys.int::symbol-global-value 'sys.int::*disk-io-thread*))
                   (eql current (sys.int::symbol-global-value 'sys.int::*bsp-idle-thread*))))
      (%lock-thread current)
      (setf (thread-state current) :runnable)
      (%reschedule-via-interrupt interrupt-frame))))

;;; Stuff.

(sys.int::define-lap-function current-thread (())
  (sys.lap-x86:test64 :rcx :rcx)
  (sys.lap-x86:jnz BAD-ARGS)
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 :r8 (:object nil #.+thread-self+))
  (sys.lap-x86:mov32 :ecx #.(ash 1 sys.int::+n-fixnum-bits+))
  (sys.lap-x86:ret)
  BAD-ARGS
  (sys.lap-x86:mov64 :r13 (:function sys.int::raise-invalid-argument-error))
  (sys.lap-x86:xor32 :ecx :ecx)
  (sys.lap-x86:call (:object :r13 #.sys.int::+fref-entry-point+))
  (sys.lap-x86:ud2))

(defun make-thread (function &key name initial-bindings (stack-size (* 256 1024)) (priority :normal))
  (declare (sys.c::closure-allocation :wired))
  (check-type function (or function symbol))
  (check-type priority (member :normal :low))
  ;; Allocate-object will leave the thread's state variable initialized to 0.
  ;; The GC detects this to know when it's scanning a partially-initialized thread.
  (let* ((thread (mezzano.runtime::%allocate-object sys.int::+object-tag-thread+ 0 511 :wired))
         (stack (%allocate-stack stack-size)))
    (setf (sys.int::%object-ref-t thread +thread-name+) name
          (sys.int::%object-ref-t thread +thread-lock+) :unlocked
          (sys.int::%object-ref-t thread +thread-stack+) stack
          (sys.int::%object-ref-t thread +thread-special-stack-pointer+) nil
          (sys.int::%object-ref-t thread +thread-self+) thread
          (sys.int::%object-ref-t thread +thread-wait-item+) nil
          (sys.int::%object-ref-t thread +thread-mutex-stack+) nil
          (sys.int::%object-ref-t thread +thread-pending-footholds+) '()
          (sys.int::%object-ref-t thread +thread-inhibit-footholds+) 1
          (sys.int::%object-ref-t thread +thread-priority+) priority
          (sys.int::%object-ref-t thread +thread-pager-argument-1+) nil
          (sys.int::%object-ref-t thread +thread-pager-argument-2+) nil
          (sys.int::%object-ref-t thread +thread-pager-argument-3+) nil)
    ;; Perform initial bindings.
    (when initial-bindings
      (let ((symbols (mapcar #'first initial-bindings))
            (values (mapcar #'second initial-bindings))
            (original-function function))
        (setf function (lambda ()
                         (progv symbols values
                           (funcall original-function))))))
    ;; Initialize the FXSAVE area.
    ;; All FPU/SSE interrupts masked, round to nearest,
    ;; x87 using 80 bit precision (long-float).
    (dotimes (i 64)
      (setf (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ i)) 0))
    (setf (ldb (byte 16 0) (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ 0)))
          #x037F) ; FCW
    (setf (ldb (byte 32 0) (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ 3)))
          #x00001F80) ; MXCSR
    ;; Set up the initial register state.
    (let ((stack-pointer (+ (stack-base stack) (stack-size stack)))
          (trampoline #'thread-entry-trampoline))
      ;; Push a fake return address on the stack, this keeps the stack aligned correctly.
      (setf (sys.int::memref-unsigned-byte-64 (decf stack-pointer 8) 0) 0)
      ;; Initialize state save area.
      (setf (thread-state-ss thread) 0
            (thread-state-rsp thread) stack-pointer
            (thread-state-rbp thread) 0
            ;; Start with interrupts enabled.
            (thread-state-rflags thread) #x202
            ;; Kernel code segment (defined in cpu.lisp).
            (thread-state-cs thread) 8
            ;; Trampoline entry point.
            (thread-state-rip thread) (sys.int::%object-ref-signed-byte-64 trampoline 0)
            (thread-state-rax thread) 0
            ;; 1 argument passed.
            (thread-state-rcx-value thread) 1
            (thread-state-rdx thread) 0
            ;; FUNCALL calling convention.
            (thread-state-rbx-value thread) trampoline
            (thread-state-rsi thread) 0
            (thread-state-rdi thread) 0
            ;; First arg, function to call.
            (thread-state-r8-value thread) function
            (thread-state-r9 thread) 0
            (thread-state-r10 thread) 0
            (thread-state-r11 thread) 0
            (thread-state-r12 thread) 0
            (thread-state-r13 thread) 0
            (thread-state-r14 thread) 0
            (thread-state-r15 thread) 0))
    (setf (thread-full-save-p thread) t
          (thread-state thread) :runnable)
    (safe-without-interrupts (thread)
      (with-symbol-spinlock (*global-thread-lock*)
        (push-run-queue thread)
        ;; Add thread to global thread list.
        (setf (thread-global-prev *all-threads*) thread
              (thread-global-next thread) *all-threads*
              (thread-global-prev thread) nil
              *all-threads* thread)))
    thread))

(defun make-ephemeral-thread (entry-point initial-state &key name (stack-size (* 256 1024)) (priority :normal))
  (let* ((thread (mezzano.runtime::%allocate-object sys.int::+object-tag-thread+ 0 511 :wired))
         (stack (%allocate-stack stack-size t)))
    (setf (sys.int::%object-ref-t thread +thread-name+) name
          (sys.int::%object-ref-t thread +thread-lock+) :unlocked
          (sys.int::%object-ref-t thread +thread-stack+) stack
          (sys.int::%object-ref-t thread +thread-special-stack-pointer+) nil
          (sys.int::%object-ref-t thread +thread-self+) thread
          (sys.int::%object-ref-t thread +thread-wait-item+) nil
          (sys.int::%object-ref-t thread +thread-mutex-stack+) nil
          (sys.int::%object-ref-t thread +thread-pending-footholds+) '()
          (sys.int::%object-ref-t thread +thread-inhibit-footholds+) 1
          (sys.int::%object-ref-t thread +thread-priority+) priority
          (sys.int::%object-ref-t thread +thread-pager-argument-1+) nil
          (sys.int::%object-ref-t thread +thread-pager-argument-2+) nil
          (sys.int::%object-ref-t thread +thread-pager-argument-3+) nil)
    (reset-ephemeral-thread thread entry-point initial-state)
    thread))

(defun thread-entry-trampoline (function)
  (let ((self (current-thread)))
    (unwind-protect
         (catch 'terminate-thread
           (decf (thread-inhibit-footholds self))
           (funcall function))
      ;; Cleanup, terminate the thread.
      (%run-on-wired-stack-without-interrupts (sp fp self)
       (%lock-thread self)
       (setf (thread-state self) :dead)
       ;; Remove thread from the global list.
       (with-symbol-spinlock (*global-thread-lock*)
         (when (thread-global-next self)
           (setf (thread-global-prev (thread-global-next self)) (thread-global-prev self)))
         (when (thread-global-prev self)
           (setf (thread-global-next (thread-global-prev self)) (thread-global-next self)))
         (when (eql self *all-threads*)
           (setf *all-threads* (thread-global-next self))))
       (%reschedule-via-wired-stack sp fp)))))

;; The idle thread is not a true thread. It does not appear in all-threads, nor in any run-queue.
;; When the machine boots, one idle thread is created for each core. When a core is idle, the
;; idle thread will be run.
;; FIXME: SMP-safety.
(defun idle-thread ()
  (loop
     (sys.int::%cli)
     ;; Look for a thread to switch to.
     (let ((next (with-symbol-spinlock (*global-thread-lock*)
                   (cond ((eql (thread-state sys.int::*pager-thread*) :runnable)
                          sys.int::*pager-thread*)
                         ((eql (thread-state sys.int::*disk-io-thread*) :runnable)
                          sys.int::*disk-io-thread*)
                         (*world-stopper*
                          (when (eql (thread-state *world-stopper*) :runnable)
                            *world-stopper*))
                         (t (pop-run-queue))))))
       (cond (next
              (set-run-light t)
              ;; Switch to thread.
              (%lock-thread sys.int::*bsp-idle-thread*)
              (%lock-thread next)
              (setf (thread-state next) :active)
              (%run-on-wired-stack-without-interrupts (sp fp next)
                (%%switch-to-thread-via-wired-stack sys.int::*bsp-idle-thread* sp fp next))
              (when (boundp '*light-run*)
                ;; Clear the run light immediately so it doesn't stay on between
                ;; GUI screen updates.
                (clear-light *light-run*)))
             (t ;; Wait for an interrupt.
              (sys.int::%stihlt))))))

(defun reset-ephemeral-thread (thread entry-point state)
  ;; Threads created by the cold-generator have conses instead of real stack
  ;; objects. Work around this.
  (when (consp (thread-stack thread))
    (setf (thread-stack thread) (%make-stack (car (thread-stack thread))
                                             (cdr (thread-stack thread)))))
  ;; Set up the initial register state.
  (let ((stack-pointer (+ (stack-base (thread-stack thread))
                          (stack-size (thread-stack thread))))
        (function (sys.int::%coerce-to-callable entry-point)))
    ;; Push a fake return address on the stack, this keeps the stack aligned correctly.
    (setf (sys.int::memref-unsigned-byte-64 (decf stack-pointer 8) 0) 0)
    ;; Initialize state save area.
    (setf (thread-state-ss thread) 0
          (thread-state-rsp thread) stack-pointer
          (thread-state-rbp thread) 0
          ;; Start with interrupts enabled.
          (thread-state-rflags thread) #x202
          ;; Kernel code segment (defined in cpu.lisp).
          (thread-state-cs thread) 8
          ;; Entry point.
          (thread-state-rip thread) (sys.int::%object-ref-signed-byte-64 function 0)
          (thread-state-rax thread) 0
          ;; 0 arguments passed.
          (thread-state-rcx-value thread) 0
          (thread-state-rdx thread) 0
          ;; FUNCALL calling convention.
          (thread-state-rbx-value thread) function
          (thread-state-rsi thread) 0
          (thread-state-rdi thread) 0
          (thread-state-r8 thread) 0
          (thread-state-r9 thread) 0
          (thread-state-r10 thread) 0
          (thread-state-r11 thread) 0
          (thread-state-r12 thread) 0
          (thread-state-r13 thread) 0
          (thread-state-r14 thread) 0
          (thread-state-r15 thread) 0))
  (setf (thread-state thread) state
        (sys.int::%object-ref-t thread +thread-special-stack-pointer+) nil
        (sys.int::%object-ref-t thread +thread-wait-item+) nil
        (sys.int::%object-ref-t thread +thread-mutex-stack+) nil
        (sys.int::%object-ref-t thread +thread-pending-footholds+) '()
        (sys.int::%object-ref-t thread +thread-inhibit-footholds+) 1
        (thread-full-save-p thread) t)
  ;; Initialize the FXSAVE area.
  ;; All FPU/SSE interrupts masked, round to nearest,
  ;; x87 using 80 bit precision (long-float).
  (dotimes (i 64)
    (setf (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ i)) 0))
  (setf (ldb (byte 16 0) (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ 0)))
        #x037F) ; FCW
  (setf (ldb (byte 32 0) (sys.int::%object-ref-unsigned-byte-64 thread (+ +thread-fx-save-area+ 3)))
        #x00001F80) ; MXCSR
  ;; Flush the symbol cache.
  (dotimes (i (- +thread-symbol-cache-end+ +thread-symbol-cache-start+))
    (setf (sys.int::%object-ref-t thread (+ +thread-symbol-cache-start+ i)) 0)))

(defun initialize-threads ()
  (when (not (boundp '*global-thread-lock*))
    ;; First-run stuff.
    (setf *global-thread-lock* :unlocked)
    (setf *thread-run-queue-head* nil
          *thread-run-queue-tail* nil)
    (setf *low-priority-thread-run-queue-head* nil
          *low-priority-thread-run-queue-tail* nil)
    (setf *world-stop-lock* (make-mutex "World stop lock")
          *world-stop-cvar* (make-condition-variable "World stop cvar")
          *world-stop-pending* nil
          *pseudo-atomic-thread-count* 0)
    (setf *all-threads* sys.int::*snapshot-thread*
          (thread-global-next sys.int::*snapshot-thread*) sys.int::*pager-thread*
          (thread-global-prev sys.int::*snapshot-thread*) nil
          (thread-global-next sys.int::*pager-thread*) sys.int::*disk-io-thread*
          (thread-global-prev sys.int::*pager-thread*) sys.int::*snapshot-thread*
          (thread-global-next sys.int::*disk-io-thread*) nil
          (thread-global-prev sys.int::*disk-io-thread*) sys.int::*pager-thread*))
  (reset-ephemeral-thread sys.int::*bsp-idle-thread* #'idle-thread :sleeping)
  (reset-ephemeral-thread sys.int::*snapshot-thread* #'snapshot-thread :sleeping)
  (reset-ephemeral-thread sys.int::*pager-thread* #'pager-thread :runnable)
  (reset-ephemeral-thread sys.int::*disk-io-thread* #'disk-thread :runnable)
  (condition-notify *world-stop-cvar* t))

(defun wake-thread (thread)
  "Wake a sleeping thread."
  (without-interrupts
    (with-thread-lock (thread)
      (with-symbol-spinlock (*global-thread-lock*)
        (setf (thread-state thread) :runnable)
        (push-run-queue thread)))))

(defun initialize-initial-thread ()
  "Called very early after boot to reset the initial thread."
  (let* ((thread (current-thread)))
    (setf *world-stopper* thread)
    (setf (thread-state thread) :active)))

(defun finish-initial-thread ()
  "Called when the boot code is done with the initial thread."
  ;; The initial thread never dies, it just sleeps until the next boot.
  ;; The bootloader will partially wake it up, then initialize-initial-thread
  ;; will finish initialization.
  ;; The initial thread must finish with no values on the special stack.
  ;; This is required by INITIALIZE-INITIAL-THREAD.
  (let ((thread (current-thread)))
    (setf *world-stopper* nil)
    (sys.int::%cli)
    (%lock-thread thread)
    (setf (thread-wait-item thread) "The start of a new world"
          (thread-state thread) :sleeping)
    (%run-on-wired-stack-without-interrupts (sp fp)
     (%reschedule-via-wired-stack sp fp))
    (panic "Initial thread woken??")))

(defun all-threads ()
  (do ((list '())
       (current *all-threads* (thread-global-next current)))
      ((null current)
       list)
    (push current list)))

(defun terminate-thread (thread)
  (establish-thread-foothold
   thread
   (lambda ()
     (throw 'terminate-thread nil))))

(defmacro dx-lambda (lambda-list &body body)
  `(flet ((dx-lambda ,lambda-list ,@body))
     (declare (dynamic-extent #'dx-lambda))
     #'dx-lambda))

;;; Foothold management.

(defun %pop-foothold ()
  (safe-without-interrupts ()
    (pop (thread-pending-footholds (current-thread)))))

(defun %run-thread-footholds (footholds)
  (loop
     for fn in footholds
     do (funcall fn))
  (values))

(defmacro without-footholds (&body body)
  (let ((thread (gensym)))
    `(unwind-protect
          (progn
            (sys.int::%atomic-fixnum-add-object (current-thread) +thread-inhibit-footholds+ 1)
            ,@body)
       (let ((,thread (current-thread)))
         (sys.int::%atomic-fixnum-add-object ,thread +thread-inhibit-footholds+ -1)
         (when (and (zerop (sys.int::%object-ref-t ,thread +thread-inhibit-footholds+))
                    (sys.int::%object-ref-t ,thread +thread-pending-footholds+))
           (%run-thread-footholds (sys.int::%xchg-object ,thread +thread-pending-footholds+ nil)))))))

(defun establish-thread-foothold (thread function)
  (loop
     (let ((old (thread-pending-footholds thread)))
       ;; Use CAS to avoid having to disable interrupts/lock the thread/etc.
       ;; Tricky to mix with allocation.
       (when (sys.int::%cas-object thread +thread-pending-footholds+
                                   old (cons function old))
         (return)))))

;;; Stopping the world.
;;; WITH-WORLD-STOPPED and WITH-PSEUDO-ATOMIC work together as a sort-of global
;;; reader/writer lock over the whole system.

(defun call-with-world-stopped (thunk)
  (let ((self (current-thread)))
    (when (eql *world-stopper* self)
      (panic "Nested world stop!"))
    (when *pseudo-atomic*
      (panic "Stopping world while pseudo-atomic!"))
    (ensure-interrupts-enabled)
    (with-mutex (*world-stop-lock*)
      ;; First, try to position ourselves as the next thread to stop the world.
      ;; This prevents any more threads from becoming PA.
      (loop
         (when (null *world-stop-pending*)
           (setf *world-stop-pending* self)
           (return))
         ;; Wait for the world to unstop.
         (condition-wait *world-stop-cvar* *world-stop-lock*))
      ;; Now wait for any PA threads to finish.
      (loop
         (when (zerop *pseudo-atomic-thread-count*)
           (setf *world-stopper* self
                 *world-stop-pending* nil)
           (return))
         (condition-wait *world-stop-cvar* *world-stop-lock*)))
    ;; Don't hold the mutex over the thunk, it's a spinlock and disables interrupts.
    (multiple-value-prog1
        (funcall thunk)
      (with-mutex (*world-stop-lock*)
        ;; Release the dogs!
        (setf *world-stopper* nil)
        (condition-notify *world-stop-cvar* t)))))

(defmacro with-world-stopped (&body body)
  `(call-with-world-stopped (dx-lambda () ,@body)))

(defun call-with-pseudo-atomic (thunk)
  (when (eql *world-stopper* (current-thread))
    (panic "Going PA with world stopped!"))
  (ensure-interrupts-enabled)
  (with-mutex (*world-stop-lock*)
    (loop
       (when (null *world-stop-pending*)
         (return))
       ;; Don't go PA if there is a thread waiting to stop the world.
       (condition-wait *world-stop-cvar* *world-stop-lock*))
    ;; TODO: Have a list of pseudo atomic threads, and prevent PA threads
    ;; from being inspected.
    (incf *pseudo-atomic-thread-count*))
  (unwind-protect
       (let ((*pseudo-atomic* t))
         (funcall thunk))
    (with-mutex (*world-stop-lock*)
      (decf *pseudo-atomic-thread-count*)
      (condition-notify *world-stop-cvar* t))))

(defmacro with-pseudo-atomic (&body body)
  `(call-with-pseudo-atomic (dx-lambda () ,@body)))

;;; Higher-level locks and things.

;;; Common structure for sleepable things.
(defstruct (wait-queue
             (:area :wired))
  name
  (%lock (place-spinlock-initializer))
  (head nil)
  (tail nil))

(defun push-wait-queue (thread wait-queue)
  (cond ((null (wait-queue-head wait-queue))
         (setf (wait-queue-head wait-queue) thread
               (wait-queue-tail wait-queue) thread)
         (setf (thread-%next thread) nil
               (thread-%prev thread) nil))
        (t
         (setf (thread-%next (wait-queue-tail wait-queue)) thread
               (thread-%prev thread) (wait-queue-tail wait-queue)
               (thread-%next thread) nil
               (wait-queue-tail wait-queue) thread))))

(defun pop-wait-queue (wait-queue)
  (let ((thread (wait-queue-head wait-queue)))
    (when thread
      (cond ((thread-%next thread)
             (setf (thread-%prev (thread-%next thread)) nil)
             (setf (wait-queue-head wait-queue) (thread-%next thread)))
            (t (setf (wait-queue-head wait-queue) nil
                     (wait-queue-tail wait-queue) nil)))
      thread)))

(defun lock-wait-queue (wait-queue)
  (acquire-place-spinlock (wait-queue-%lock wait-queue)))

(defun unlock-wait-queue (wait-queue)
  (release-place-spinlock (wait-queue-%lock wait-queue)))

(defmacro with-wait-queue-lock ((wait-queue) &body body)
  (let ((sym (gensym "WAIT-QUEUE")))
    `(let ((,sym ,wait-queue))
       (unwind-protect
            (progn
              (lock-wait-queue ,sym)
              ,@body)
         (unlock-wait-queue ,sym)))))

(defstruct (mutex
             (:include wait-queue)
             (:constructor make-mutex (&optional name))
             (:area :wired))
  ;; Thread holding the lock, or NIL if it is free.
  ;; May not be correct when the lock is being acquired/released.
  (owner nil)
  ;; Lock state.
  ;; :unlocked - No thread is holding the lock.
  ;; :locked - A thread is holding the lock and no other threads have
  ;;           attempted to acquire it.
  ;; :contested - The lock is held, and there are threads attempting to
  ;;              acquire it. This causes release to wake sleeping threads.
  ;; Must be index 6. CONS grovels directly in the lock.
  (state :unlocked)
  (stack-next nil)
  ;; Number of times ACQUIRE-MUTEX failed to immediately acquire the lock.
  (contested-count 0))

(defun acquire-mutex (mutex &optional (wait-p t))
  (let ((self (current-thread)))
    ;; Fast path - try to lock.
    (when (eql (sys.int::cas (mutex-state mutex) :unlocked :locked) :unlocked)
      ;; We got it.
      (setf (mutex-owner mutex) self)
      (return-from acquire-mutex t))
    ;; Idiot check.
    (unless (not (mutex-held-p mutex))
      (panic "Recursive locking detected on " mutex " " (mutex-name mutex)))
    ;; Increment MUTEX-CONTESTED-COUNT
    (sys.int::%atomic-fixnum-add-object mutex 8 1)
    (when wait-p
      (ensure-interrupts-enabled)
      (unless (not *pseudo-atomic*)
        (panic "Trying to acquire mutex " mutex " while pseudo-atomic."))
      (%call-on-wired-stack-without-interrupts
       #'acquire-mutex-slow-path nil mutex self)
      t)))

(defun acquire-mutex-slow-path (sp fp mutex self)
  ;; Slow path.
  ;; Now try to sleep on the lock.
  (lock-wait-queue mutex)
  ;; Put the lock into the contested state.
  ;; Try to acquire again, release may have been running.
  (when (eql (sys.int::%xchg-object mutex 6 :contested) :unlocked)
    ;; We got it.
    (setf (mutex-owner mutex) self)
    (unlock-wait-queue mutex)
    (return-from acquire-mutex-slow-path))
  ;; Add to wait queue. Release will directly transfer ownership
  ;; to this thread.
  (push-wait-queue self mutex)
  ;; Now sleep.
  ;; Must take the thread lock before dropping the mutex lock or release
  ;; may be able to remove the thread from the sleep queue before it goes
  ;; to sleep.
  (%lock-thread self)
  (unlock-wait-queue mutex)
  (setf (thread-wait-item self) mutex
        (thread-state self) :sleeping)
  (%reschedule-via-wired-stack sp fp))

(defun mutex-held-p (mutex)
  "Return true if this thread holds MUTEX."
  (eql (mutex-owner mutex) (current-thread)))

(defun release-mutex (mutex)
  (unless (mutex-held-p mutex)
    (panic "Trying to release mutex " mutex " not held by thread."))
  (setf (mutex-owner mutex) nil)
  (when (not (eql (sys.int::cas (mutex-state mutex) :locked :unlocked) :locked))
    ;; Mutex must be in the contested state.
    (release-mutex-slow-path mutex))
  (values))

(defun release-mutex-slow-path (mutex)
  ;; Contested lock. Need to wake a thread and pass the lock to it.
  (safe-without-interrupts (mutex)
    (with-wait-queue-lock (mutex)
      ;; Look for a thread to wake.
      (let ((thread (pop-wait-queue mutex)))
        (cond (thread
               ;; Found one, wake it & transfer the lock.
               (setf (mutex-owner mutex) thread)
               (wake-thread thread))
              (t
               ;; No threads sleeping, just drop the lock.
               ;; Any threads trying to lock will be spinning on the wait queue lock.
               (setf (mutex-state mutex) :unlocked)))))))

(defun call-with-mutex (thunk mutex wait-p)
  (unwind-protect
       (when (acquire-mutex mutex wait-p)
         (funcall thunk))
    (when (mutex-held-p mutex)
      (release-mutex mutex))))

(defmacro with-mutex ((mutex &optional (wait-p t)) &body body)
  "Run body with MUTEX locked.
May be used from an interrupt handler when WAIT-P is false or if MUTEX is a spin mutex."
  ;; Cold generator has some odd problems with uninterned symbols...
  `(flet ((call-with-mutex-thunk () ,@body))
     (declare (dynamic-extent #'call-with-mutex-thunk))
     (call-with-mutex #'call-with-mutex-thunk
                      ,mutex
                      ,wait-p)))

(defstruct (condition-variable
             (:include wait-queue)
             (:constructor make-condition-variable (&optional name))
             (:area :wired)))

(defun condition-wait (condition-variable mutex)
  (assert (mutex-held-p mutex))
  (ensure-interrupts-enabled)
  (unwind-protect
       (%run-on-wired-stack-without-interrupts (sp fp condition-variable mutex)
        (let ((self (current-thread)))
          (lock-wait-queue condition-variable)
          (%lock-thread self)
          ;; Attach to the list.
          (push-wait-queue self condition-variable)
          ;; Drop the mutex.
          (release-mutex mutex)
          ;; Sleep.
          ;; need to be careful with that, returning or unwinding from condition-wait
          ;; with the lock unlocked would be quite bad.
          (setf (thread-wait-item self) condition-variable
                (thread-state self) :sleeping)
          (unlock-wait-queue condition-variable)
          (%reschedule-via-wired-stack sp fp)))
    ;; Got woken up. Reacquire the mutex.
    ;; Slightly tricky, if the thread was interrupted and unwound before
    ;; interrupts were disabled, then the mutex won't have been released.
    (when (not (mutex-held-p mutex))
      (acquire-mutex mutex t)))
  (values))

(defun condition-notify (condition-variable &optional broadcast)
  "Wake one or many threads waiting on CONDITION-VARIABLE.
May be used from an interrupt handler, assuming the associated mutex is interrupt-safe."
  (safe-without-interrupts (condition-variable broadcast)
    (flet ((pop-one ()
             (wake-thread (pop-wait-queue condition-variable))))
      (declare (dynamic-extent #'pop-one))
      (with-wait-queue-lock (condition-variable)
        (cond (broadcast
               ;; Loop until all the threads have been woken.
               (do ()
                   ((null (condition-variable-head condition-variable)))
                 (pop-one)))
              (t
               ;; Wake exactly one.
               (when (condition-variable-head condition-variable)
                 (pop-one)))))))
  (values))

(defstruct (semaphore
             (:include wait-queue)
             (:constructor make-semaphore (value &optional name))
             (:area :wired))
  (value 0 :type (integer 0)))

(defun semaphore-up (semaphore)
  "Increment the semaphore count, or wake a waiting thread.
May be used from an interrupt handler."
  (with-wait-queue-lock (semaphore)
    ;; If there is a thread, wake it instead of incrementing.
    (let ((thread (pop-wait-queue semaphore)))
      (cond (thread
             ;; Found one, wake it.
             (wake-thread thread))
            (t
             ;; No threads sleeping, increment.
             (incf (semaphore-value semaphore)))))))

(defun semaphore-down (semaphore &optional (wait-p t))
  (ensure-interrupts-enabled)
  ;; Invert the result here because %RESCHEDULE-VIA-WIRED-STACK will always
  ;; cause %R-O-W-S-W-I to return NIL, which is actually a success result.
  (not (%run-on-wired-stack-without-interrupts (sp fp semaphore wait-p)
        (let ((self (current-thread)))
          (lock-wait-queue semaphore)
          (cond ((not (zerop (semaphore-value semaphore)))
                 (decf (semaphore-value semaphore))
                 (unlock-wait-queue semaphore)
                 ;; Success (inverted).
                 nil)
                (wait-p
                 ;; Go to sleep.
                 (push-wait-queue self semaphore)
                 ;; Now sleep.
                 ;; Must take the thread lock before dropping the semaphore lock or up
                 ;; may be able to remove the thread from the sleep queue before it goes
                 ;; to sleep.
                 (%lock-thread self)
                 (unlock-wait-queue semaphore)
                 (setf (thread-wait-item self) semaphore
                       (thread-state self) :sleeping)
                 (%reschedule-via-wired-stack sp fp))
                (t (unlock-wait-queue semaphore)
                   ;; Failure (inverted).
                   t))))))

(defstruct (latch
             (:include wait-queue)
             (:constructor make-latch (&optional name))
             (:area :wired))
  (state nil))

(defun latch-reset (latch)
  (safe-without-interrupts (latch)
    (with-wait-queue-lock (latch)
      (setf (latch-state latch) nil))))

(defun latch-wait (latch)
  (when (latch-state latch)
    (return-from latch-wait))
  (ensure-interrupts-enabled)
  (%run-on-wired-stack-without-interrupts (sp fp latch)
   (let ((self (current-thread)))
     (lock-wait-queue latch)
     (cond ((latch-state latch)
            ;; Latch was opened after the wait-queue was locked.
            ;; Don't sleep.
            (unlock-wait-queue latch))
           (t ;; Latch is closed, sleep.
            (%lock-thread self)
            ;; Attach to the list.
            (push-wait-queue self latch)
            ;; Sleep.
            (setf (thread-wait-item self) latch
                  (thread-state self) :sleeping)
            (unlock-wait-queue latch)
            (%reschedule-via-wired-stack sp fp)))))
  (values))

(defun latch-trigger (latch)
  (safe-without-interrupts (latch)
    (with-wait-queue-lock (latch)
      (setf (latch-state latch) t)
      ;; Loop until all the threads have been woken.
      (do ()
          ((null (wait-queue-head latch)))
        (wake-thread (pop-wait-queue latch))))))

(defstruct (irq-fifo
             (:area :wired)
             (:constructor %make-irq-fifo))
  (head 0 :type fixnum)
  (tail 0 :type fixnum)
  (size)
  (element-type)
  (buffer (error "no buffer supplied") :read-only t)
  (count (make-semaphore 0))
  (lock (place-spinlock-initializer)))

(defun make-irq-fifo (size &key (element-type 't))
  ;; TODO: non-t element types.
  (%make-irq-fifo :size size
                  :buffer (sys.int::make-simple-vector size :wired)
                  :element-type 't))

(defun irq-fifo-push (value fifo)
  "Push a byte onto FIFO. Returns true if there was space adn value was pushed successfully.
If the fifo is full, then FIFO-PUSH will return false.
Safe to use from an interrupt handler."
  (safe-without-interrupts (value fifo)
    (with-place-spinlock ((irq-fifo-lock fifo))
      (let ((next (1+ (irq-fifo-tail fifo))))
        (when (>= next (irq-fifo-size fifo))
          (setf next 0))
        ;; When next reaches head, the buffer is full.
        (unless (= next (irq-fifo-head fifo))
          (setf (svref (irq-fifo-buffer fifo) (irq-fifo-tail fifo)) value
                (irq-fifo-tail fifo) next)
          (semaphore-up (irq-fifo-count fifo))
          t)))))

(defun irq-fifo-pop (fifo &optional (wait-p t))
  "Pop a byte from FIFO.
Returns two values. The first value is the value popped from the FIFO.
The second value is true if a value was popped, false otherwise.
It is only possible for the second value to be false when wait-p is false."
  (when (not (semaphore-down (irq-fifo-count fifo) wait-p))
    (return-from irq-fifo-pop
      (values nil nil)))
  (safe-without-interrupts (fifo)
    (with-place-spinlock ((irq-fifo-lock fifo))
      ;; FIFO must not be empty.
      (ensure (not (eql (irq-fifo-head fifo) (irq-fifo-tail fifo))))
      ;; Pop byte.
      (let ((value (svref (irq-fifo-buffer fifo) (irq-fifo-head fifo)))
            (next (1+ (irq-fifo-head fifo))))
        (when (>= next (irq-fifo-size fifo))
          (setf next 0))
        (setf (irq-fifo-head fifo) next)
        (values value t)))))

(defun irq-fifo-reset (fifo)
  "Flush any waiting data."
  (loop
     (multiple-value-bind (value validp)
         (irq-fifo-pop fifo nil)
       (declare (ignore value))
       (when (not validp)
         (return)))))

(defstruct (fifo
             (:area :wired)
             (:constructor (make-fifo (size &key (element-type 't) &aux (buffer (make-array (list size) :element-type element-type))))))
  (head 0 :type fixnum)
  (tail 0 :type fixnum)
  (size nil :read-only t)
  (element-type nil :read-only t)
  (buffer nil :read-only t)
  (cv (make-condition-variable))
  (lock (make-mutex "fifo-lock")))

(defun fifo-push (value fifo &optional (wait-p t))
  "Push a byte onto FIFO. Returns true if successful.
If the fifo is full, then FIFO-PUSH will wait for space to become available
when WAIT-P is true, otherwise it will immediately return false."
  (with-mutex ((fifo-lock fifo))
    (loop
       (let ((next (1+ (fifo-tail fifo))))
         (when (>= next (fifo-size fifo))
           (setf next 0))
         ;; When next reaches head, the buffer is full.
         (unless (= next (fifo-head fifo))
           (setf (aref (fifo-buffer fifo) (fifo-tail fifo)) value
                 (fifo-tail fifo) next)
           (condition-notify (fifo-cv fifo))
           (return t)))
       (unless wait-p
         (return nil))
       (condition-wait (fifo-cv fifo)
                       (fifo-lock fifo)))))

(defun fifo-pop (fifo &optional (wait-p t))
  "Pop a byte from FIFO.
Returns two values. The first value is the value popped from the FIFO.
The second value is true if a value was popped, false otherwise.
It is only possible for the second value to be false when wait-p is false."
  (with-mutex ((fifo-lock fifo))
    (loop
       (when (not (eql (fifo-head fifo) (fifo-tail fifo)))
         ;; Fifo not empty, pop byte.
         (let ((value (aref (fifo-buffer fifo) (fifo-head fifo)))
               (next (1+ (fifo-head fifo))))
           (when (>= next (fifo-size fifo))
             (setf next 0))
           (setf (fifo-head fifo) next)
           (condition-notify (fifo-cv fifo))
           (return (values value t))))
       ;; Fifo empty, maybe wait?
       (unless wait-p
         (return (values nil nil)))
       (condition-wait (fifo-cv fifo)
                       (fifo-lock fifo)))))

(defun fifo-reset (fifo)
  "Flush any waiting data."
  (with-mutex ((fifo-lock fifo))
    (setf (fifo-head fifo) 0
          (fifo-tail fifo) 0)
    ;; Signal the cvar to wake any waiting FIFO-PUSH calls.
    (condition-notify (fifo-cv fifo) t)))
