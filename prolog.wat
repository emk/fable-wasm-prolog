;; ============================================================
;; A tiny Prolog interpreter in WebAssembly (GC extensions)
;; ============================================================
;;
;; See PLAN.md and DESIGN_NOTES.md. The interpreter lives entirely
;; in this module: tokenizer, parser, printer, unification, and a
;; backtracking solver. Terms live on the WASM GC heap; a small
;; linear memory is used only to pass strings across the boundary.

(module
  ;; ----------------------------------------------------------
  ;; Linear memory: string I/O buffer only.
  ;; Host writes input at IN_BUF, module writes output at OUT_BUF.
  ;; ----------------------------------------------------------
  (memory (export "memory") 1)

  ;; Milestone-1 smoke test: allocate a GC struct and read it back,
  ;; proving the toolchain handles the GC extensions end to end.
  (type $box (struct (field $value i32)))

  (func (export "gc_smoke") (result i32)
    (struct.get $box $value
      (struct.new $box (i32.const 42))))
)
