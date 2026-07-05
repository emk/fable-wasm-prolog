//! Thin wasmtime wrapper around the WAT Prolog interpreter.
//!
//! All the interesting logic is in `prolog.wat`; this crate just
//! instantiates it and shuttles strings through its linear memory.

use wasmtime::{Config, Engine, Instance, Module, Result, Store};

pub struct Prolog {
    store: Store<()>,
    instance: Instance,
}

impl Prolog {
    pub fn new() -> Result<Prolog> {
        let mut config = Config::new();
        config.wasm_function_references(true).wasm_gc(true);
        let engine = Engine::new(&config)?;
        let wat_path = concat!(env!("CARGO_MANIFEST_DIR"), "/prolog.wat");
        let module = Module::from_file(&engine, wat_path)?;
        let mut store = Store::new(&engine, ());
        let instance = Instance::new(&mut store, &module, &[])?;
        Ok(Prolog { store, instance })
    }

    pub fn gc_smoke(&mut self) -> Result<i32> {
        let f = self
            .instance
            .get_typed_func::<(), i32>(&mut self.store, "gc_smoke")?;
        f.call(&mut self.store, ())
    }
}
