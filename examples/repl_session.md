# REPL セッションの例

`lang-ml -r` で起動して以下のように対話。`> ` は通常プロンプト、`..>` は
multi-line 継続プロンプト。

```
$ lang-ml -r
lang-ml REPL. Type :help for commands, :quit to exit.

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

> :load examples/lib_list_ops.lang
type 'a list defined (2 variants)
val ListOps.length : ('a list -> int)
val ListOps.sum : (int list -> int)
val ListOps.map : (('a -> 'b) -> ('a list -> 'b list))
(loaded examples/lib_list_ops.lang)

> ListOps.sum [1, 2, 3, 4, 5]
- : int = 15

> :reset
(envs reset)

> :env
(no user bindings)

> :quit
$
```

## コマンドまとめ

| コマンド | 動作 |
|---|---|
| `:help` / `:h` | help 表示 |
| `:quit` / `:q` | exit |
| `:type EXPR` | EXPR の型推論結果のみ表示 (eval しない) |
| `:env` | 現在の user bindings を `val name : ty` で列挙 |
| `:show NAME` | NAME の型と値を同時に表示 |
| `:load FILE` | FILE の decls を REPL env に取り込み |
| `:reset` | 全 user bindings をクリア |

## Multi-line のしくみ

入力が parser から見て「途中で終わっている」(T_eof 位置でエラー) と判定された
ら継続プロンプト `..>` が表示される。継続中に空行を打つか `:` で始まる行を
打つと buffer は破棄される (`(input aborted)`)。
