/* Compare the optimized walker with the original independent-word contract.
   Synthetic spans own their bytes; gaps, headers and end addresses are explicit. */
static void bench_reference_word(__lang_string_scan* s, uintptr_t w) {
  uintptr_t a = w & ~(uintptr_t)7;
  for (size_t i = 0; i < s->nsp; i++) {
    __lang_span* sp = s->spans + i;
    if (a < sp->lo || a >= sp->hi) continue;
    uintptr_t used = sp->hi;
    if (sp->b->owner && sp->b->owner->blocks == sp->b)
      used = (uintptr_t)sp->b->owner->top;
    if (a > used) return;
    uintptr_t begin = a > s->maxlen ? a - s->maxlen : 0;
    if (begin < sp->lo + sizeof(size_t)) begin = sp->lo + sizeof(size_t);
    begin = (begin + 7) & ~(uintptr_t)7;
    uintptr_t end = a + sizeof(size_t);
    if (end > used) end = used;
    for (uintptr_t p = begin; p <= end; p += 8) {
      size_t n;
      memcpy(&n, (const void*)(p - sizeof(size_t)), sizeof n);
      if (n <= s->maxlen && n <= used - p && (p > a || a - p <= n))
        __lang_string_root_match(s, (const char*)p, n);
      if (end - p < 8) break;
    }
    return;
  }
}

static void bench_oracle(void) {
  union { size_t align; unsigned char bytes[8192]; } storage;
  unsigned char* data = storage.bytes;
  memset(data, 0xa5, sizeof storage.bytes);
  __lang_region owner;
  __lang_region_block blocks[2];
  memset(&owner, 0, sizeof owner);
  memset(blocks, 0, sizeof blocks);
  /* A real hole and unused capacity in the second current block. */
  __lang_span spans[2] = {
    { .b = blocks, .lo = (uintptr_t)data, .hi = (uintptr_t)data + 2048 },
    { .b = blocks + 1, .lo = (uintptr_t)data + 4096, .hi = (uintptr_t)data + 6144 }
  };
  blocks[1].owner = &owner;
  owner.blocks = blocks + 1;
  owner.top = (char*)data + 5600;
  const size_t positions[] = { 16, 128, 320, 768, 4144, 4384, 5520 };
  const size_t lengths[] = { 0, 1, 9, 79, 8, 127, 71 };
  enum { N = 7 };
  __lang_string_candidate entries[N], reference[N];
  size_t heads[16];
  memset(heads, 255, sizeof heads);
  memset(entries, 0, sizeof entries);
  for (size_t i = 0; i < N; i++) {
    memcpy(data + positions[i] - sizeof(size_t), lengths + i, sizeof(size_t));
    for (size_t j = 0; j < lengths[i]; j++) data[positions[i] + j] = (unsigned char)(i * 17 + j);
    entries[i].text = (const char*)data + positions[i];
    entries[i].len = lengths[i];
    entries[i].hash = __lang_string_root_hash(entries[i].text, lengths[i]);
    size_t bucket = entries[i].hash & 15;
    entries[i].next = heads[bucket]; heads[bucket] = i;
  }
  for (int trial = 0; trial < 1136; trial++) {
    uintptr_t words[1200];
    size_t count = 0;
    /* Every header/interior/end offset is tested on its own, then with
       overlapping and duplicated words, invalid addresses and span gaps. */
    size_t which = (size_t)trial % N;
    words[count++] = (uintptr_t)data + positions[which] - 8 + ((trial / N) % 144);
    if (trial >= 1008) {
      for (size_t i = 0; i < sizeof storage.bytes; i += 8 + (trial % 4) * 8)
        words[count++] = (uintptr_t)data + i;
      words[count++] = words[0];
      words[count++] = 0;
      words[count++] = UINTPTR_MAX;
    }
    qsort(words, count, sizeof(uintptr_t), __lang_uptr_cmp);
    for (size_t i = 0; i < N; i++) entries[i].found = 0;
    memcpy(reference, entries, sizeof entries);
    __lang_string_scan actual = { .entries = entries, .heads = heads, .cap = 16,
      .maxlen = (trial % 3 == 0 ? 0 : trial % 3 == 1 ? 128 : 32768),
      .spans = spans, .nsp = 2 };
    __lang_string_scan expected = actual;
    expected.entries = reference;
    unsigned long long before = bench_probes;
    for (size_t i = 0; i < count; i++) {
      bench_reference_word(&expected, words[i]);
      __lang_string_root_word(&actual, words[i]);
    }
    for (size_t i = 0; i < N; i++) {
      if (entries[i].found != reference[i].found) {
        fprintf(stderr, "scan oracle: match mismatch trial=%d entry=%zu\n", trial, i);
        exit(4);
      }
    }
    if (bench_probes - before > (2048 + 1504) / 8) {
      fprintf(stderr, "scan oracle: repeated header visits trial=%d\n", trial);
      exit(5);
    }
  }
}
