// prism-mere.js — Prism.js language definition for Mere
//
// Mere の lexer (lib/lexer.ml) と対応するトークン定義。
// Prism.js (https://prismjs.com/) の `Prism.languages` に "mere" を追加。
// docs site の `<pre><code class="language-mere">` block が highlight される。
//
// 使い方: <script src="prism-core.min.js"></script>
//         <script src="prism-mere.js"></script>
//         で Prism core の後にロード。

(function (Prism) {
  Prism.languages.mere = {
    'comment': [
      // 単行 // ...
      { pattern: /\/\/.*/, greedy: true }
      // Mere は /* ... */ 形式の block comment は無い
    ],
    'string': {
      // 文字列リテラル "..."。 `\{` escape + `{expr}` 補間も含む
      pattern: /"(?:\\.|[^"\\])*"/,
      greedy: true,
      inside: {
        'interpolation': {
          pattern: /\{[^}]*\}/,
          inside: {
            'punctuation': /^\{|\}$/,
            'rest': null  // populated below
          }
        }
      }
    },
    'tyvar': {
      // 'a, 'b: 型変数
      pattern: /'[a-zA-Z_][a-zA-Z0-9_]*/,
      alias: 'symbol'
    },
    'char': {
      // 文字リテラル 'a'
      pattern: /'[^'\\\n]'|'\\.'/,
      greedy: true
    },
    'keyword':
      /\b(?:let|rec|and|in|if|then|else|for|do|while|fn|type|signature|region|view|drop|using|module|import|open|extern|match|with|when|of|as|true|false)\b/,
    'builtin':
      /\b(?:print|print_int|print_bool|print_no_nl|print_err|read_file|read_lines|read_line|write_file|file_exists|file_mtime|sleep_ms|list_dir|mkdir_p|env_var|args|exit|time|show|fail|try_or|assert|str_len|str_split|str_join|str_contains|str_count|str_index_of|str_starts_with|str_ends_with|str_repeat|substring|str_replace|str_compare|str_trim|str_rev|str_unescape|char_at|chr|ord|to_upper|to_lower|is_digit|is_alpha|is_space|int_of_str|str_of_int|bool_of_str|float_of_int|int_of_float|str_of_float|float_of_str|f_add|f_sub|f_mul|f_div|f_lt|f_le|f_gt|f_ge|f_min|f_max|f_pow|f_neg|f_abs|sqrt|floor|ceil|round|log|exp|sin|cos|tan|pi|e|random_int|random_float|min|max|abs|even|odd|incr|decr|pow|gcd|lcm|sum_range|square|cube|sign|clamp|divmod|int_max|int_min|not|id|const|flip|pair|swap|fst|snd|iter_n|len|map_new|map_set|map_get|map_has|map_delete|map_len|map_iter|vec_new|vec_push|vec_get|vec_set|vec_len|vec_iter|vec_map|vec_fold|vec_filter|vec_sort|vec_reverse|vec_to_list|vec_to_owned|vec_concat|owned_vec_new|owned_vec_push|owned_vec_get|owned_vec_len|owned_vec_to_vec|strbuf_new|strbuf_push|strbuf_len|strbuf_to_str|mk_logger|mk_metrics|list_iter|list_map|list_fold|list_len|list_rev|range|list_filter|list_take|list_drop|list_find|list_append|list_concat|list_flat_map|list_zip|list_for_all|list_any|list_member|list_sum|list_product|list_max|list_min|list_sort|list_sort_by|option_map|option_default|option_is_some|option_and_then|result_map|result_and_then|result_or_else|result_default|result_is_ok)\b/,
    'constructor': {
      // 大文字始まり = constructor (Some / None / Cons / Nil / user-defined)
      pattern: /\b[A-Z][a-zA-Z0-9_]*\b/,
      alias: 'class-name'
    },
    'number': /\b\d+(?:\.\d+)?\b/,
    'operator':
      /(?:\+\+|->|<-|\|>|<<|>>|<=|>=|==|!=|<\||@@|&&|\|\||::|\?!|[+\-*/%<>=|&^!?])/,
    'punctuation': /[{}[\]();,.:]/
  };

  // Prism.js の補間 (interpolation) は string の rest を string 自身に
  // 再帰参照する必要がある
  Prism.languages.mere.string.inside.interpolation.inside.rest =
    Prism.languages.mere;
}(Prism));
