use wasm_prolog::Prolog;
use wasmtime::Result;

fn main() -> Result<()> {
    let mut prolog = Prolog::new()?;
    println!("gc_smoke() = {}", prolog.gc_smoke()?);
    Ok(())
}
