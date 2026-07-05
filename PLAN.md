# Tiny Prolog interpreter in WASM GC (WAT)

## Context

Greenfield project per `DESIGN_NOTES.md`: a tiny Prolog interpreter — miniKanren/Reasoned-Schemer scale, normal Prolog syntax, no cut — written in hand-authored WAT using the WASM GC extensions (s-expression syntax). The goal is a comprehensible learning artifact, not a standards-compliant Prolog. Toolchain confirmed present: `wasm-tools` 1.252, `wasmtime` 46 (GC-capable), cargo 1.95, `just`.

Decisions settled with the user:
- **Everything in WAT** — tokenizer, parser, printer, and engine. The Rust wrapper is a super-thin REPL.
- **miniKanren-style engine** — immutable substitutions (assoc lists), no mutation/trail.
- **Features**: atoms, variables, compound terms, `=/2`, user-defined predicates, conjunction via `,`, and list syntax `[a,b|T]`. No integers, no extra builtins, no cut.
- **Pull-based answers** — no host callbacks (must also run on the web, so no sync-callback tricks). Search state is first-class data; host repeatedly calls `query_next()`.
- **String I/O via a small linear memory** — one page used as an in/out byte buffer; GC heap holds all terms. Trivial to drive from both Rust and JS.

## Architecture

### Term representation (WASM GC heap)

- Atoms are interned to `i32` symbol IDs via a growable symbol table (GC array of byte-array strings) in a global — makes atom comparison an integer compare and gives the printer a lookup table.
- A compound term with 0 args *is* an atom (like real Prolog: `foo` = `foo/0`), so there are only two term shapes, in a subtype hierarchy under an abstract `$term`:
  - `$var  {id: i32}`
  - `$app  {sym: i32, args: (ref $term-array)}`
  - Dispatch via `ref.test`/`ref.cast` (showcases GC extensions; types go in a `rec` group).
- Lists are ordinary terms: `'.'(H,T)` compounds ending in atom `[]` — the parser/printer provide the `[a,b|T]` sugar.

### Substitution & unification

- Substitution = immutable assoc list: `$binding {var-id, term, next}`; empty = null.
- `walk(term, subst)` resolves a variable through the substitution (as in miniKanren).
- `unify(t1, t2, subst) -> subst | failure`: walk both, bind var, or match sym/arity and recurse over args. **Include the occurs check** (miniKanren-style, ~15 lines) — a toy without it hangs the printer on `X = f(X)`; comment notes real Prologs skip it for speed.

### Solver: explicit-frontier DFS (defunctionalized miniKanren stream)

