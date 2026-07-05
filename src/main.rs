use std::io::{self, BufRead, Write};

use wasm_prolog::{Prolog, STATUS_OK};

/// Temporary driver while the solver is under construction:
/// parse each line as a goal and echo it back.
fn main() -> wasmtime::Result<()> {
    let mut prolog = Prolog::new()?;
    let stdin = io::stdin();
    print!("?- ");
    io::stdout().flush()?;
    for line in stdin.lock().lines() {
        let line = line?;
        if !line.trim().is_empty() {
            let (status, text) = prolog.roundtrip(&line)?;
            if status == STATUS_OK {
                println!("{text}");
            } else {
                println!("error: {text}");
            }
        }
        print!("?- ");
        io::stdout().flush()?;
    }
    println!();
    Ok(())
}
