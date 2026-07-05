//! Thin wasmtime wrapper around the WAT Prolog interpreter.
//!
//! All the interesting logic is in `prolog.wat`; this crate just
//! instantiates it and shuttles strings through its linear memory.

use wasmtime::{Config, Engine, Error, Instance, Module, Result, Store};

/// Where the module expects input text, and where it leaves output
/// text (see the memory map comment in prolog.wat).
const IN_BUF: usize = 0;
const IN_CAP: usize = 32768;
const OUT_BUF: usize = 32768;

/// Status codes shared with prolog.wat.
pub const STATUS_OK: i32 = 0;
pub const STATUS_ERROR: i32 = 3;

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

    /// Write `input` to IN_BUF, call the export `name` with its
    /// length, and return (status, output text from OUT_BUF).
    fn call_text(&mut self, name: &str, input: &str) -> Result<(i32, String)> {
        if input.len() > IN_CAP {
            return Err(Error::msg("input too long for the interpreter's buffer"));
        }
        let memory = self
            .instance
            .get_memory(&mut self.store, "memory")
            .ok_or_else(|| Error::msg("no exported memory"))?;
        memory.write(&mut self.store, IN_BUF, input.as_bytes())?;
        let f = self
            .instance
            .get_typed_func::<i32, i32>(&mut self.store, name)?;
        let status = f.call(&mut self.store, input.len() as i32)?;
        Ok((status, self.read_output()?))
    }

    fn read_output(&mut self) -> Result<String> {
        let memory = self
            .instance
            .get_memory(&mut self.store, "memory")
            .ok_or_else(|| Error::msg("no exported memory"))?;
        let out_len = self
            .instance
            .get_global(&mut self.store, "out_len")
            .ok_or_else(|| Error::msg("no out_len global"))?
            .get(&mut self.store)
            .i32()
            .ok_or_else(|| Error::msg("out_len is not an i32"))? as usize;
        let mut buf = vec![0u8; out_len];
        memory.read(&self.store, OUT_BUF, &mut buf)?;
        Ok(String::from_utf8_lossy(&buf).into_owned())
    }

    /// Test hook: parse one goal and print it back.
    pub fn roundtrip(&mut self, input: &str) -> Result<(i32, String)> {
        self.call_text("roundtrip", input)
    }
}
