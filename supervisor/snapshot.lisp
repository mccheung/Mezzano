;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

(defvar *snapshot-in-progress* nil)
(defvar *snapshot-inhibit*)

(defvar *snapshot-disk-request*)
(defvar *snapshot-bounce-buffer-page*)
(defvar *snapshot-pending-writeback-pages-count*)
(defvar *snapshot-pending-writeback-pages*)

;;; (destination source)
(sys.int::define-lap-function %fast-page-copy ()
  (sys.lap-x86:mov64 :rdi :r8)
  (sys.lap-x86:mov64 :rsi :r9)
  (sys.lap-x86:sar64 :rdi #.sys.int::+n-fixnum-bits+)
  (sys.lap-x86:sar64 :rsi #.sys.int::+n-fixnum-bits+)
  (sys.lap-x86:mov32 :ecx 512)
  (sys.lap-x86:rep)
  (sys.lap-x86:movs64)
  (sys.lap-x86:ret))

(defun snapshot-add-to-writeback-list (frame)
  ;; Link frame into writeback list.
  (cond (*snapshot-pending-writeback-pages*
         (setf (physical-page-frame-prev *snapshot-pending-writeback-pages*) frame
               (physical-page-frame-next frame) *snapshot-pending-writeback-pages*
               (physical-page-frame-prev frame) nil
               *snapshot-pending-writeback-pages* frame))
        (t
         (setf *snapshot-pending-writeback-pages* frame
               (physical-page-frame-next frame) nil
               (physical-page-frame-prev frame) nil)))
  (incf *snapshot-pending-writeback-pages-count*))

(defun snapshot-add-writeback-frame (frame)
  (ensure (eql (physical-page-frame-type frame) :active)
          "Tried to writeback non-active frame of type " (physical-page-frame-type frame))
  (let* ((address (physical-page-virtual-address frame))
         (bme-addr (or (block-info-for-virtual-address-1 address nil)
                       (panic "No block map entry for page " address)))
         (bme (sys.int::memref-unsigned-byte-64 bme-addr 0)))
    #+(or)(debug-print-line "Add writeback frame " frame ":" address " " bme)
    ;; Commit if needed.
    (when (not (logtest bme sys.int::+block-map-committed+))
      (let ((new-block (or (store-alloc 1)
                           (panic "Aiiee, out of store during writeback page commit.")))
            (old-block (ash bme (- sys.int::+block-map-id-shift+))))
        #+(or)(debug-print-line "  committing " old-block " " new-block)
        (setf bme (logior (ash new-block sys.int::+block-map-id-shift+)
                          sys.int::+block-map-committed+
                          (logand bme #xFF))
              (sys.int::memref-unsigned-byte-64 bme-addr 0) bme)
        #+(or)(debug-print-line "Replace old block " old-block " with " new-block " vaddr " candidate-virtual)
        (decf *store-fudge-factor*)
        (store-deferred-free old-block 1)
        #+(or)(debug-print-line "Old block: " old-block "  new-block: " new-block)))
    ;; Set block number.
    (setf (physical-page-frame-block-id frame) (ash bme (- sys.int::+block-map-id-shift+)))
    (setf (physical-page-frame-type frame) :active-writeback)
    (remove-from-page-replacement-list frame)
    (snapshot-add-to-writeback-list frame)))

(defun snapshot-copy-wired-area ()
  ;; FIXME: Only copy dirty pages.
  ;; Walk through each wired page and allocate a new block for it.
  (loop
     for wired-page from #x200000 below sys.int::*wired-area-bump* by #x1000
     for pte = (or (get-pte-for-address wired-page nil)
                   (panic "No page table entry for wired-page " wired-page))
     for page-frame = (ash (sys.int::memref-unsigned-byte-64 pte 0) -12)
     for backing-frame = (physical-page-frame-next page-frame)
     for bme-addr = (or (block-info-for-virtual-address-1 wired-page nil)
                        (panic "No block map entry for wired-page " wired-page))
     for bme = (sys.int::memref-unsigned-byte-64 bme-addr 0)
     for new-block = (or (store-alloc 1)
                         (panic "Aiiee, out of store when copying wired area!"))
     for old-block = (ash bme (- sys.int::+block-map-id-shift+))
     do
       (setf (physical-page-frame-block-id backing-frame) new-block)
       (setf bme (logior (ash new-block sys.int::+block-map-id-shift+)
                         sys.int::+block-map-committed+
                         (logand bme #xFF))
             (sys.int::memref-unsigned-byte-64 bme-addr 0) bme)
       (decf *store-fudge-factor*)
       (store-deferred-free old-block 1))
  ;; I bet this could be partially done with CoW. Evil.
  ;; Copy without interrupts to avoid smearing.
  (without-interrupts
    (loop
       for wired-page from #x200000 below sys.int::*wired-area-bump* by #x1000
       for pte = (or (get-pte-for-address wired-page nil)
                     (panic "No page table entry for " wired-page))
       for page-frame = (ash (sys.int::memref-unsigned-byte-64 pte 0) -12)
       for other-frame = (physical-page-frame-next page-frame)
       do
         (%fast-page-copy (+ +physical-map-base+ (ash other-frame 12)) wired-page)
         (snapshot-add-to-writeback-list other-frame))))

(defun snapshot-mark-cow-dirty-pages ()
  ;; Mark all non-wired dirty pages as read-only and set their CoW bits.
  (let ((pml4 (+ +physical-map-base+ (logand (sys.int::%cr3) (lognot #xFFF)))))
    (labels ((mark-level (pml index next-fn)
               ;;(debug-print-line " PML " pml " index " index)
               (let* ((entry (sys.int::memref-unsigned-byte-64 pml index))
                      (next-pml (+ +physical-map-base+
                                   (logand entry +page-table-address-mask+))))
                 (when (and (logtest entry +page-table-present+)
                            (logtest entry +page-table-accessed+))
                   (dotimes (i 512)
                     (funcall next-fn next-pml i))
                   ;; Clear accessed bit.
                   (setf (sys.int::memref-unsigned-byte-64 pml index)
                         (logand entry (lognot +page-table-accessed+))))))
             (mark-pml4e-cow (pml4e)
               (mark-level pml4 pml4e #'mark-pml3e-cow))
             (mark-pml3e-cow (pml3 pml3e)
               (mark-level pml3 pml3e #'mark-pml2e-cow))
             (mark-pml2e-cow (pml2 pml2e)
               (mark-level pml2 pml2e #'mark-pml1e-cow))
             (mark-pml1e-cow (pml1 pml1e)
               (let ((entry (sys.int::memref-unsigned-byte-64 pml1 pml1e)))
                 ;;(debug-print-line "    PML1e " pml1e "  " pml1 "  " entry)
                 (when (logtest entry +page-table-copy-on-write+)
                   (panic "Page table entry marked CoW when it shouldn't be."))
                 (when (logtest entry +page-table-dirty+)
                   (snapshot-add-writeback-frame (ash (sys.int::memref-unsigned-byte-64 pml1 pml1e) -12))
                   ;; Clear dirty and writable bits, set copy-on-write bit.
                   (setf (sys.int::memref-unsigned-byte-64 pml1 pml1e)
                         (logand (logior entry
                                         +page-table-copy-on-write+)
                                 (lognot +page-table-write+)
                                 (lognot +page-table-dirty+)))))))
      (declare (dynamic-extent #'mark-level
                               #'mark-pml4e-cow #'mark-pml3e-cow
                               #'mark-pml2e-cow #'mark-pml1e-cow))
      ;; Skip wired area, entry 0.
      (loop for i from 1 below 64 ; pinned area to wired stack area.
         do (mark-pml4e-cow i))
      ;; Skip wired stack area, entry 64.
      (loop for i from 65 below 256 ; stack area to end of persistent memory.
         do (mark-pml4e-cow i))
      ;; Cover the part of the pinned area that got missed as well.
      (let ((pml3 (+ +physical-map-base+ (logand (sys.int::memref-unsigned-byte-64 pml4 0) +page-table-address-mask+))))
        ;; Skip first 2 entries, the wired area.
        (loop for i from 2 below 512
           do (mark-pml3e-cow pml3 i)))))
  (flush-tlb))

(defun snapshot-clone-cow-page (new-frame fault-addr)
  (let* ((pte (or (get-pte-for-address fault-addr nil)
                  (panic "No PTE for CoW address?")))
         (old-frame (ash (sys.int::memref-unsigned-byte-64 pte 0) -12)))
    (ensure (logtest (sys.int::memref-unsigned-byte-64 pte 0) +page-table-copy-on-write+)
            "Copying non-CoW page?")
    (%fast-page-copy (+ +physical-map-base+ (ash new-frame 12))
                     (logand fault-addr (lognot #xFFF)))
    (setf (physical-page-frame-block-id new-frame) (physical-page-frame-block-id old-frame)
          (physical-page-virtual-address new-frame) (physical-page-virtual-address old-frame))
    (setf (physical-page-frame-type new-frame) :active
          (physical-page-frame-type old-frame) :inactive-writeback)
    (append-to-page-replacement-list new-frame)
    ;; Point the PTE at the new page, disable copy on write and reenable write access.
    (setf (sys.int::memref-unsigned-byte-64 pte 0)
          (logior (ash new-frame 12)
                  +page-table-write+
                  +page-table-present+))
    (sys.int::%invlpg fault-addr)
    #+(or)(debug-print-line "Copied page " fault-addr)))

(defun snapshot-clone-cow-page-via-page-fault (interrupt-frame fault-addr)
  (let ((new-frame (allocate-physical-pages 1)))
    (when (not new-frame)
      ;; No memory. Punt to the pager, does not return.
      (wait-for-page-via-interrupt interrupt-frame fault-addr))
    (snapshot-clone-cow-page new-frame fault-addr)))

(defun pop-pending-snapshot-page ()
  (with-mutex (*vm-lock*)
    (without-interrupts
      (let* ((frame *snapshot-pending-writeback-pages*)
             (address (physical-page-virtual-address frame)))
        ;; Remove frame from list.
        (setf *snapshot-pending-writeback-pages* (physical-page-frame-next frame))
        (when *snapshot-pending-writeback-pages*
          (setf (physical-page-frame-prev *snapshot-pending-writeback-pages*) nil))
        (decf *snapshot-pending-writeback-pages-count*)
        (case (physical-page-frame-type frame)
          (:active-writeback
           ;; Page is mapped in memory.
           ;; Copy to the bounce buffer.
           (%fast-page-copy (+ +physical-map-base+ (ash *snapshot-bounce-buffer-page* 12))
                            (+ +physical-map-base+ (ash frame 12)))
           ;; Allow access to the page again.
           (let ((pte (or (get-pte-for-address address nil)
                          (panic "No PTE for CoW address?"))))
             ;; Update PTE bits. Clear CoW bit, make writable.
             (setf (sys.int::memref-unsigned-byte-64 pte 0)
                   (logior (logand (sys.int::memref-unsigned-byte-64 pte 0)
                                   (lognot +page-table-copy-on-write+))
                           +page-table-write+))
             (sys.int::%invlpg address))
           ;; Return page to normal use.
           (setf (physical-page-frame-type frame) :active)
           (append-to-page-replacement-list frame)
           (values *snapshot-bounce-buffer-page*
                   ;; Don't free the bounce page.
                   nil
                   (physical-page-frame-block-id frame)
                   address))
          (:inactive-writeback
           ;; Page was copied.
           (values frame
                   t
                   (physical-page-frame-block-id frame)
                   address))
          (:wired-backing
           ;; Page is a wired backing page.
           (values frame
                   nil
                   (physical-page-frame-block-id frame)
                   address))
          (t (panic "Page " frame " for address " address " has non-writeback type "
                    (physical-page-frame-type frame))))))))

(defun snapshot-write-back-pages ()
  ;; Write dirty/copied pages back.
  (let ((n 0))
    (loop
       (when (eql n 0)
         (setf n 100)
         (debug-print-line *snapshot-pending-writeback-pages-count* " dirty pages to write back"))
       (decf n)
       (when (not *snapshot-pending-writeback-pages*) (return))
       (multiple-value-bind (frame freep block-id address)
           (pop-pending-snapshot-page)
         #+(or)(debug-print-line "Writing back page " frame "/" block-id "/" address)
         (or (snapshot-write-disk block-id (+ +physical-map-base+ (ash frame 12)))
             (panic "Unable to write page to disk!"))
         (when freep
           (release-physical-pages frame 1))))))

(defun snapshot-write-disk (block data)
  (disk-submit-request *snapshot-disk-request*
                       *paging-disk*
                       :write
                       (* block
                          (ceiling +4k-page-size+ (disk-sector-size *paging-disk*)))
                       (ceiling +4k-page-size+ (disk-sector-size *paging-disk*))
                       data)
  (disk-await-request *snapshot-disk-request*))

(defun snapshot-freelist ()
  (values (regenerate-store-freelist)
          (prog1 *store-deferred-freelist-head*
            (setf *store-deferred-freelist-head* '()))))

(defun snapshot-bml1 (bml1)
  (let ((bml1-disk (or (store-alloc 1)
                       (panic "Unable to allocate disk space for new block map.")))
        ;; Update the bottom level of the block map in-place.
        (bml1-memory bml1)
        (bml1-count 0))
    (dotimes (i 512)
      (let ((entry (sys.int::memref-unsigned-byte-64 bml1 i)))
        (when (not (zerop entry))
          ;; Uncommit any committed pages.
          (when (logtest entry sys.int::+block-map-committed+)
            (setf (sys.int::memref-unsigned-byte-64 bml1 i) (logand entry (lognot sys.int::+block-map-committed+)))
            (incf *store-fudge-factor*))
          (incf bml1-count))))
    (cond ((zerop bml1-count)
           ;; No entries, don't bother with this level.
           (store-free bml1-disk 1)
           nil)
          (t (snapshot-write-disk bml1-disk bml1-memory)
             (logior (ash bml1-disk sys.int::+block-map-id-shift+)
                     sys.int::+block-map-present+)))))

(defun snapshot-block-map-outer-level (bml next-fn)
  (let ((bml-disk (or (store-alloc 1)
                      (panic "Unable to allocate disk space for new block map.")))
        (bml-memory (+ +physical-map-base+ (* (pager-allocate-page :other) +4k-page-size+)))
        (bml-count 0))
    (dotimes (i 512)
      (let* ((entry (sys.int::memref-signed-byte-64 bml i))
             (disk-entry (if (zerop entry)
                             nil
                             (funcall next-fn entry))))
        (cond (disk-entry
               (setf (sys.int::memref-signed-byte-64 bml-memory i) disk-entry)
               (incf bml-count))
              (t
               (setf (sys.int::memref-signed-byte-64 bml-memory i) 0)))))
    (prog1
        (cond ((zerop bml-count)
               ;; No entries, don't bother with this level.
               (store-free bml-disk 1)
               nil)
              (t (snapshot-write-disk bml-disk bml-memory)
                 (logior (ash bml-disk sys.int::+block-map-id-shift+)
                         sys.int::+block-map-present+)))
      (free-page bml-memory))))

(defun snapshot-bml2 (bml2)
  (snapshot-block-map-outer-level bml2 #'snapshot-bml1))

(defun snapshot-bml3 (bml3)
  (snapshot-block-map-outer-level bml3 #'snapshot-bml2))

(defun snapshot-bml4 (bml4)
  (snapshot-block-map-outer-level bml4 #'snapshot-bml3))

(defun snapshot-block-map ()
  (ash (snapshot-bml4 *bml4*) (- sys.int::+block-map-id-shift+)))

(defun take-snapshot ()
  (debug-write-line "Begin snapshot.")
  ;; TODO: Ensure there is a free area of at least 64kb in the wired area.
  ;; That should be enough to boot the system.
  (set-snapshot-light t)
  (setf *snapshot-pending-writeback-pages* nil
        *snapshot-pending-writeback-pages-count* 0)
  (let ((freelist-block nil)
        (bml4-block nil)
        (previously-deferred-free-blocks nil))
    ;; Stop the world before taking the *VM-LOCK*. There may be PA threads waiting for pages.
    (with-world-stopped
      (with-mutex (*vm-lock*)
        (debug-print-line "deferred blocks: " *store-freelist-n-deferred-free-blocks*)
        (debug-print-line "Copying wired area.")
        (snapshot-copy-wired-area)
        (debug-print-line "Marking dirty pages copy-on-write.")
        (snapshot-mark-cow-dirty-pages)
        ;; FIXME: Disk writes are slow and should be done outside WITH-WORLD-STOPPED.
        ;; FIXME!! Need to free the old block map & freelist.
        (debug-print-line "Updating block map.")
        (setf bml4-block (snapshot-block-map))
        (debug-print-line "Updating freelist.")
        (setf (values freelist-block previously-deferred-free-blocks)
              (snapshot-freelist))))
    (snapshot-write-back-pages)
    ;; Update the block map & freelist entries in the header.
    (debug-print-line "Updating disk header.")
    (let ((header (+ +physical-map-base+ (* (with-mutex (*vm-lock*)
                                              (pager-allocate-page :other))
                                            +4k-page-size+))))
      (disk-submit-request *snapshot-disk-request*
                           *paging-disk*
                           :read
                           0
                           (ceiling +4k-page-size+ (disk-sector-size *paging-disk*))
                           header)
      (unless (disk-await-request *snapshot-disk-request*)
        (panic "Unable to read header from disk"))
      (setf (sys.int::memref-unsigned-byte-64 (+ header +image-header-block-map+) 0) bml4-block)
      (setf (sys.int::memref-unsigned-byte-64 (+ header +image-header-freelist+) 0) freelist-block)
      (snapshot-write-disk 0 header)
      (free-page header))
    (with-mutex (*vm-lock*)
      (store-release-deferred-blocks previously-deferred-free-blocks)))
  (set-snapshot-light nil)
  (debug-write-line "End snapshot."))

(defun snapshot-thread ()
  (loop
     (when (zerop *snapshot-inhibit*)
       (take-snapshot))
     ;; After taking a snapshot, clear *snapshot-in-progress*
     ;; and go back to sleep.
     (sys.int::%cli)
     (%lock-thread sys.int::*snapshot-thread*)
     (setf *snapshot-in-progress* nil)
     (setf (thread-state sys.int::*snapshot-thread*) :sleeping
           (thread-wait-item sys.int::*snapshot-thread*) "Snapshot")
     (%reschedule)))

(defun initialize-snapshot ()
  (setf *snapshot-disk-request* (make-disk-request))
  (setf *snapshot-in-progress* nil)
  (setf *snapshot-inhibit* 1)
  ;; Allocate pages to copy the wired area into.
  ;; TODO: Use 2MB pages when possible.
  ;; ### when the wired area expands this will need to be something...
  (loop
     for wired-page from #x200000 below sys.int::*wired-area-bump* by #x1000
     ;; ### Could disable snapshotting if this can't be allocated.
     do (let* ((frame (allocate-physical-pages 1
                                               :mandatory-p "wired backing pages"
                                               :type :wired-backing))
               (pte (or (get-pte-for-address wired-page nil)
                        (panic "No page table entry for wired page " wired-page)))
               (page-frame (ash (sys.int::memref-unsigned-byte-64 pte 0) -12)))
          (setf (physical-page-frame-next page-frame) frame)
          (setf (physical-page-virtual-address frame) wired-page)))
  ;; ### same here.
  (setf *snapshot-bounce-buffer-page* (allocate-physical-pages 1
                                                               :mandatory-p "snapshot bounce page")))

(defun snapshot ()
  ;; Attempt to wake the snapshot thread, only waking it if
  ;; there is not snapshot currently in progress.
  (let ((did-wake (safe-without-interrupts ()
                    (with-thread-lock (sys.int::*snapshot-thread*)
                      (when (not *snapshot-in-progress*)
                        (setf *snapshot-in-progress* t)
                        (setf (thread-state sys.int::*snapshot-thread*) :runnable)
                        (with-symbol-spinlock (*global-thread-lock*)
                          (push-run-queue sys.int::*snapshot-thread*))
                        t)))))
    (when did-wake
      (thread-yield))))
