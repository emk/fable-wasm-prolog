# Compile the WAT to a binary .wasm (for the web demo) and validate it.
build:
    wasm-tools parse prolog.wat -o prolog.wasm
    wasm-tools validate prolog.wasm

# Run the terminal REPL, optionally consulting files first.
repl *ARGS:
    cargo run --quiet -- {{ARGS}}

test:
    cargo test --quiet

# Serve the web demo (needs `just build` output).
serve: build
    cp prolog.wasm web/prolog.wasm
    python3 -m http.server -d web 8000
