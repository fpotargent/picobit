#lang racket

(require srfi/4) ; u8vector stuff
(require "utilities.rkt" "asm.rkt" "primitives.rkt")

(provide assemble)

;; These definitions must match those in the VM (in picobit-vm.h).
(define min-fixnum-encoding 3)
(define min-fixnum -1)
(define max-fixnum 256)
(define min-rom-encoding (+ min-fixnum-encoding (- max-fixnum min-fixnum) 1))
(define min-ram-encoding 1280)

(define code-start #x8000)

(define (predef-constants) (list))

(define (predef-globals) (list))

(define (encode-direct obj)
  (cond [(eq? obj #f)  0]
        [(eq? obj #t)  1]
        [(eq? obj '()) 2]
        [(and (exact-integer? obj)
              (<= min-fixnum obj max-fixnum))
         (+ obj (- min-fixnum-encoding min-fixnum))]
        [else #f])) ; can't encode directly

(define (translate-constant obj)
  (if (char? obj)
      (char->integer obj)
      obj))

(define (encode-constant obj constants)
  (let* ([o (translate-constant obj)]
         [e (encode-direct o)])
    (cond [e e] ; can be encoded directly
          [(assoc o constants)
           => (lambda (x) (vector-ref (cdr x) 0))]
          [else (compiler-error "unknown object" obj)])))

;; TODO actually, seem to be in a pair, scheme object in car, vector in cdr
;; constant objects are represented by vectors
;; 0 : encoding (ROM address) TODO really the ROM address ?
;; 1 : TODO asm label constant ?
;; 2 : number of occurences of this constant in the code
;; 3 : pointer to content, used at encoding time
(define (add-constant obj constants from-code?)
  (define o (translate-constant obj))
  (define e (encode-direct o))
  (cond [e constants] ; can be encoded directly
        [(dict-ref constants o #f) ; did we encode this already?
         =>
         (lambda (x)
           (when from-code? ; increment its reference counter
             (vector-set! x 2 (+ (vector-ref x 2) 1)))
           constants)]
        [else
         (define descr
           (vector #f
                   (asm-make-label 'constant)
                   (if from-code? 1 0)
                   #f))
         (define new-constants (dict-set constants o descr))
         (cond [(pair? o)
                ;; encode both parts as well
                (add-constants (list (car o) (cdr o)) new-constants)]
               [(symbol? o) new-constants] ; symbols don't store information
               [(string? o)
                ;; encode each character as well
                (let ([chars (map char->integer (string->list o))])
                  (vector-set! descr 3 chars)
                  (add-constant chars new-constants #f))]
               [(vector? o) ; ordinary vectors are stored as lists
                (let ([elems (vector->list o)])
                  (vector-set! descr 3 elems)
                  (add-constant elems new-constants #f))]
               [(u8vector? o) ; ROM u8vectors are lists as well, so O(n) access
                (let ([elems (u8vector->list o)])
                  (vector-set! descr 3 elems)
                  (add-constant elems new-constants #f))]
               [(exact-integer? o)
                (let ([hi (arithmetic-shift o -16)])
                  (vector-set! descr 3 hi)
                  ;; Recursion will stop once we reach 0 or -1 as the
                  ;; high part, which will be matched by encode-direct.
                  ;; Only the high part needs to be registered as a new
                  ;; constant. The low part will be filled in at
                  ;; encoding time.
                  (add-constant hi new-constants #f))]
               (else
                new-constants))]))

(define (add-constants objs constants)
  (for/fold ([constants constants])
      ([o objs])
    (add-constant o constants #f)))

(define (add-global var globals)
  (cond [(dict-ref globals var #f)
         =>
         (lambda (x)
           ;; increment reference counter
           (vector-set! x 1 (+ (vector-ref x 1) 1))
           globals)]
        [else (dict-set globals var (vector (length globals) 1))]))

(define (sort-constants constants)
  (let ([csts (sort constants > #:key (lambda (x) (vector-ref (cdr x) 2)))])
    (for ([i   (in-naturals min-rom-encoding)]
          [cst (in-list csts)])
      ;; Constants can use all the rom addresses up to 256 constants since
      ;; their number is encoded in a byte at the beginning of the bytecode.
      ;; The rest of the ROM encodings are used for the contents of these
      ;; constants.
      (when (or (> i min-ram-encoding) (> (- i min-rom-encoding) 256))
        (compiler-error "too many constants"))
      (vector-set! (cdr cst) 0 i))
    csts))

(define (sort-globals globals)
  (let ([glbs (sort globals > #:key (lambda (x) (vector-ref (cdr x) 1)))])
    (for ([i (in-naturals)]
          [g (in-list glbs)])
      (when (> i 256) ;; the number of globals is encoded in a byte
        (compiler-error "too many global variables"))
      (vector-set! (cdr g) 0 i))
    glbs))


;-----------------------------------------------------------------------------

(define instr-table (make-hash))
(define (inc-instr-count! k)
  (hash-update! instr-table k add1 (lambda () 0)))

(define (label-instr label
                     opcode-rel4 opcode-rel8 opcode-rel12 opcode-abs16
                     opcode-sym)
  (asm-at-assembly
   ;; Args are procedures that go 2 by 2.
   ;; The first one of each pair checks if a given strategy is applicable.
   ;; If so, it returns the size of the code to be generated, and the
   ;; second procedure of the pair generates code. Otherwise, the assembler
   ;; tries the next pair, and so on.

   ;; target is less than 16 bytecodes ahead:
   ;; 4 bit opcode, 4 bit operand
   (lambda (self)
     (let ([dist (- (asm-label-pos label) (+ self 1))])
       (and opcode-rel4 (<= 0 dist 15) 1))) ; size 1 byte total
   (lambda (self)
     (let ([dist (- (asm-label-pos label) (+ self 1))])
       (inc-instr-count! (list '---rel-4bit opcode-sym))
       (asm-8 (+ opcode-rel4 dist))))

   ;; distance is less than 128 in either direction:
   ;; 1 byte opcode, 1 byte operand
   (lambda (self)
     (let ([dist (+ 128 (- (asm-label-pos label) (+ self 2)))])
       (and opcode-rel8 (<= 0 dist 255) 2))) ; size 2 bytes total
   (lambda (self)
     (let ([dist (+ 128 (- (asm-label-pos label) (+ self 2)))])
       (inc-instr-count! (list '---rel-8bit opcode-sym))
       (asm-8 opcode-rel8)
       (asm-8 dist)))

   ;; distance is less than 2048 in either direction:
   ;; 4 bit opcode, 12 bit operand
   (lambda (self)
     (let ([dist (+ 2048 (- (asm-label-pos label) (+ self 2)))])
       (and opcode-rel12 (<= 0 dist 4095) 2))) ; size 2 bytes total
   (lambda (self)
     (let ([dist (+ 2048 (- (asm-label-pos label) (+ self 2)))])
       (inc-instr-count! (list '---rel-12bit opcode-sym))
       (asm-16 (+ (* opcode-rel12 256) dist))))

   ;; target is too far, fallback on absolute jump:
   ;; 1 byte opcode, 2 bytes operand
   (lambda (self)
     3) ; size 3 bytes total
   (lambda (self)
     (let ([pos (- (asm-label-pos label) code-start)])
       (inc-instr-count! (list '---abs-16bit opcode-sym))
       (asm-8 opcode-abs16)
       (asm-16 pos)))))

(define (push-constant n)
  (cond [(<= n 31) ; 3 bit opcode, 5 bit operand. first 32 constants.
         (inc-instr-count! '---push-constant-1byte)
         (asm-8 (+ #x00 n))]
        [else ; 4 bit opcode, 12 bits operand.
         (inc-instr-count! '---push-constant-2bytes)
         (asm-16 (+ #xa000 n))]))

(define (push-stack n)
  (if (> n 31) ; 3 bit opcode, 5 bits operand
      (compiler-error "stack is too deep")
      (asm-8 (+ #x20 n))))

(define (push-global n)
  (cond [(<= n 15) ; 4 bit opcode, 4 bit operand. first 16 globals.
         (inc-instr-count! '---push-global-1byte)
         (asm-8 (+ #x40 n))]
        [else ; 8 bit opcode, 8 bit operand. 256 globals max.
         (inc-instr-count! '---push-global-2bytes)
         (asm-8 #x8e)
         (asm-8 n)]))

(define (set-global n)
  (cond [(<= n 15) ; 4 bit opcode, 4 bit operand. first 16 globals.
         (inc-instr-count! '---set-global-1byte)
         (asm-8 (+ #x50 n))]
        [else ; 8 bit opcode, 8 bit operand. 256 globals max.
         (inc-instr-count! '---set-global-2bytes)
         (asm-8 #x8f)
         (asm-8 n)]))

(define (call n)
  (if (> n 15) ; 4 bit opcode, 4 bit argument (n of args to the call)
      (compiler-error "call has too many arguments")
      (asm-8 (+ #x60 n))))

(define (jump n)
  (if (> n 15) ; 4 bit opcode, 4 bit argument (n of args to the call)
      (compiler-error "call has too many arguments")
      (asm-8 (+ #x70 n))))

(define (call-toplevel label)
  (label-instr label #f   #xb5 #f #xb0 'call-toplevel))
(define (jump-toplevel label)
  (label-instr label #x80 #xb6 #f #xb1 'jump-toplevel))
(define (goto label)
  (label-instr label #f   #xb7 #f #xb2 'goto))
(define (goto-if-false label)
  (label-instr label #x90 #xb8 #f #xb3 'goto-if-false))
(define (closure label)
  (label-instr label #f   #xb9 #f #xb4 'closure))

(define (prim n) (asm-8 (+ #xc0 n)))

;-----------------------------------------------------------------------------

(define (assemble code hex-filename)
  (let loop1 ((lst code)
              (constants (predef-constants))
              (globals (predef-globals))
              (labels (list)))
    (if (pair? lst)

        (let ((instr (car lst)))
          (cond ((number? instr)
                 (loop1 (cdr lst)
                        constants
                        globals
                        (cons (cons instr (asm-make-label 'label))
                              labels)))
                ((eq? (car instr) 'push-constant)
                 (let ([new-constants
                        (add-constant (cadr instr) constants #t)])
                   (loop1 (cdr lst) new-constants globals labels)))
                ((memq (car instr) '(push-global set-global))
                 (let ([new-globals (add-global (cadr instr) globals)])
                   (loop1 (cdr lst) constants new-globals labels)))
                (else
                 (loop1 (cdr lst)
                        constants
                        globals
                        labels))))

        ;; Constants and globals are sorted by frequency of reference.
        ;; That way, the most often referred to constants and globals get
        ;; the lowest encodings. Low encodings mean that they can be
        ;; pushed/set with short instructions, reducing overall code size.
        (let ((constants (sort-constants constants))
              (globals   (sort-globals   globals)))

          (asm-begin! code-start #t)

          (asm-16 #xfbd7)
          (asm-8 (length constants))
          (asm-8 (length globals))

          (for-each
           (lambda (x)
             (let* ((descr (cdr x))
                    (label (vector-ref descr 1))
                    (obj (car x)))
               (asm-label label)
               ;; see the vm source for a description of encodings
               ;; TODO have comments here to explain encoding, at least magic number that give the type
               (cond ((and (integer? obj) (exact? obj))
                      (let ((hi (encode-constant (vector-ref descr 3)
                                                 constants)))
                        (asm-16 hi)    ; pointer to hi
                        (asm-16 obj))) ; bits 0-15
                     ((pair? obj)
                      (let ((obj-car (encode-constant (car obj) constants))
                            (obj-cdr (encode-constant (cdr obj) constants)))
                        (asm-16 (+ #x8000 obj-car))
                        (asm-16 (+ #x0000 obj-cdr))))
                     ((symbol? obj)
                      (asm-32 #x80002000))
                     ((string? obj)
                      (let ((obj-enc (encode-constant (vector-ref descr 3)
                                                      constants)))
                        (asm-16 (+ #x8000 obj-enc))
                        (asm-16 #x4000)))
                     ((vector? obj) ; ordinary vectors are stored as lists
                      (let* ((elems (vector-ref descr 3))
                             (obj-car (encode-constant (car elems)
                                                       constants))
                             (obj-cdr (encode-constant (cdr elems)
                                                       constants)))
                        (asm-16 (+ #x8000 obj-car))
                        (asm-16 (+ #x0000 obj-cdr))))
                     ((u8vector? obj)
                      (let ((obj-enc (encode-constant (vector-ref descr 3)
                                                      constants))
                            (l (length (vector-ref descr 3))))
                        ;; length is stored raw, not encoded as an object
                        ;; however, the bytes of content are encoded as
                        ;; fixnums
                        (asm-16 (+ #x8000 l))
                        (asm-16 (+ #x6000 obj-enc))))
                     (else
                      (compiler-error "unknown object type" obj)))))
           constants)

          (let loop2 ((lst code))
            (when (pair? lst)
              (let ((instr (car lst)))

                (when (and (stats?) (not (number? instr)))
                  (inc-instr-count! (car instr)))

                (cond ((number? instr)
                       (let ((label (cdr (assq instr labels))))
                         (asm-label label)))

                      ((eq? (car instr) 'entry)
                       (let ((np (cadr instr))
                             (rest? (caddr instr)))
                         (asm-8 (if rest? (- np) np))))

                      ((eq? (car instr) 'push-constant)
                       (let ((n (encode-constant (cadr instr) constants)))
                         (push-constant n)))

                      ((eq? (car instr) 'push-stack)
                       (push-stack (cadr instr)))

                      ((eq? (car instr) 'push-global)
                       (push-global (vector-ref
                                     (cdr (assq (cadr instr) globals))
                                     0)))

                      ((eq? (car instr) 'set-global)
                       (set-global (vector-ref
                                    (cdr (assq (cadr instr) globals))
                                    0)))

                      ((eq? (car instr) 'call)
                       (call (cadr instr)))

                      ((eq? (car instr) 'jump)
                       (jump (cadr instr)))

                      ((eq? (car instr) 'call-toplevel)
                       (let ((label (cdr (assq (cadr instr) labels))))
                         (call-toplevel label)))

                      ((eq? (car instr) 'jump-toplevel)
                       (let ((label (cdr (assq (cadr instr) labels))))
                         (jump-toplevel label)))

                      ((eq? (car instr) 'goto)
                       (let ((label (cdr (assq (cadr instr) labels))))
                         (goto label)))

                      ((eq? (car instr) 'goto-if-false)
                       (let ((label (cdr (assq (cadr instr) labels))))
                         (goto-if-false label)))

                      ((eq? (car instr) 'closure)
                       (let ((label (cdr (assq (cadr instr) labels))))
                         (closure label)))

                      ((eq? (car instr) 'prim)
                       (let ([p (cadr instr)])
                         (prim (dict-ref
                                primitive-encodings p
                                (lambda ()
                                  (compiler-error "unknown primitive" p))))))

                      ((eq? (car instr) 'return)
                       (prim 47))

                      ((eq? (car instr) 'pop)
                       (prim 46))

                      (else
                       (compiler-error "unknown instruction" instr)))

                (loop2 (cdr lst)))))

          (asm-assemble)

          (when (stats?)
            (pretty-print
             (sort (hash->list instr-table)
                   (lambda (x y) (> (cdr x) (cdr y))))))

          (begin0 (asm-write-hex-file hex-filename)
            (asm-end!))))))