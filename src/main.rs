//! A terminal REPL for the WAT Prolog interpreter.
//!
//! Files named on the command line are consulted at startup.
//! At the `> ` prompt, input starting with `?-` runs as a query
//! (type `;` for the next answer, Enter to stop); anything else
//! is consulted as clauses. `halt.` exits.

use std::io::{self, Write};
use std::process::ExitCode;

use wasm_prolog::{
    Prolog, DEFAULT_FUEL, STATUS_NO_MORE, STATUS_OK, STATUS_OUT_OF_FUEL,
};

fn main() -> ExitCode {
    let mut prolog = match Prolog::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    for path in std::env::args().skip(1) {
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) => {
                eprintln!("error: cannot read {path}: {e}");
                return ExitCode::FAILURE;
            }
        };
        if let Err(e) = prolog.consult(&text) {
            eprintln!("error: {path}: {e}");
            return ExitCode::FAILURE;
        }
        eprintln!("% consulted {path}");
    }

    loop {
        print!("> ");
        let Some(line) = read_line() else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line == "halt." {
            break;
        }
        if line.starts_with("?-") {
            run_query(&mut prolog, line);
        } else if let Err(e) = prolog.consult(line) {
            println!("error: {e}");
        }
    }
    ExitCode::SUCCESS
}

fn run_query(prolog: &mut Prolog, query: &str) {
    let result = (|| {
        let (status, text) = prolog.query_begin(query)?;
        if status != STATUS_OK {
            println!("error: {text}");
            return Ok(());
        }
        loop {
            let (status, text) = prolog.query_next(DEFAULT_FUEL)?;
            match status {
                STATUS_OK => {
                    // print the answer and let the user ask for
                    // more with ';', just like a real Prolog
                    print!("{text} ");
                    io::stdout().flush()?;
                    match read_line() {
                        Some(line) if line.trim_start().starts_with(';') => continue,
                        _ => {
                            println!(".");
                            return Ok(());
                        }
                    }
                }
                STATUS_NO_MORE => {
                    println!("false.");
                    return Ok(());
                }
                STATUS_OUT_OF_FUEL => continue, // keep searching; Ctrl-C interrupts
                _ => {
                    println!("error: {text}");
                    return Ok(());
                }
            }
        }
    })();
    if let Err(e) = result {
        let e: wasmtime::Error = e;
        println!("error: {e}");
    }
}

fn read_line() -> Option<String> {
    let mut line = String::new();
    match io::stdin().read_line(&mut line) {
        Ok(0) => None, // EOF
        Ok(_) => Some(line),
        Err(_) => None,
    }
}
