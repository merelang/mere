// wordfreq reference, Go. Built-in map, the idiomatic answer.
package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

func main() {
	b, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	counts := make(map[string]int64)
	total := int64(0)
	for _, w := range strings.FieldsFunc(string(b), func(r rune) bool {
		return r == ' ' || r == '\n'
	}) {
		counts[w]++
		total++
	}
	type kv struct {
		w string
		c int64
	}
	pairs := make([]kv, 0, len(counts))
	for w, c := range counts {
		pairs = append(pairs, kv{w, c})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].c != pairs[j].c {
			return pairs[i].c > pairs[j].c
		}
		return pairs[i].w < pairs[j].w
	})
	fmt.Printf("words %d\n", total)
	fmt.Printf("unique %d\n", len(pairs))
	for i := 0; i < 10 && i < len(pairs); i++ {
		fmt.Printf("%s %d\n", pairs[i].w, pairs[i].c)
	}
}
