use wasm_prolog::Prolog;

#[test]
fn instantiates_with_gc() {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    assert_eq!(prolog.gc_smoke().unwrap(), 42);
}
