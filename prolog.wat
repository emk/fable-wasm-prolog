;; ============================================================
;; A tiny Prolog interpreter in WebAssembly (GC extensions)
;; ============================================================
;;
;; The whole interpreter lives in this one module: tokenizer,
;; parser, printer, unification, and a backtracking solver.
;; Prolog terms live on the WASM GC heap; a small linear memory
;; is used only to pass strings across the host boundary.
;;
;; Host protocol:
;;   - write UTF-8 input at address 0 (IN_BUF, capacity 32768)
;;   - call an export with the input length
;;   - on status 0 (ok) or 3 (error), read `out_len` bytes of
;;     output text at address 32768 (OUT_BUF)
;;
;; Memory map:
;;      0 .. 32767   IN_BUF   input text from the host
;;  32768 .. 40959   OUT_BUF  output text for the host
;;  40960 .. ~41100  static strings (data segments below)

(module
  (memory (export "memory") 1)

  ;; ----------------------------------------------------------
  ;; Term representation
  ;; ----------------------------------------------------------
  ;;
  ;; There are only two kinds of term:
  ;;   $var  -- a logic variable, identified by a number. Two
  ;;            $var structs with the same id are the same
  ;;            variable; the struct is just a box for the id.
  ;;   $app  -- a functor applied to arguments: foo(bar, X).
  ;;            An atom is simply an $app with zero arguments,
  ;;            just as in real Prolog (foo = foo/0).
  ;;
  ;; Functor names are interned: $sym is an index into the
  ;; symbol table below, so comparing names is an i32 compare.
  ;;
  ;; Lists are ordinary terms: '.'(Head, Tail) pairs ending in
  ;; the atom [].  Only the parser and printer know about the
  ;; [a,b|T] sugar.
  ;;
  ;; The four types are mutually recursive, so they share a rec
  ;; group. We dispatch on the concrete type with ref.test.
  (rec
    (type $term (sub (struct)))
    (type $term-array (array (mut (ref $term))))
    (type $var (sub final $term (struct (field $id i32))))
    (type $app (sub final $term (struct (field $sym i32)
                                        (field $args (ref $term-array)))))
  )

  ;; A byte string on the GC heap (interned symbol names, etc).
  (type $str (array (mut i8)))
  ;; The symbol table: sym id -> name.
  (type $str-array (array (mut (ref null $str))))

  ;; A linked list of terms. Used for parsed argument lists and
  ;; (later) for goal lists in the solver.
  (type $tlist (struct (field $tl-head (ref $term))
                       (field $tl-tail (ref null $tlist))))

  ;; Variable name -> id mapping for the clause/query being
  ;; parsed ("X" must mean the same variable throughout one
  ;; clause). Kept after parsing a query so answers can be
  ;; printed as "X = ...".
  (type $vnames (struct (field $vn-name (ref $str))
                        (field $vn-id i32)
                        (field $vn-next (ref null $vnames))))

  ;; A substitution: an immutable association list mapping
  ;; variable ids to terms, exactly as in miniKanren. Extending
  ;; a substitution is consing; backtracking is just using an
  ;; older list, so nothing ever needs to be undone.
  (type $subst (struct (field $s-vid i32)
                       (field $s-val (ref $term))
                       (field $s-next (ref null $subst))))

  ;; One alternative in the search: "prove these goals under this
  ;; substitution". The solver's frontier is a stack of frames --
  ;; a miniKanren stream with the closures replaced by plain data.
  ;; Popping a frame after a dead end IS backtracking.
  (type $frame (struct (field $f-goals (ref null $tlist))
                       (field $f-subst (ref null $subst))
                       (field $f-next (ref null $frame))))

  ;; ----------------------------------------------------------
  ;; Static strings (see memory map above)
  ;; ----------------------------------------------------------
  (data (i32.const 40960) "[]")
  (data (i32.const 40962) ".")
  (data (i32.const 40963) "=")
  (data (i32.const 40964) "true")
  (data (i32.const 40968) " at byte ")
  (data (i32.const 40980) "unexpected character")
  (data (i32.const 41008) "unexpected token")
  (data (i32.const 41024) "expected ')'")
  (data (i32.const 41036) "expected ']'")
  (data (i32.const 41048) "expected '.'")
  (data (i32.const 41060) "output too long")
  (data (i32.const 41100) "unknown predicate ")
  (data (i32.const 41120) "cannot call an unbound variable")

  ;; ----------------------------------------------------------
  ;; Output buffer
  ;; ----------------------------------------------------------
  (global $out-pos (mut i32) (i32.const 32768))
  (global $out-overflow (mut i32) (i32.const 0))
  (global $out_len (export "out_len") (mut i32) (i32.const 0))

  (func $out-reset
    (global.set $out-pos (i32.const 32768))
    (global.set $out-overflow (i32.const 0)))

  (func $out-byte (param $b i32)
    (if (i32.ge_u (global.get $out-pos) (i32.const 40960))
      (then (global.set $out-overflow (i32.const 1)) (return)))
    (i32.store8 (global.get $out-pos) (local.get $b))
    (global.set $out-pos (i32.add (global.get $out-pos) (i32.const 1))))

  (func $out-mem (param $ptr i32) (param $len i32)
    (local $i i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (call $out-byte (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l))))

  (func $out-gcstr (param $s (ref $str))
    (local $i i32) (local $n i32)
    (local.set $n (array.len (local.get $s)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (call $out-byte (array.get_u $str (local.get $s) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l))))

  ;; Print a non-negative integer in decimal.
  (func $out-int (param $n i32)
    (if (i32.ge_u (local.get $n) (i32.const 10))
      (then (call $out-int (i32.div_u (local.get $n) (i32.const 10)))))
    (call $out-byte (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10)))))

  (func $out-finish
    (global.set $out_len (i32.sub (global.get $out-pos) (i32.const 32768))))

  ;; Place "<message>" / "<message> at byte <pos>" in OUT_BUF.
  (func $error (param $ptr i32) (param $len i32)
    (call $out-reset)
    (call $out-mem (local.get $ptr) (local.get $len))
    (call $out-finish))

  (func $error-at (param $ptr i32) (param $len i32) (param $at i32)
    (call $out-reset)
    (call $out-mem (local.get $ptr) (local.get $len))
    (call $out-mem (i32.const 40968) (i32.const 9)) ;; " at byte "
    (call $out-int (local.get $at))
    (call $out-finish))

  ;; ----------------------------------------------------------
  ;; Symbol table (interned functor/atom names)
  ;; ----------------------------------------------------------
  (global $syms (mut (ref $str-array))
    (array.new_default $str-array (i32.const 64)))
  (global $sym-count (mut i32) (i32.const 0))

  ;; Well-known symbols, interned by $init at instantiation.
  (global $sym-nil (mut i32) (i32.const 0))   ;; []
  (global $sym-dot (mut i32) (i32.const 0))   ;; '.' (list cons)
  (global $sym-eq (mut i32) (i32.const 0))    ;; =
  (global $sym-true (mut i32) (i32.const 0))  ;; true

  ;; Copy bytes out of linear memory into a fresh GC string.
  (func $mem-to-str (param $ptr i32) (param $len i32) (result (ref $str))
    (local $s (ref null $str)) (local $i i32)
    (local.set $s (array.new_default $str (local.get $len)))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (array.set $str (local.get $s) (local.get $i)
          (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (ref.as_non_null (local.get $s)))

  (func $str-eq-mem (param $s (ref $str)) (param $ptr i32) (param $len i32) (result i32)
    (local $i i32)
    (if (i32.ne (array.len (local.get $s)) (local.get $len))
      (then (return (i32.const 0))))
    (block $ne
      (block $done
        (loop $l
          (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
          (br_if $ne (i32.ne (array.get_u $str (local.get $s) (local.get $i))
                             (i32.load8_u (i32.add (local.get $ptr) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
      (return (i32.const 1)))
    (i32.const 0))

  ;; Return the symbol id for the name at [ptr, ptr+len) in
  ;; linear memory, adding it to the table on first sight.
  (func $intern (param $ptr i32) (param $len i32) (result i32)
    (local $i i32) (local $grown (ref null $str-array))
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (global.get $sym-count)))
        (if (call $str-eq-mem
              (ref.as_non_null (array.get $str-array (global.get $syms) (local.get $i)))
              (local.get $ptr) (local.get $len))
          (then (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (if (i32.eq (global.get $sym-count) (array.len (global.get $syms)))
      (then
        (local.set $grown (array.new_default $str-array
          (i32.mul (array.len (global.get $syms)) (i32.const 2))))
        (array.copy $str-array $str-array
          (local.get $grown) (i32.const 0)
          (global.get $syms) (i32.const 0) (global.get $sym-count))
        (global.set $syms (ref.as_non_null (local.get $grown)))))
    (array.set $str-array (global.get $syms) (global.get $sym-count)
      (call $mem-to-str (local.get $ptr) (local.get $len)))
    (global.set $sym-count (i32.add (global.get $sym-count) (i32.const 1)))
    (i32.sub (global.get $sym-count) (i32.const 1)))

  (func $sym-name (param $sym i32) (result (ref $str))
    (ref.as_non_null (array.get $str-array (global.get $syms) (local.get $sym))))

  (func $init
    (global.set $sym-nil (call $intern (i32.const 40960) (i32.const 2)))
    (global.set $sym-dot (call $intern (i32.const 40962) (i32.const 1)))
    (global.set $sym-eq (call $intern (i32.const 40963) (i32.const 1)))
    (global.set $sym-true (call $intern (i32.const 40964) (i32.const 4))))
  (start $init)

  ;; ----------------------------------------------------------
  ;; Term constructors
  ;; ----------------------------------------------------------
  (func $mk-atom (param $sym i32) (result (ref $app))
    (struct.new $app (local.get $sym) (array.new_fixed $term-array 0)))

  (func $mk-cons (param $h (ref $term)) (param $t (ref $term)) (result (ref $app))
    (struct.new $app (global.get $sym-dot)
      (array.new_fixed $term-array 2 (local.get $h) (local.get $t))))

  ;; ----------------------------------------------------------
  ;; Tokenizer
  ;; ----------------------------------------------------------
  ;;
  ;; Token kinds (in $tok after $advance):
  ;;   0 EOF   1 atom   2 variable   3 (   4 )   5 ,   6 |
  ;;   7 [     8 ]      9 .         10 :-  11 ?-  12 =  13 bad char
  ;; For atoms and variables the text is [tok-start, +tok-len)
  ;; in IN_BUF.
  (global $pos (mut i32) (i32.const 0))
  (global $end (mut i32) (i32.const 0))
  (global $tok (mut i32) (i32.const 0))
  (global $tok-start (mut i32) (i32.const 0))
  (global $tok-len (mut i32) (i32.const 0))

  (func $is-lower (param $c i32) (result i32)
    (i32.and (i32.ge_u (local.get $c) (i32.const 97))
             (i32.le_u (local.get $c) (i32.const 122))))
  (func $is-upper (param $c i32) (result i32)
    (i32.and (i32.ge_u (local.get $c) (i32.const 65))
             (i32.le_u (local.get $c) (i32.const 90))))
  (func $is-digit (param $c i32) (result i32)
    (i32.and (i32.ge_u (local.get $c) (i32.const 48))
             (i32.le_u (local.get $c) (i32.const 57))))
  (func $is-name-char (param $c i32) (result i32)
    (i32.or (i32.or (call $is-lower (local.get $c))
                    (call $is-upper (local.get $c)))
            (i32.or (call $is-digit (local.get $c))
                    (i32.eq (local.get $c) (i32.const 95))))) ;; _

  (func $scan-name
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (global.get $pos) (global.get $end)))
        (br_if $done (i32.eqz (call $is-name-char (i32.load8_u (global.get $pos)))))
        (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
        (br $l)))
    (global.set $tok-len (i32.sub (global.get $pos) (global.get $tok-start))))

  (func $advance
    (local $c i32)
    ;; Skip whitespace and % line comments.
    (block $ws-done
      (loop $ws
        (br_if $ws-done (i32.ge_u (global.get $pos) (global.get $end)))
        (local.set $c (i32.load8_u (global.get $pos)))
        (if (i32.or (i32.or (i32.eq (local.get $c) (i32.const 32))   ;; space
                            (i32.eq (local.get $c) (i32.const 9)))   ;; tab
                    (i32.or (i32.eq (local.get $c) (i32.const 10))   ;; \n
                            (i32.eq (local.get $c) (i32.const 13)))) ;; \r
          (then
            (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
            (br $ws)))
        (if (i32.eq (local.get $c) (i32.const 37)) ;; %
          (then
            (block $eol
              (loop $skip
                (br_if $eol (i32.ge_u (global.get $pos) (global.get $end)))
                (br_if $eol (i32.eq (i32.load8_u (global.get $pos)) (i32.const 10)))
                (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
                (br $skip)))
            (br $ws)))))
    (global.set $tok-start (global.get $pos))
    (global.set $tok-len (i32.const 0))
    (if (i32.ge_u (global.get $pos) (global.get $end))
      (then (global.set $tok (i32.const 0)) (return))) ;; EOF
    (local.set $c (i32.load8_u (global.get $pos)))
    (if (call $is-lower (local.get $c))
      (then (call $scan-name) (global.set $tok (i32.const 1)) (return)))
    (if (i32.or (call $is-upper (local.get $c)) (i32.eq (local.get $c) (i32.const 95)))
      (then (call $scan-name) (global.set $tok (i32.const 2)) (return)))
    (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
    (if (i32.eq (local.get $c) (i32.const 40)) ;; (
      (then (global.set $tok (i32.const 3)) (return)))
    (if (i32.eq (local.get $c) (i32.const 41)) ;; )
      (then (global.set $tok (i32.const 4)) (return)))
    (if (i32.eq (local.get $c) (i32.const 44)) ;; ,
      (then (global.set $tok (i32.const 5)) (return)))
    (if (i32.eq (local.get $c) (i32.const 124)) ;; |
      (then (global.set $tok (i32.const 6)) (return)))
    (if (i32.eq (local.get $c) (i32.const 91)) ;; [
      (then (global.set $tok (i32.const 7)) (return)))
    (if (i32.eq (local.get $c) (i32.const 93)) ;; ]
      (then (global.set $tok (i32.const 8)) (return)))
    (if (i32.eq (local.get $c) (i32.const 46)) ;; .
      (then (global.set $tok (i32.const 9)) (return)))
    (if (i32.eq (local.get $c) (i32.const 61)) ;; =
      (then (global.set $tok (i32.const 12)) (return)))
    (if (i32.eq (local.get $c) (i32.const 58)) ;; :  (looking for :-)
      (then
        (if (i32.and (i32.lt_u (global.get $pos) (global.get $end))
                     (i32.eq (i32.load8_u (global.get $pos)) (i32.const 45)))
          (then
            (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
            (global.set $tok (i32.const 10)) (return)))
        (global.set $tok (i32.const 13)) (return)))
    (if (i32.eq (local.get $c) (i32.const 63)) ;; ?  (looking for ?-)
      (then
        (if (i32.and (i32.lt_u (global.get $pos) (global.get $end))
                     (i32.eq (i32.load8_u (global.get $pos)) (i32.const 45)))
          (then
            (global.set $pos (i32.add (global.get $pos) (i32.const 1)))
            (global.set $tok (i32.const 11)) (return)))
        (global.set $tok (i32.const 13)) (return)))
    (global.set $tok (i32.const 13)))

  ;; ----------------------------------------------------------
  ;; Variables of the clause/query being parsed
  ;; ----------------------------------------------------------
  (global $var-names (mut (ref null $vnames)) (ref.null $vnames))
  (global $nvars (mut i32) (i32.const 0))

  (func $reset-vars
    (global.set $var-names (ref.null $vnames))
    (global.set $nvars (i32.const 0)))

  (func $fresh-var-id (result i32)
    (global.set $nvars (i32.add (global.get $nvars) (i32.const 1)))
    (i32.sub (global.get $nvars) (i32.const 1)))

  ;; "X" -> its id, allocating one the first time we see "X"
  ;; in the current clause.
  (func $lookup-var (param $ptr i32) (param $len i32) (result i32)
    (local $v (ref null $vnames)) (local $id i32)
    (local.set $v (global.get $var-names))
    (block $done
      (loop $l
        (br_if $done (ref.is_null (local.get $v)))
        (if (call $str-eq-mem (struct.get $vnames $vn-name (local.get $v))
                              (local.get $ptr) (local.get $len))
          (then (return (struct.get $vnames $vn-id (local.get $v)))))
        (local.set $v (struct.get $vnames $vn-next (local.get $v)))
        (br $l)))
    (local.set $id (call $fresh-var-id))
    (global.set $var-names
      (struct.new $vnames (call $mem-to-str (local.get $ptr) (local.get $len))
                          (local.get $id) (global.get $var-names)))
    (local.get $id))

  ;; ----------------------------------------------------------
  ;; Parser (recursive descent)
  ;; ----------------------------------------------------------
  ;;
  ;;   clause    := term [ ':-' goals ] '.'
  ;;   goals     := goal { ',' goal }
  ;;   goal      := term [ '=' term ]
  ;;   term      := VAR | ATOM [ '(' term { ',' term } ')' ] | list
  ;;   list      := '[' ']' | '[' term { ',' term } [ '|' term ] ']'
  ;;
  ;; Parse functions return null after stashing an error message
  ;; in OUT_BUF; callers just propagate the null upward.

  (func $parse-term (result (ref null $term))
    (local $sym i32) (local $id i32) (local $lst (ref null $tlist))
    ;; variable
    (if (i32.eq (global.get $tok) (i32.const 2))
      (then
        ;; a lone _ is anonymous: fresh and unnamed every time
        (if (i32.and (i32.eq (global.get $tok-len) (i32.const 1))
                     (i32.eq (i32.load8_u (global.get $tok-start)) (i32.const 95)))
          (then (local.set $id (call $fresh-var-id)))
          (else (local.set $id (call $lookup-var (global.get $tok-start) (global.get $tok-len)))))
        (call $advance)
        (return (struct.new $var (local.get $id)))))
    ;; atom or compound
    (if (i32.eq (global.get $tok) (i32.const 1))
      (then
        (local.set $sym (call $intern (global.get $tok-start) (global.get $tok-len)))
        (call $advance)
        (if (i32.ne (global.get $tok) (i32.const 3)) ;; no '(' -> plain atom
          (then (return (call $mk-atom (local.get $sym)))))
        (call $advance)
        (local.set $lst (call $parse-term-list))
        (if (ref.is_null (local.get $lst)) (then (return (ref.null $term))))
        (if (i32.ne (global.get $tok) (i32.const 4)) ;; )
          (then
            (call $error-at (i32.const 41024) (i32.const 12) (global.get $tok-start))
            (return (ref.null $term))))
        (call $advance)
        (return (struct.new $app (local.get $sym)
                  (call $tlist-to-array (local.get $lst))))))
    ;; list
    (if (i32.eq (global.get $tok) (i32.const 7)) ;; [
      (then
        (call $advance)
        (if (i32.eq (global.get $tok) (i32.const 8)) ;; ]
          (then (call $advance) (return (call $mk-atom (global.get $sym-nil)))))
        (return (call $parse-list-items))))
    (if (i32.eq (global.get $tok) (i32.const 13))
      (then (call $error-at (i32.const 40980) (i32.const 20) (global.get $tok-start)))
      (else (call $error-at (i32.const 41008) (i32.const 16) (global.get $tok-start))))
    (ref.null $term))

  ;; Inside '[': elements up to ']', desugaring to '.'/2 chains.
  (func $parse-list-items (result (ref null $term))
    (local $h (ref null $term)) (local $t (ref null $term))
    (local.set $h (call $parse-term))
    (if (ref.is_null (local.get $h)) (then (return (ref.null $term))))
    (if (i32.eq (global.get $tok) (i32.const 5)) ;; ,
      (then
        (call $advance)
        (local.set $t (call $parse-list-items))
        (if (ref.is_null (local.get $t)) (then (return (ref.null $term))))
        (return (call $mk-cons (ref.as_non_null (local.get $h))
                               (ref.as_non_null (local.get $t))))))
    (if (i32.eq (global.get $tok) (i32.const 6)) ;; |
      (then
        (call $advance)
        (local.set $t (call $parse-term))
        (if (ref.is_null (local.get $t)) (then (return (ref.null $term))))
        (if (i32.ne (global.get $tok) (i32.const 8)) ;; ]
          (then
            (call $error-at (i32.const 41036) (i32.const 12) (global.get $tok-start))
            (return (ref.null $term))))
        (call $advance)
        (return (call $mk-cons (ref.as_non_null (local.get $h))
                               (ref.as_non_null (local.get $t))))))
    (if (i32.eq (global.get $tok) (i32.const 8)) ;; ]
      (then
        (call $advance)
        (return (call $mk-cons (ref.as_non_null (local.get $h))
                               (call $mk-atom (global.get $sym-nil))))))
    (call $error-at (i32.const 41036) (i32.const 12) (global.get $tok-start))
    (ref.null $term))

  ;; term { ',' term } -- at least one, so null always = error.
  (func $parse-term-list (result (ref null $tlist))
    (local $h (ref null $term)) (local $rest (ref null $tlist))
    (local.set $h (call $parse-term))
    (if (ref.is_null (local.get $h)) (then (return (ref.null $tlist))))
    (if (i32.eq (global.get $tok) (i32.const 5)) ;; ,
      (then
        (call $advance)
        (local.set $rest (call $parse-term-list))
        (if (ref.is_null (local.get $rest)) (then (return (ref.null $tlist))))
        (return (struct.new $tlist (ref.as_non_null (local.get $h)) (local.get $rest)))))
    (struct.new $tlist (ref.as_non_null (local.get $h)) (ref.null $tlist)))

  ;; goal := term [ '=' term ]   ('=' is our only infix operator)
  (func $parse-goal (result (ref null $term))
    (local $l (ref null $term)) (local $r (ref null $term))
    (local.set $l (call $parse-term))
    (if (ref.is_null (local.get $l)) (then (return (ref.null $term))))
    (if (i32.eq (global.get $tok) (i32.const 12)) ;; =
      (then
        (call $advance)
        (local.set $r (call $parse-term))
        (if (ref.is_null (local.get $r)) (then (return (ref.null $term))))
        (return (struct.new $app (global.get $sym-eq)
          (array.new_fixed $term-array 2 (ref.as_non_null (local.get $l))
                                         (ref.as_non_null (local.get $r)))))))
    (local.get $l))

  ;; goal { ',' goal } -- at least one, so null always = error.
  (func $parse-goals (result (ref null $tlist))
    (local $h (ref null $term)) (local $rest (ref null $tlist))
    (local.set $h (call $parse-goal))
    (if (ref.is_null (local.get $h)) (then (return (ref.null $tlist))))
    (if (i32.eq (global.get $tok) (i32.const 5)) ;; ,
      (then
        (call $advance)
        (local.set $rest (call $parse-goals))
        (if (ref.is_null (local.get $rest)) (then (return (ref.null $tlist))))
        (return (struct.new $tlist (ref.as_non_null (local.get $h)) (local.get $rest)))))
    (struct.new $tlist (ref.as_non_null (local.get $h)) (ref.null $tlist)))

  (func $tlist-len (param $l (ref null $tlist)) (result i32)
    (local $n i32)
    (block $done
      (loop $lp
        (br_if $done (ref.is_null (local.get $l)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (local.set $l (struct.get $tlist $tl-tail (local.get $l)))
        (br $lp)))
    (local.get $n))

  (func $tlist-to-array (param $l (ref null $tlist)) (result (ref $term-array))
    (local $n i32) (local $i i32) (local $arr (ref null $term-array))
    (local.set $n (call $tlist-len (local.get $l)))
    (if (i32.eqz (local.get $n))
      (then (return (array.new_fixed $term-array 0))))
    (local.set $arr (array.new $term-array
      (struct.get $tlist $tl-head (local.get $l)) (local.get $n)))
    (block $done
      (loop $lp
        (br_if $done (ref.is_null (local.get $l)))
        (array.set $term-array (local.get $arr) (local.get $i)
          (struct.get $tlist $tl-head (local.get $l)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $l (struct.get $tlist $tl-tail (local.get $l)))
        (br $lp)))
    (ref.as_non_null (local.get $arr)))

  ;; ----------------------------------------------------------
  ;; Substitutions
  ;; ----------------------------------------------------------
  ;;
  ;; walk: resolve a term through the substitution until it is
  ;; either a non-variable or an unbound variable. The heart of
  ;; miniKanren.
  (func $walk (param $t (ref $term)) (param $s (ref null $subst)) (result (ref $term))
    (local $b (ref null $subst)) (local $id i32)
    (loop $again
      (if (i32.eqz (ref.test (ref $var) (local.get $t)))
        (then (return (local.get $t))))
      (local.set $id (struct.get $var $id (ref.cast (ref $var) (local.get $t))))
      (local.set $b (local.get $s))
      (block $rebound
        (loop $sl
          (if (ref.is_null (local.get $b))
            (then (return (local.get $t)))) ;; unbound variable
          (if (i32.eq (struct.get $subst $s-vid (local.get $b)) (local.get $id))
            (then
              (local.set $t (struct.get $subst $s-val (local.get $b)))
              (br $rebound)))
          (local.set $b (struct.get $subst $s-next (local.get $b)))
          (br $sl)))
      (br $again))
    (unreachable))

  ;; ----------------------------------------------------------
  ;; Unification
  ;; ----------------------------------------------------------
  ;;
  ;; $unify returns the (possibly extended) substitution, or the
  ;; unique sentinel $no-unify on failure. (Failure cannot be
  ;; null: null is the perfectly good *empty* substitution.)
  (global $no-unify (ref $subst)
    (struct.new $subst (i32.const -1)
                       (struct.new $var (i32.const -1))
                       (ref.null $subst)))

  ;; Does variable $id occur in $t? Real Prologs skip this check
  ;; for speed and let X = f(X) build a cyclic term; we do it the
  ;; miniKanren way so every term stays finite and printable.
  (func $occurs (param $id i32) (param $t (ref $term)) (param $s (ref null $subst)) (result i32)
    (local $args (ref null $term-array)) (local $n i32) (local $i i32)
    (local.set $t (call $walk (local.get $t) (local.get $s)))
    (if (ref.test (ref $var) (local.get $t))
      (then (return (i32.eq (struct.get $var $id (ref.cast (ref $var) (local.get $t)))
                            (local.get $id)))))
    (local.set $args (struct.get $app $args (ref.cast (ref $app) (local.get $t))))
    (local.set $n (array.len (local.get $args)))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (call $occurs (local.get $id)
                          (array.get $term-array (local.get $args) (local.get $i))
                          (local.get $s))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))

  (func $unify (param $t1 (ref $term)) (param $t2 (ref $term)) (param $s (ref null $subst))
               (result (ref null $subst))
    (local $a1 (ref null $app)) (local $a2 (ref null $app))
    (local $n i32) (local $i i32)
    (local.set $t1 (call $walk (local.get $t1) (local.get $s)))
    (local.set $t2 (call $walk (local.get $t2) (local.get $s)))
    ;; the same unbound variable on both sides: nothing to do
    (if (i32.and (ref.test (ref $var) (local.get $t1))
                 (ref.test (ref $var) (local.get $t2)))
      (then
        (if (i32.eq (struct.get $var $id (ref.cast (ref $var) (local.get $t1)))
                    (struct.get $var $id (ref.cast (ref $var) (local.get $t2))))
          (then (return (local.get $s))))))
    ;; unbound variable on either side: bind it
    (if (ref.test (ref $var) (local.get $t1))
      (then
        (if (call $occurs (struct.get $var $id (ref.cast (ref $var) (local.get $t1)))
                          (local.get $t2) (local.get $s))
          (then (return (global.get $no-unify))))
        (return (struct.new $subst
          (struct.get $var $id (ref.cast (ref $var) (local.get $t1)))
          (local.get $t2) (local.get $s)))))
    (if (ref.test (ref $var) (local.get $t2))
      (then
        (if (call $occurs (struct.get $var $id (ref.cast (ref $var) (local.get $t2)))
                          (local.get $t1) (local.get $s))
          (then (return (global.get $no-unify))))
        (return (struct.new $subst
          (struct.get $var $id (ref.cast (ref $var) (local.get $t2)))
          (local.get $t1) (local.get $s)))))
    ;; two applications: same functor, same arity, args unify
    (local.set $a1 (ref.cast (ref $app) (local.get $t1)))
    (local.set $a2 (ref.cast (ref $app) (local.get $t2)))
    (if (i32.ne (struct.get $app $sym (local.get $a1))
                (struct.get $app $sym (local.get $a2)))
      (then (return (global.get $no-unify))))
    (local.set $n (array.len (struct.get $app $args (local.get $a1))))
    (if (i32.ne (local.get $n) (array.len (struct.get $app $args (local.get $a2))))
      (then (return (global.get $no-unify))))
    (block $done
      (loop $lp
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $s (call $unify
          (array.get $term-array (struct.get $app $args (local.get $a1)) (local.get $i))
          (array.get $term-array (struct.get $app $args (local.get $a2)) (local.get $i))
          (local.get $s)))
        (if (ref.eq (local.get $s) (global.get $no-unify))
          (then (return (global.get $no-unify))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $s))

  ;; ----------------------------------------------------------
  ;; Printer
  ;; ----------------------------------------------------------
  (func $print-term (param $t (ref $term)) (param $s (ref null $subst))
    (local $a (ref null $app)) (local $args (ref null $term-array))
    (local $i i32) (local $n i32)
    (local.set $t (call $walk (local.get $t) (local.get $s)))
    (if (ref.test (ref $var) (local.get $t))
      (then
        (call $out-byte (i32.const 95)) ;; _
        (call $out-byte (i32.const 71)) ;; G
        (call $out-int (struct.get $var $id (ref.cast (ref $var) (local.get $t))))
        (return)))
    (local.set $a (ref.cast (ref $app) (local.get $t)))
    (local.set $args (struct.get $app $args (local.get $a)))
    (local.set $n (array.len (local.get $args)))
    ;; [a,b|T] sugar for '.'/2 chains
    (if (i32.and (i32.eq (struct.get $app $sym (local.get $a)) (global.get $sym-dot))
                 (i32.eq (local.get $n) (i32.const 2)))
      (then
        (call $print-list (ref.as_non_null (local.get $a)) (local.get $s))
        (return)))
    ;; A=B sugar (only reachable when printing goals)
    (if (i32.and (i32.eq (struct.get $app $sym (local.get $a)) (global.get $sym-eq))
                 (i32.eq (local.get $n) (i32.const 2)))
      (then
        (call $print-term (array.get $term-array (local.get $args) (i32.const 0)) (local.get $s))
        (call $out-byte (i32.const 61)) ;; =
        (call $print-term (array.get $term-array (local.get $args) (i32.const 1)) (local.get $s))
        (return)))
    (call $out-gcstr (call $sym-name (struct.get $app $sym (local.get $a))))
    (if (i32.eqz (local.get $n)) (then (return)))
    (call $out-byte (i32.const 40)) ;; (
    (block $done
      (loop $lp
        (call $print-term (array.get $term-array (local.get $args) (local.get $i)) (local.get $s))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (call $out-byte (i32.const 44)) ;; ,
        (br $lp)))
    (call $out-byte (i32.const 41))) ;; )

  ;; $a is a walked '.'/2 term.
  (func $print-list (param $a (ref $app)) (param $s (ref null $subst))
    (local $t (ref null $term)) (local $args (ref null $term-array))
    (call $out-byte (i32.const 91)) ;; [
    (loop $lp
      (local.set $args (struct.get $app $args (local.get $a)))
      (call $print-term (array.get $term-array (local.get $args) (i32.const 0)) (local.get $s))
      (local.set $t (call $walk (array.get $term-array (local.get $args) (i32.const 1))
                          (local.get $s)))
      (if (ref.test (ref $app) (local.get $t))
        (then
          ;; tail = [] : close the list
          (if (i32.and
                (i32.eq (struct.get $app $sym (ref.cast (ref $app) (local.get $t)))
                        (global.get $sym-nil))
                (i32.eqz (array.len (struct.get $app $args (ref.cast (ref $app) (local.get $t))))))
            (then (call $out-byte (i32.const 93)) (return))) ;; ]
          ;; tail = '.'/2 : another element
          (if (i32.and
                (i32.eq (struct.get $app $sym (ref.cast (ref $app) (local.get $t)))
                        (global.get $sym-dot))
                (i32.eq (array.len (struct.get $app $args (ref.cast (ref $app) (local.get $t))))
                        (i32.const 2)))
            (then
              (call $out-byte (i32.const 44)) ;; ,
              (local.set $a (ref.cast (ref $app) (local.get $t)))
              (br $lp)))))
      ;; anything else: improper list, print [a|Tail]
      (call $out-byte (i32.const 124)) ;; |
      (call $print-term (ref.as_non_null (local.get $t)) (local.get $s))
      (call $out-byte (i32.const 93)))) ;; ]

  ;; ----------------------------------------------------------
  ;; The solver
  ;; ----------------------------------------------------------
  ;;
  ;; One query is active at a time; its search state lives here.
  ;; Because the frontier is plain data, the host can pull one
  ;; solution at a time -- there is nothing to suspend or resume.
  (global $frontier (mut (ref null $frame)) (ref.null $frame))
  ;; The active query's variable names, for printing answers.
  (global $query-vars (mut (ref null $vnames)) (ref.null $vnames))
  ;; Fresh variable ids for renaming clauses apart, continuing
  ;; after the ids the query itself used.
  (global $var-counter (mut i32) (i32.const 0))

  (func $push-frame (param $goals (ref null $tlist)) (param $s (ref null $subst))
    (global.set $frontier
      (struct.new $frame (local.get $goals) (local.get $s) (global.get $frontier))))

  ;; Print one solution: "X = ...,\n..." for each named query
  ;; variable, or "true" if the query named none.
  (func $print-solution (param $s (ref null $subst))
    (call $out-reset)
    (if (ref.is_null (global.get $query-vars))
      (then (call $out-mem (i32.const 40964) (i32.const 4))) ;; "true"
      (else (call $print-bindings (ref.as_non_null (global.get $query-vars)) (local.get $s))))
    (call $out-finish))

  ;; $vnames lists names newest-first; recurse so they print in
  ;; order of first appearance.
  (func $print-bindings (param $v (ref $vnames)) (param $s (ref null $subst))
    (if (i32.eqz (ref.is_null (struct.get $vnames $vn-next (local.get $v))))
      (then
        (call $print-bindings (ref.as_non_null (struct.get $vnames $vn-next (local.get $v)))
                              (local.get $s))
        (call $out-byte (i32.const 44))    ;; ,
        (call $out-byte (i32.const 10))))  ;; \n
    (call $out-gcstr (struct.get $vnames $vn-name (local.get $v)))
    (call $out-byte (i32.const 32))
    (call $out-byte (i32.const 61)) ;; =
    (call $out-byte (i32.const 32))
    (call $print-term (struct.new $var (struct.get $vnames $vn-id (local.get $v)))
                      (local.get $s)))

  (func $error-unknown (param $sym i32) (param $arity i32)
    (call $out-reset)
    (call $out-mem (i32.const 41100) (i32.const 18)) ;; "unknown predicate "
    (call $out-gcstr (call $sym-name (local.get $sym)))
    (call $out-byte (i32.const 47)) ;; /
    (call $out-int (local.get $arity))
    (call $out-finish))

  ;; ----------------------------------------------------------
  ;; Exports
  ;; ----------------------------------------------------------
  ;; Statuses: 0 = solution/ok (text in OUT_BUF), 1 = no (more)
  ;; solutions, 2 = out of fuel (call query_next again),
  ;; 3 = error (message in OUT_BUF).

  ;; Parse a query ("?-" optional) and set up the search.
  (func (export "query_begin") (param $len i32) (result i32)
    (local $goals (ref null $tlist))
    (global.set $pos (i32.const 0))
    (global.set $end (local.get $len))
    (call $reset-vars)
    (global.set $frontier (ref.null $frame))
    (global.set $query-vars (ref.null $vnames))
    (call $advance)
    (if (i32.eq (global.get $tok) (i32.const 11)) ;; ?-
      (then (call $advance)))
    (local.set $goals (call $parse-goals))
    (if (ref.is_null (local.get $goals)) (then (return (i32.const 3))))
    (if (i32.ne (global.get $tok) (i32.const 9)) ;; .
      (then
        (call $error-at (i32.const 41048) (i32.const 12) (global.get $tok-start))
        (return (i32.const 3))))
    (global.set $query-vars (global.get $var-names))
    (global.set $var-counter (global.get $nvars))
    (call $push-frame (local.get $goals) (ref.null $subst))
    (i32.const 0))

  ;; Run the search until the next solution (or the end, or an
  ;; error, or $fuel exhausted frames -- so a slow query cannot
  ;; freeze the host; just call again to keep searching).
  (func (export "query_next") (param $fuel i32) (result i32)
    (local $goals (ref null $tlist)) (local $s (ref null $subst))
    (local $g (ref null $term)) (local $a (ref null $app))
    (local $args (ref null $term-array)) (local $s2 (ref null $subst))
    (loop $step
      (if (ref.is_null (global.get $frontier))
        (then (return (i32.const 1)))) ;; search space exhausted
      (if (i32.eqz (local.get $fuel))
        (then (return (i32.const 2)))) ;; out of fuel
      (local.set $fuel (i32.sub (local.get $fuel) (i32.const 1)))
      ;; pop the top alternative -- on a dead end, this is
      ;; exactly the backtracking step
      (local.set $goals (struct.get $frame $f-goals (global.get $frontier)))
      (local.set $s (struct.get $frame $f-subst (global.get $frontier)))
      (global.set $frontier (struct.get $frame $f-next (global.get $frontier)))
      ;; nothing left to prove: a solution
      (if (ref.is_null (local.get $goals))
        (then
          (call $print-solution (local.get $s))
          (return (i32.const 0))))
      (local.set $g (call $walk (struct.get $tlist $tl-head (local.get $goals))
                          (local.get $s)))
      (local.set $goals (struct.get $tlist $tl-tail (local.get $goals)))
      (if (ref.test (ref $var) (local.get $g))
        (then
          (call $error (i32.const 41120) (i32.const 31))
          (return (i32.const 3))))
      (local.set $a (ref.cast (ref $app) (local.get $g)))
      (local.set $args (struct.get $app $args (local.get $a)))
      ;; true/0 succeeds without binding anything
      (if (i32.and (i32.eq (struct.get $app $sym (local.get $a)) (global.get $sym-true))
                   (i32.eqz (array.len (local.get $args))))
        (then
          (call $push-frame (local.get $goals) (local.get $s))
          (br $step)))
      ;; =/2: unify, continue only if that succeeded
      (if (i32.and (i32.eq (struct.get $app $sym (local.get $a)) (global.get $sym-eq))
                   (i32.eq (array.len (local.get $args)) (i32.const 2)))
        (then
          (local.set $s2 (call $unify
            (array.get $term-array (local.get $args) (i32.const 0))
            (array.get $term-array (local.get $args) (i32.const 1))
            (local.get $s)))
          (if (i32.eqz (ref.eq (local.get $s2) (global.get $no-unify)))
            (then (call $push-frame (local.get $goals) (local.get $s2))))
          (br $step)))
      ;; user-defined predicates arrive with the clause database
      (call $error-unknown (struct.get $app $sym (local.get $a))
                           (array.len (local.get $args)))
      (return (i32.const 3)))
    (unreachable))

  ;; Test hook: parse one goal ending in '.', print it back.
  (func (export "roundtrip") (param $len i32) (result i32)
    (local $t (ref null $term))
    (global.set $pos (i32.const 0))
    (global.set $end (local.get $len))
    (call $reset-vars)
    (call $advance)
    (local.set $t (call $parse-goal))
    (if (ref.is_null (local.get $t)) (then (return (i32.const 3))))
    (if (i32.ne (global.get $tok) (i32.const 9)) ;; .
      (then
        (call $error-at (i32.const 41048) (i32.const 12) (global.get $tok-start))
        (return (i32.const 3))))
    (call $out-reset)
    (call $print-term (ref.as_non_null (local.get $t)) (ref.null $subst))
    (call $out-finish)
    (if (global.get $out-overflow)
      (then
        (call $error (i32.const 41060) (i32.const 15))
        (return (i32.const 3))))
    (i32.const 0))
)
