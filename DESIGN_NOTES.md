# Simple Prolog WASM interpreter

Basic design: A simple Prolog interpreter, roughly equivalent to the functionality of Mini-Kanren or _The Reasoned Schemer_, but using normal Prolog syntax. No cut support. Implementation language is WASM WAT, using the GC extensions, and the nested s-expression syntax variant for clarity. Interface is one or more exported Prolog functions.

Simplifying assumptions can and should be made. The goal is a _tiny_ Prolog interpreter, suitable for as learning tool (much like Mini-Kanren). The goal is to be recognizable as a Prolog implementation, and to show the core implementation ideas, much in the spirit of something like Mini-Kanren itself or one of the earlier Lisp interpreters in _Lisp in Small Pieces_. Prioritize simplicity and comprehensibility heavily. An anti-goal is to be a full implementation of any specific Prolog standard or to be useful for production Prolog work.

Available development tools include `wasm-tools` for compiling WAT syntax, Rust + the `wasmtime` crate with GC enabled for wrapping the WASM exports in a simple REPL loop, and `just` for Makefile-like tasks.

You will definitely want a test harness of some sort to help you as you work. This can be part of the Rust wrapper.
