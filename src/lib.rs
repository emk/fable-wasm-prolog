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
pub const STATUS_NO_MORE: i32 = 1;
pub const STATUS_OUT_OF_FUEL: i32 = 2;
pub const STATUS_ERROR: i32 = 3;

/// Frames the solver may pop per query_next call before it
/// hands control back (so hosts stay responsive).
pub const DEFAULT_FUEL: i32 = 1_000_000;

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

    /// Parse a Prolog program and add its clauses to the database.
    pub fn consult(&mut self, program: &str) -> Result<()> {
        let (status, text) = self.call_text("consult", program)?;
        if status == STATUS_ERROR {
            return Err(Error::msg(text));
        }
        Ok(())
    }

    /// Parse a query (the "?-" is optional) and set up the search.
    pub fn query_begin(&mut self, query: &str) -> Result<(i32, String)> {
        self.call_text("query_begin", query)
    }

    /// Search until the next solution, popping at most `fuel`
    /// alternatives before returning STATUS_OUT_OF_FUEL.
    pub fn query_next(&mut self, fuel: i32) -> Result<(i32, String)> {
        let f = self
            .instance
            .get_typed_func::<i32, i32>(&mut self.store, "query_next")?;
        let status = f.call(&mut self.store, fuel)?;
        Ok((status, self.read_output()?))
    }

    /// Convenience: run a query and collect up to `max` solutions.
    /// Interpreter-level failures (parse errors, unknown
    /// predicates) come back as Err.
    pub fn solutions(&mut self, query: &str, max: usize) -> Result<Vec<String>> {
        let (status, text) = self.query_begin(query)?;
        if status == STATUS_ERROR {
            return Err(Error::msg(text));
        }
        let mut found = Vec::new();
        while found.len() < max {
            let (status, text) = self.query_next(DEFAULT_FUEL)?;
            match status {
                STATUS_OK => found.push(text),
                STATUS_NO_MORE => break,
                STATUS_OUT_OF_FUEL => continue,
                _ => return Err(Error::msg(text)),
            }
        }
        Ok(found)
    }
}
