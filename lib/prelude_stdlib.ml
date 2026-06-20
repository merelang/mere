(* Phase 19.4/19.5: 自動 import される prelude。
   全 Mere プログラムの parse 開始時に、ここの decls が
   ユーザのソースの **先頭** に挿入される。

   方針:
   - **型宣言のみ** を含める。`type 'a list` / `'a option` /
     `('a, 'e) result` の 3 つ。
   - **let-rec helpers (list_iter / option_map / result_map 等) は
     入れていない**: 多相 let-rec の codegen 未対応 (DEFERRED §1.7) で
     全 program の codegen が壊れるため。fix されたら helpers を追加。
   - ユーザが同じ型を再宣言しても破綻しないように (typer は
     `Hashtbl.replace` で上書き、ctor も同様)。 *)

let contents = {|
type 'a list = Nil | Cons of 'a * 'a list;
type 'a option = None | Some of 'a;
type ('a, 'e) result = Ok of 'a | Err of 'e;
|}