- Frontier = a stack (linked list) of alternatives: `$frame {goals: (ref $goal-list), subst, next}`.
- Engine state struct holds the mutable frontier plus the query's variable-name table (for answer printing). Held in a module global (one active query at a time — keeps the host from juggling GC refs).
- `step`: pop a frame. Empty goal list → **solution** (format bindings into the out buffer). Otherwise take the first goal:
  - `true/0` → push (rest, subst)
  - `'='(X,Y)` → unify; on success push (rest, s')
  - user predicate → for each clause of matching sym/arity: rename apart (fresh var IDs from a global counter; clause stores its var count), unify head with goal, on success push (clause-body ++ rest, s'). Push in reverse clause order so the first clause is tried first (LIFO frontier).
  - unknown predicate → error status ("unknown predicate foo/2").
- Clause database: linked list of `$clause {head, body: goal-array, nvars, next}` in a mutable global.
- **Fuel**: `query_next(max_steps)` counts frame pops; hitting the cap returns status "still searching, call again". Costs a few lines and keeps a browser tab responsive on runaway searches (and Ctrl-C still works in the terminal REPL).

### Parser & printer (in WAT)

- Tokenizer over the input bytes in linear memory: atoms (`lowercase` start, alnum/_), variables (`Uppercase`/`_` start), punctuation `( ) , | [ ] .`, operators `:-` `?-` `=`, and `%` line comments. Digit-leading tokens are a parse error (no integers per scope).
- Recursive-descent grammar (only infix operators: `=` in goals, `,` as conjunction — no general operator table):
  - clause := `term` [`:-` goal-list] `.`
  - query := goal-list `.` (the REPL strips the `?-`)
  - goal := term [`=` term]
  - term := var | atom [`(` term-list `)`] | `[` … `|` … `]`
- Per-clause variable scoping: name→id table during parsing; same name = same var within one clause/query. The query's table is kept for printing `X = …` answers.
- Printer: walk* the term through the substitution, write text into the out buffer; lists print as `[a,b|T]`; unbound vars as `_G<id>`; no-vars solution prints `true`.

### WASM interface (exports)

- `(memory (export "memory") 1)` — layout: input buffer at a fixed offset, output buffer at another.
- `consult(ptr, len) -> status` — parse & assert one or more clauses.
- `query_begin(ptr, len) -> status` — parse a query, initialize the engine global.
- `query_next(max_steps) -> status` — statuses: solution-ready / no-more-solutions / still-running / error. Solution or error text is in the out buffer; `out_len()` (or a packed return) gives its length.

### Rust wrapper (repo-root crate)

- wasmtime with `Config::wasm_gc(true)` + function references; loads `prolog.wat` **directly** (wasmtime's `wat` feature compiles WAT text at runtime — no build step needed for the REPL path).
- REPL: consult files given on argv, then read lines — `?- …` runs a query (`query_begin`, then `query_next` in a loop, printing each answer and prompting `;` / Enter); anything else is consulted. Print errors from the out buffer.
- **Test harness**: integration tests with a helper that instantiates the module, consults a program string, runs a query, and collects all answers as strings. Cases: term round-trips (parse→print), unification (incl. occurs check), backtracking order, `append`/`member`/`reverse`, a family-tree program, multiple-solutions via repeated `query_next`, parse errors, unknown predicates.

### Build & files

```
PLAN.md           — copy of this plan, committed for the record
prolog.wat        — the whole interpreter, one file, section banners + heavy comments
Cargo.toml, src/main.rs, tests/prolog.rs   — Rust crate at repo top level
justfile          — build (wasm-tools parse+validate → prolog.wasm), repl, test, serve
web/index.html    — minimal single-file web REPL (loads prolog.wasm, textarea + button)
README.md         — usage + a short tour of the implementation ideas
```

## Implementation milestones (each ends green)

0. **Repo setup**: `git init`; save this plan as `PLAN.md` in the working directory; commit. Commit at each milestone thereafter as a record and safety net.
1. **Scaffold**: justfile, Rust crate (at the repo top level), minimal WAT module (memory + a trivial export) instantiated by wasmtime with GC on; one smoke test.
2. **Terms + parse/print**: GC types, symbol table, tokenizer, parser, printer; a temporary `roundtrip(ptr,len)` export; round-trip tests.
3. **Unification + minimal engine**: substitutions, walk, unify, frontier, `query_begin`/`query_next` with only `=/2` and `true`. Test: `?- X = foo(Y), Y = bar.`
4. **Clause database**: `consult`, rename-apart, user predicate expansion, full backtracking. The classic test suite (append/member/family) passes.
5. **REPL polish**: `;` interaction, argv file loading, readable errors, fuel status handling; drop the temporary roundtrip export or keep it behind tests.
6. **Web demo**: `just build` produces `prolog.wasm`; `web/index.html` with ~50 lines of JS (same 4 exports); `just serve`.
7. **README** with examples and an implementation tour.

## Verification

- `just test` — the Rust integration suite above is the primary harness (per DESIGN_NOTES).
- `wasm-tools validate --features gc prolog.wasm` wired into `just build` as a lint.
- Manual end-to-end: `just repl examples/family.pl`, run `?- ancestor(X, cathy).`, step with `;`.
- Web: `just serve`, load the page in a browser, run the same query.

## Notes / risks

- WAT GC syntax specifics (rec groups, `sub`, `ref.cast`, array ops) get exercised in milestones 1–2, so syntax surprises surface early and cheaply.
- Left-recursive programs loop forever — authentic Prolog DFS behavior; the fuel mechanism keeps hosts responsive rather than "fixing" it.
- Web page needs a WasmGC-capable browser (all current majors) — noted in README.
