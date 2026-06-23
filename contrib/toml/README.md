# contrib/toml — TOML 1.0 縮小 parser

Mere で書かれた TOML パーサ。 config file の読み取りに使う想定。

## 使い方

```mere
import "contrib/toml/toml.mere";

let input =
  "title = \"My App\"\n" ++
  "[server]\n" ++
  "host = \"localhost\"\n" ++
  "port = 8080\n";

let doc = Toml.parse_toml input in
match Toml.get doc "server.host" with
| Toml.TStr s -> print s
| _ -> ();
```

## API

| fn | 型 | 内容 |
|---|---|---|
| `Toml.parse_toml` | `str -> (str * toml_value) list` | input → fully-qualified key の key/value pair list (出現順) |
| `Toml.get` | `(str * toml_value) list -> str -> toml_value` | key で lookup、 未発見は `fail` |
| `Toml.has` | `(str * toml_value) list -> str -> bool` | key 存在確認 |

`toml_value`:

```mere
type toml_value =
  | TInt  of int
  | TStr  of str
  | TBool of bool
  | TArr  of toml_value list;
```

## 対応 subset

| 機能 | 状態 |
|---|---|
| key/value (`key = value`) | ✓ |
| section header (`[section]`) | ✓ |
| dotted section (`[a.b.c]`) | ✓ (key を `a.b.c.k` に flatten) |
| 整数 (`42` / `-7`) | ✓ |
| basic string (`"text"` + escape `\"` `\\` `\n` `\t`) | ✓ |
| bool (`true` / `false`) | ✓ |
| array (`[1, 2, 3]`、 primitives + 入れ子 array まで) | ✓ |
| comment (`# ...` 行末まで、 string 内は除外) | ✓ |
| empty line / leading whitespace | ✓ (skip) |

## 非対応 (将来 Phase or 別 lib)

- datetime (RFC 3339: `2026-06-23T19:30:00Z`)
- multi-line basic string (`"""..."""`)
- literal string (`'...'` raw、 escape 解釈なし)
- dotted key (`a.b = 1` を top-level table の sub key として扱う)
- inline table (`{ k1 = v1, k2 = v2 }`)
- table array (`[[name]]` で同名 section の repeat)
- hex / octal / binary integer (`0xff` / `0o755` / `0b1010`)
- float (`3.14` / `1e10`)
- underscore separator (`1_000_000`)

これらが必要な dogfood が出てきたら検討する。

## 実行例

```sh
dune exec mere -- contrib/toml/toml.mere
# entries: 8
#   title = TStr "My App"
#   ...
#   ✓ server.host == "localhost"
#   ...
```

## backend サポート

| backend | 状態 |
|---|---|
| interp | ✓ |
| C | ✓ |
| LLVM | ✓ |
| Wasm | ✓ |

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-toml` (別 repo、 pkg manager 完成後)。
