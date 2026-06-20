(* Phase 19.4: 自動 import される prelude。
   全 Mere プログラムの parse 開始時に、ここの decls が
   ユーザのソースの **先頭** に挿入される。

   方針:
   - 当面は最小限 (`type 'a list = Nil | Cons of 'a * 'a list;`) のみ。
   - Result / Option / helpers は Phase 19.5 で追加。
   - codegen 影響を最小化するため、ユーザが同じ型を再宣言しても
     破綻しないように (typer は `Hashtbl.replace` で上書きするだけ)。 *)

let contents = {|
type 'a list = Nil | Cons of 'a * 'a list;
|}
