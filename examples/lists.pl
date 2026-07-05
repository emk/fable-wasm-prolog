% The classic list predicates.
%
% Try:
%   ?- append([a,b], [c,d], Zs).
%   ?- append(Xs, Ys, [a,b,c]).     % all ways to split a list
%   ?- member(X, [a,b,c]).
%   ?- reverse([a,b,c], Rs).

append([], Ys, Ys).
append([X|Xs], Ys, [X|Zs]) :- append(Xs, Ys, Zs).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).

reverse([], []).
reverse([H|T], R) :- reverse(T, RT), append(RT, [H], R).
