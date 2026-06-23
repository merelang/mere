# contrib/time — time format helpers

経過秒 (float) を人間可読 string に format する小さな helper 群。 `module Time
{ format_elapsed, to_ms, to_us }` で名前空間化。

## ファイル

| file | export | 行数 |
|---|---|---|
| `time.mere` | `module Time { format_elapsed, to_ms, to_us }` | 約 60 行 |

## 使い方

```mere
import "contrib/time/time.mere";

// 経過秒を表示
print (Time.format_elapsed 1.25);   // "1.25s"
print (Time.format_elapsed 0.005);  // "5ms"
print (Time.format_elapsed 12.34);  // "12.34s"

// 整数変換
print (show (Time.to_ms 1.5));        // 1500
print (show (Time.to_us 0.001234));   // 1234

// 実時間 benchmark (interp only — `time` builtin が C/LLVM/Wasm 未対応)
let t0 = time () in
... 重い処理 ...
let dt = f_sub (time ()) t0 in
print (Time.format_elapsed dt);
```

## API

| fn | signature | 用途 |
|---|---|---|
| `format_elapsed` | `float -> str` | `< 1s` → `"Nms"`、 `>= 1s` → `"N.NNs"` |
| `to_ms` | `float -> int` | float 秒を ms 単位の int に |
| `to_us` | `float -> int` | float 秒を us 単位の int に |

## backend サポート

| backend | 状態 |
|---|---|
| interp | ✓ |
| C | ✓ (Phase 43.1 で `TyFloat` が `ty_is_concrete` から漏れていた typo を fix) |
| LLVM | ✓ (同上) |
| Wasm | ✗ 当面 unsupported (user-defined fn の float parameter が i32 hardcode、 `codegen_wasm.ml:2587`。 Wasm の float fn signature 対応は別 Phase) |

## MVP 限定

- `now` / `since` / `bench` (実時間計測 helper) は本 lib に含めない — `time` builtin が C/LLVM/Wasm 未実装のため。 interp で benchmark したい場合は user 側で `time ()` を直接呼ぶ
- date formatting (`YYYY-MM-DD HH:MM:SS` 等) も非対応 — Mere builtin に `strftime` 相当が無い

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-time` (別 repo、 pkg manager 完成後)。 Wasm float fn 対応 +
`time` builtin の C/LLVM/Wasm 実装 + date formatting が graduation 前の前提。
