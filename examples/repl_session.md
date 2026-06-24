# Example REPL session

Launch with `mere -r` and interact as below. `> ` is the normal prompt;
`..>` is the multi-line continuation prompt.

```
$ mere -r
mere REPL. Type :help for commands, :quit to exit.

> 1 + 2 * 3
- : int = 7

> let greet = fn name -> "Hello, " ++ name ++ "!";
val greet : (str -> str)

> greet "world"
- : str = "Hello, world!"

> :type fn x -> x + 1
(int -> int)

> let rec fact = fn n ->
..>   if n < 1 then 1
..>   else n * fact (n - 1);
val fact : (int -> int)

> fact 10
- : int = 3628800

> :show fact
val fact : (int -> int)
  = <closure:n>

> :env
val greet : (str -> str)
val fact : (int -> int)

> :load examples/lib_list_ops.mere
type 'a list defined (2 variants)
val ListOps.length : ('a list -> int)
val ListOps.sum : (int list -> int)
val ListOps.map : (('a -> 'b) -> ('a list -> 'b list))
(loaded examples/lib_list_ops.mere)

> ListOps.sum [1, 2, 3, 4, 5]
- : int = 15

> :reset
(envs reset)

> :env
(no user bindings)

> :quit
$
```

## Command summary

| Command | Action |
|---|---|
| `:help` / `:h` | Show help |
| `:quit` / `:q` | Exit |
| `:type EXPR` | Show only the inferred type of EXPR (no eval) |
| `:env` | List current user bindings as `val name : ty` |
| `:show NAME` | Show NAME's type and value together |
| `:load FILE` | Load FILE's decls into the REPL env |
| `:reset` | Clear all user bindings |

## How multi-line works

If the parser sees the input as "incomplete" (an error at the T_eof
position), the continuation prompt `..>` is shown. During continuation,
typing a blank line or a line starting with `:` discards the buffer
(`(input aborted)`).
