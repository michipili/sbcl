;;;; the VM definition of various primitive memory access VOPs for the
;;;; ARM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;;; Data object ref/set stuff.

(define-vop (slot)
  (:args (object :scs (descriptor-reg)))
  (:info name offset lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg any-reg)))
  (:generator 1
    (loadw result object offset lowtag)))

(define-vop (set-slot)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:info name offset lowtag)
  (:ignore name)
  (:results)
  (:generator 1
    (storew value object offset lowtag)))

(define-vop (init-slot set-slot))

;;;; Symbol hacking VOPs:

;;; The compiler likes to be able to directly SET symbols.
;;;
(define-vop (set cell-set)
  (:variant symbol-value-slot other-pointer-lowtag))

;;; Do a cell ref with an error check for being unbound.
;;;
(define-vop (checked-cell-ref)
  (:args (object :scs (descriptor-reg) :target obj-temp))
  (:results (value :scs (descriptor-reg any-reg)))
  (:policy :fast-safe)
  (:vop-var vop)
  (:save-p :compute-only)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) obj-temp))

;;; With Symbol-Value, we check that the value isn't the trap object.  So
;;; Symbol-Value of NIL is NIL.
;;;
(define-vop (symbol-value checked-cell-ref)
  (:translate symbol-value)
  (:generator 9
    (move obj-temp object)
    (loadw value obj-temp symbol-value-slot other-pointer-lowtag)
    (let ((err-lab (generate-error-code vop 'unbound-symbol-error obj-temp)))
      (inst cmp value unbound-marker-widetag)
      (inst b :eq err-lab))))

;;; Like CHECKED-CELL-REF, only we are a predicate to see if the cell is bound.
(define-vop (boundp-frob)
  (:args (object :scs (descriptor-reg)))
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe)
  (:temporary (:scs (descriptor-reg)) value))

(define-vop (boundp boundp-frob)
  (:translate boundp)
  (:generator 9
    (loadw value object symbol-value-slot other-pointer-lowtag)
    (inst cmp value unbound-marker-widetag)
    (inst b (if not-p :eq :ne) target)))

(define-vop (fast-symbol-value cell-ref)
  (:variant symbol-value-slot other-pointer-lowtag)
  (:policy :fast)
  (:translate symbol-value))

(define-vop (symbol-hash)
  (:policy :fast-safe)
  (:translate symbol-hash)
  (:args (symbol :scs (descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:results (res :scs (any-reg)))
  (:result-types positive-fixnum)
  (:generator 2
    ;; The symbol-hash slot of NIL holds NIL because it is also the
    ;; cdr slot, so we have to strip off the two low bits to make sure
    ;; it is a fixnum.  The lowtag selection magic that is required to
    ;; ensure this is explained in the comment in objdef.lisp
    (loadw temp symbol symbol-hash-slot other-pointer-lowtag)
    (inst and res temp (bic-mask fixnum-tag-mask))))

;;; On unithreaded builds these are just copies of the non-global versions.
(define-vop (%set-symbol-global-value set))
(define-vop (symbol-global-value symbol-value)
  (:translate symbol-global-value))
(define-vop (fast-symbol-global-value fast-symbol-value)
  (:translate symbol-global-value))

;;;; Fdefinition (fdefn) objects.

(define-vop (fdefn-fun cell-ref)
  (:variant fdefn-fun-slot other-pointer-lowtag))

(define-vop (safe-fdefn-fun)
  (:translate safe-fdefn-fun)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :save))
  (:results (value :scs (descriptor-reg any-reg)))
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 10
    (loadw value object fdefn-fun-slot other-pointer-lowtag)
    (inst cmp value null-tn)
    (let ((err-lab (generate-error-code vop 'undefined-fun-error object)))
      (inst b :eq err-lab))))

(define-vop (set-fdefn-fun)
  (:policy :fast-safe)
  (:translate (setf fdefn-fun))
  (:args (function :scs (descriptor-reg) :target result)
         (fdefn :scs (descriptor-reg)))
  (:temporary (:scs (interior-reg)) lip)
  (:temporary (:scs (non-descriptor-reg)) type)
  (:results (result :scs (descriptor-reg)))
  (:generator 38
    (let ((closure-tramp-fixup (gen-label)))
      (assemble (*elsewhere*)
        (emit-label closure-tramp-fixup)
        (inst dword (make-fixup "closure_tramp" :foreign)))
      (assemble ()
        (inst add lip function (- (* simple-fun-code-offset n-word-bytes)
                                  fun-pointer-lowtag))
        (load-type type function (- fun-pointer-lowtag))
        (inst cmp type simple-fun-header-widetag)
        (inst b :eq SIMPLE-FUN)
        (inst load-from-label lip closure-tramp-fixup)
        SIMPLE-FUN
        (storew lip fdefn fdefn-raw-addr-slot other-pointer-lowtag)
        (storew function fdefn fdefn-fun-slot other-pointer-lowtag)
        (move result function)))))

(define-vop (fdefn-makunbound)
  (:policy :fast-safe)
  (:translate fdefn-makunbound)
  (:args (fdefn :scs (descriptor-reg) :target result))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:results (result :scs (descriptor-reg)))
  (:generator 38
    (let ((undefined-tramp-fixup (gen-label)))
      (assemble (*elsewhere*)
        (emit-label undefined-tramp-fixup)
        (inst dword (make-fixup "undefined_tramp" :foreign)))
      (storew null-tn fdefn fdefn-fun-slot other-pointer-lowtag)
      (inst load-from-label temp undefined-tramp-fixup)
      (storew temp fdefn fdefn-raw-addr-slot other-pointer-lowtag)
      (move result fdefn))))



;;;; Binding and Unbinding.

;;; BIND -- Establish VAL as a binding for SYMBOL.  Save the old value and
;;; the symbol on the binding stack and stuff the new value into the
;;; symbol.

(define-vop (bind)
  (:args (val :scs (any-reg descriptor-reg))
         (symbol :scs (descriptor-reg)))
  (:temporary (:scs (descriptor-reg)) value-temp)
  (:temporary (:scs (any-reg)) bsp-temp)
  (:generator 5
    (loadw value-temp symbol symbol-value-slot other-pointer-lowtag)
    (load-symbol-value bsp-temp *binding-stack-pointer*)
    (inst add bsp-temp bsp-temp (* binding-size n-word-bytes))
    (store-symbol-value bsp-temp *binding-stack-pointer*)
    (inst stp value-temp symbol (@ bsp-temp (* (- binding-value-slot binding-size) n-word-bytes)))
    (storew val symbol symbol-value-slot other-pointer-lowtag)))

(define-vop (unbind)
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:temporary (:scs (any-reg)) bsp-temp)
  (:generator 0
    (load-symbol-value bsp-temp *binding-stack-pointer*)
    (loadw symbol bsp-temp (- binding-symbol-slot binding-size))
    (loadw value bsp-temp (- binding-value-slot binding-size))
    (storew value symbol symbol-value-slot other-pointer-lowtag)
    ;; The order of stores here is reversed with respect to interrupt safety,
    ;; but STP cannot be interrupted in the middle.
    (inst stp zr-tn zr-tn (@ bsp-temp (* (- binding-value-slot binding-size)
                                                  n-word-bytes)))
    (inst sub bsp-temp bsp-temp (* binding-size n-word-bytes))
    (store-symbol-value bsp-temp *binding-stack-pointer*)))

(define-vop (unbind-to-here)
  (:args (arg :scs (descriptor-reg any-reg) :target where))
  (:temporary (:scs (any-reg) :from (:argument 0)) where)
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:temporary (:scs (any-reg)) bsp-temp)
  (:generator 0
    (load-symbol-value bsp-temp *binding-stack-pointer*)
    (move where arg)
    (inst cmp where bsp-temp)
    (inst b :eq DONE)

    LOOP
    (inst ldp value symbol (@ bsp-temp (* (- binding-value-slot binding-size)
                                          n-word-bytes)))
    (inst cbz symbol ZERO)

    (storew value symbol symbol-value-slot other-pointer-lowtag)
    ZERO
    (inst stp zr-tn zr-tn (@ bsp-temp (* (- binding-value-slot binding-size)
                                                n-word-bytes)
                                             :post-index))

    (inst cmp where bsp-temp)
    (inst b :ne LOOP)

    DONE
    (store-symbol-value bsp-temp *binding-stack-pointer*)))

;;;; Closure indexing.

(define-full-reffer closure-index-ref *
  closure-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg) * %closure-index-ref)

