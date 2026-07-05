use wasm_prolog::{Prolog, STATUS_ERROR, STATUS_OK};

/// Parse a goal and print it back; panic on interpreter errors.
fn rt(input: &str) -> String {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    let (status, text) = prolog.roundtrip(input).unwrap();
    assert_eq!(status, STATUS_OK, "unexpected error for {input:?}: {text}");
    text
}

/// Parse a goal expecting a parse error; return the message.
fn rt_err(input: &str) -> String {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    let (status, text) = prolog.roundtrip(input).unwrap();
    assert_eq!(status, STATUS_ERROR, "expected error for {input:?}, got: {text}");
    text
}

#[test]
fn roundtrip_atoms_and_compounds() {
    assert_eq!(rt("foo."), "foo");
    assert_eq!(rt("foo(bar,baz)."), "foo(bar,baz)");
    assert_eq!(rt("foo( bar , baz )."), "foo(bar,baz)");
    assert_eq!(rt("f(g(h(x)))."), "f(g(h(x)))");
    assert_eq!(rt("true."), "true");
}

#[test]
fn roundtrip_variables() {
    assert_eq!(rt("X."), "_G0");
    assert_eq!(rt("f(X,Y,X)."), "f(_G0,_G1,_G0)");
    // each _ is a distinct fresh variable
    assert_eq!(rt("f(_,_)."), "f(_G0,_G1)");
    assert_eq!(rt("f(_Acc,_Acc)."), "f(_G0,_G0)");
}

#[test]
fn roundtrip_lists() {
    assert_eq!(rt("[]."), "[]");
    assert_eq!(rt("[a]."), "[a]");
    assert_eq!(rt("[a,b,c]."), "[a,b,c]");
    assert_eq!(rt("[a|T]."), "[a|_G0]");
    assert_eq!(rt("[a,b|T]."), "[a,b|_G0]");
    // sugar normalizes: an explicit tail list prints flattened
    assert_eq!(rt("[a,b|[c,d]]."), "[a,b,c,d]");
    assert_eq!(rt("[a|[]]."), "[a]");
    assert_eq!(rt("[[a,b],[c]]."), "[[a,b],[c]]");
    // improper list
    assert_eq!(rt("[a|b]."), "[a|b]");
}

#[test]
fn roundtrip_equals_goal() {
    assert_eq!(rt("X = f(X)."), "_G0=f(_G0)");
    assert_eq!(rt("[H|T] = [a,b]."), "[_G0|_G1]=[a,b]");
}

#[test]
fn comments_and_whitespace() {
    assert_eq!(rt("% a comment\n  foo(  X ). % trailing"), "foo(_G0)");
}

/// Run a query and collect all solutions (up to 100).
fn solve(query: &str) -> Vec<String> {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    prolog.solutions(query, 100).unwrap()
}

fn solve_err(query: &str) -> String {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    prolog.solutions(query, 100).unwrap_err().to_string()
}

#[test]
fn query_true_and_unification() {
    assert_eq!(solve("?- true."), ["true"]);
    assert_eq!(solve("?- foo = foo."), ["true"]);
    assert_eq!(solve("?- foo = bar."), Vec::<String>::new());
    assert_eq!(solve("?- X = foo."), ["X = foo"]);
    assert_eq!(solve("X = foo."), ["X = foo"]); // ?- is optional
}

#[test]
fn query_conjunction_chains_bindings() {
    assert_eq!(solve("?- X = foo(Y), Y = bar."), ["X = foo(bar),\nY = bar"]);
    assert_eq!(solve("?- X = a, X = b."), Vec::<String>::new());
    assert_eq!(solve("?- X = Y, Y = z."), ["X = z,\nY = z"]);
}

#[test]
fn query_destructures_lists() {
    assert_eq!(solve("?- [H|T] = [a,b,c]."), ["H = a,\nT = [b,c]"]);
    assert_eq!(solve("?- [a|T] = [X,b]."), ["T = [b],\nX = a"]);
}

#[test]
fn occurs_check_rejects_cyclic_terms() {
    assert_eq!(solve("?- X = f(X)."), Vec::<String>::new());
    assert_eq!(solve("?- X = f(Y), Y = g(X)."), Vec::<String>::new());
}

#[test]
fn query_errors() {
    assert!(solve_err("?- undefined_thing(x).").contains("unknown predicate undefined_thing/1"));
    assert!(solve_err("?- foo.").contains("unknown predicate foo/0"));
    assert!(solve_err("?- X = a, X.").contains("unknown predicate a/0"));
    assert!(solve_err("?- X.").contains("cannot call an unbound variable"));
    assert!(solve_err("?- f(.").contains("unexpected token"));
}

#[test]
fn parse_errors() {
    assert!(rt_err("foo").contains("expected '.'"));
    assert!(rt_err("123.").contains("unexpected character at byte 0"));
    assert!(rt_err(")").contains("unexpected token"));
    assert!(rt_err("f(a,).").contains("unexpected token"));
    assert!(rt_err("f(a.").contains("expected ')'"));
    assert!(rt_err("[a,b.").contains("expected ']'"));
    assert!(rt_err("").contains("unexpected token"));
}
