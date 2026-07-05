% A little family tree.
%
% Try:
%   ?- parent(alice, X).
%   ?- ancestor(alice, X).
%   ?- ancestor(X, eve).

parent(alice, bob).
parent(alice, carol).
parent(bob, dave).
parent(carol, eve).

ancestor(X, Y) :- parent(X, Y).
ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