(define-full-setter set-funcallable-instance-info *
  funcallable-instance-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg null) * %set-funcallable-instance-info)

(define-full-reffer funcallable-instance-info *
  funcallable-instance-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg) * %funcallable-instance-info)

(define-vop (closure-ref slot-ref)
  (:variant closure-info-offset fun-pointer-lowtag))

(define-vop (closure-init slot-set)
  (:variant closure-info-offset fun-pointer-lowtag))

(define-vop (closure-init-from-fp)
  (:args (object :scs (descriptor-reg)))
  (:info offset)
  (:generator 4
    (storew cfp-tn object (+ closure-info-offset offset) fun-pointer-lowtag)))

;;;; Value Cell hackery.

(define-vop (value-cell-ref cell-ref)
  (:variant value-cell-value-slot other-pointer-lowtag))

(define-vop (value-cell-set cell-set)
  (:variant value-cell-value-slot other-pointer-lowtag))

;;;; Instance hackery:

(define-vop (instance-length)
  (:policy :fast-safe)
  (:translate %instance-length)
  (:args (struct :scs (descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 4
    (loadw temp struct 0 instance-pointer-lowtag)
    (inst lsr res temp n-widetag-bits)))

(define-full-reffer instance-index-ref * instance-slots-offset
  instance-pointer-lowtag (descriptor-reg any-reg) * %instance-ref)

(define-full-setter instance-index-set * instance-slots-offset
  instance-pointer-lowtag (descriptor-reg any-reg null) * %instance-set)

;;;; Code object frobbing.

(define-full-reffer code-header-ref * 0 other-pointer-lowtag
  (descriptor-reg any-reg) * code-header-ref)

(define-full-setter code-header-set * 0 other-pointer-lowtag
  (descriptor-reg any-reg null) * code-header-set)

;;;; raw instance slot accessors

(macrolet
    ((define-raw-slot-vops (name value-primtype value-sc
                                 &key (width 1) (move-macro 'move))
       (labels ((emit-generator (instruction move-result)
                  `((loadw offset object 0 instance-pointer-lowtag)
                    (inst lsr offset offset n-widetag-bits)
                    (inst lsl offset offset word-shift)
                    (inst sub offset offset (lsl index (- word-shift n-fixnum-tag-bits)))
                    (inst sub offset offset (+ (* (- ,width
                                                     instance-slots-offset)
                                                  n-word-bytes)
                                               instance-pointer-lowtag))
                    (inst ,instruction value (@ object offset))
                    ,@(when move-result
                        `((,move-macro result value))))))
         (let ((ref-vop (symbolicate "RAW-INSTANCE-REF/" name))
               (set-vop (symbolicate "RAW-INSTANCE-SET/" name)))
           `(progn
              (define-vop (,ref-vop)
                (:translate ,(symbolicate "%" ref-vop))
                (:policy :fast-safe)
                (:args (object :scs (descriptor-reg))
                       (index :scs (any-reg)))
                (:arg-types * positive-fixnum)
                (:results (value :scs (,value-sc)))
                (:result-types ,value-primtype)
                (:temporary (:scs (non-descriptor-reg)) offset)
                (:generator 5 ,@(emit-generator 'ldr nil)))
              (define-vop (,set-vop)
                (:translate ,(symbolicate "%" set-vop))
                (:policy :fast-safe)
                (:args (object :scs (descriptor-reg))
                       (index :scs (any-reg))
                       (value :scs (,value-sc) :target result))
                (:arg-types * positive-fixnum ,value-primtype)
                (:results (result :scs (,value-sc)))
                (:result-types ,value-primtype)
                (:temporary (:scs (non-descriptor-reg)) offset)
                (:generator 5 ,@(emit-generator 'str t))))))))
  (define-raw-slot-vops word unsigned-num unsigned-reg)
  (define-raw-slot-vops single single-float single-reg
     :move-macro move-float)
  (define-raw-slot-vops double double-float double-reg
     :move-macro move-float)
  (define-raw-slot-vops complex-single complex-single-float complex-single-reg
    :move-macro move-float)
  (define-raw-slot-vops complex-double complex-double-float complex-double-reg
     :width 2 :move-macro move-complex-double))