use wasm_prolog::{
    Prolog, DEFAULT_FUEL, STATUS_ERROR, STATUS_NO_MORE, STATUS_OK, STATUS_OUT_OF_FUEL,
};

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

/// Consult a program, then run a query and collect all solutions.
fn program_solve(program: &str, query: &str) -> Vec<String> {
    let mut prolog = Prolog::new().expect("instantiate prolog.wat");
    prolog.consult(program).unwrap();
    prolog.solutions(query, 100).unwrap()
}

const APPEND: &str = "
    append([], Ys, Ys).
    append([X|Xs], Ys, [X|Zs]) :- append(Xs, Ys, Zs).
";

const MEMBER: &str = "
    member(X, [X|_]).
    member(X, [_|T]) :- member(X, T).
";

const FAMILY: &str = "
    parent(alice, bob).
    parent(alice, carol).
    parent(bob, dave).
    parent(carol, eve).
    ancestor(X, Y) :- parent(X, Y).
    ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
";

#[test]
fn facts_and_clause_order() {
    assert_eq!(
        program_solve(FAMILY, "?- parent(alice, X)."),
        ["X = bob", "X = carol"]
    );
    assert_eq!(program_solve(FAMILY, "?- parent(X, dave)."), ["X = bob"]);
    assert_eq!(program_solve(FAMILY, "?- parent(dave, X)."), Vec::<String>::new());
}

#[test]
fn recursive_rules_backtrack_in_order() {
    assert_eq!(
        program_solve(FAMILY, "?- ancestor(alice, X)."),
        ["X = bob", "X = carol", "X = dave", "X = eve"]
    );
    assert_eq!(
        program_solve(FAMILY, "?- ancestor(X, eve)."),
        ["X = carol", "X = alice"]
    );
}

#[test]
fn append_forward_and_backward() {
    assert_eq!(
        program_solve(APPEND, "?- append([a,b], [c], Zs)."),
        ["Zs = [a,b,c]"]
    );
    // running append "backwards" enumerates all splits
    assert_eq!(
        program_solve(APPEND, "?- append(Xs, Ys, [a,b])."),
        [
            "Xs = [],\nYs = [a,b]",
            "Xs = [a],\nYs = [b]",
            "Xs = [a,b],\nYs = []"
        ]
    );
}

#[test]
fn member_enumerates() {
    assert_eq!(
        program_solve(MEMBER, "?- member(X, [a,b,c])."),
        ["X = a", "X = b", "X = c"]
    );
    assert_eq!(program_solve(MEMBER, "?- member(b, [a,b,c])."), ["true"]);
}

#[test]
fn multiple_variables_shared_across_goals() {
    let program = "
        likes(mary, wine).
        likes(john, wine).
        likes(john, mary).
    ";
    assert_eq!(
        program_solve(program, "?- likes(X, Drink), likes(Y, Drink), X = mary."),
        ["X = mary,\nDrink = wine,\nY = mary", "X = mary,\nDrink = wine,\nY = john"]
    );
}

#[test]
fn pull_one_solution_at_a_time() {
    let mut prolog = Prolog::new().unwrap();
    prolog.consult(MEMBER).unwrap();
    let (status, _) = prolog.query_begin("?- member(X, [a,b]).").unwrap();
    assert_eq!(status, STATUS_OK);
    assert_eq!(prolog.query_next(DEFAULT_FUEL).unwrap(), (STATUS_OK, "X = a".into()));
    assert_eq!(prolog.query_next(DEFAULT_FUEL).unwrap(), (STATUS_OK, "X = b".into()));
    assert_eq!(prolog.query_next(DEFAULT_FUEL).unwrap().0, STATUS_NO_MORE);
    // asking again after exhaustion is fine
    assert_eq!(prolog.query_next(DEFAULT_FUEL).unwrap().0, STATUS_NO_MORE);
}

#[test]
fn fuel_interrupts_a_runaway_query() {
    let mut prolog = Prolog::new().unwrap();
    prolog.consult("loop :- loop.").unwrap();
    prolog.query_begin("?- loop.").unwrap();
    // never finds a solution, but always comes back to the host
    assert_eq!(prolog.query_next(1_000).unwrap().0, STATUS_OUT_OF_FUEL);
    assert_eq!(prolog.query_next(1_000).unwrap().0, STATUS_OUT_OF_FUEL);
}

#[test]
fn consult_errors() {
    let mut prolog = Prolog::new().unwrap();
    let err = prolog.consult("X :- foo.").unwrap_err().to_string();
    assert!(err.contains("clause head must be an atom or compound"));
    let err = prolog.consult("foo(a)").unwrap_err().to_string();
    assert!(err.contains("expected '.'"));
    let err = prolog.consult("foo :- .").unwrap_err().to_string();
    assert!(err.contains("unexpected token"));
}

#[test]
fn consulting_twice_extends_the_database() {
    let mut prolog = Prolog::new().unwrap();
    prolog.consult("color(red).").unwrap();
    prolog.consult("color(blue).").unwrap();
    assert_eq!(
        prolog.solutions("?- color(X).", 100).unwrap(),
        ["X = red", "X = blue"]
    );
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
