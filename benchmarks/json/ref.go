// json reference, Go. encoding/json into interface{} -- the idiomatic way to
// read a document whose shape you are not declaring.
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func walk(v interface{}) (int64, int64, int64) {
	switch t := v.(type) {
	case nil:
		return 1, 0, 0
	case bool:
		if t {
			return 1, 1, 0
		}
		return 1, 0, 0
	case float64:
		return 1, int64(t), 0
	case string:
		return 1, 0, int64(len(t))
	case []interface{}:
		var n, i, l int64 = 1, 0, 0
		for _, x := range t {
			a, b, c := walk(x)
			n += a
			i += b
			l += c
		}
		return n, i, l
	case map[string]interface{}:
		var n, i, l int64 = 1, 0, 0
		for k, x := range t {
			a, b, c := walk(x)
			n += a
			i += b
			l += c + int64(len(k))
		}
		return n, i, l
	}
	return 0, 0, 0
}

func main() {
	b, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var tree interface{}
	if err := json.Unmarshal(b, &tree); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	n, i, l := walk(tree)
	fmt.Printf("nodes %d\n", n)
	fmt.Printf("ints %d\n", i)
	fmt.Printf("strlen %d\n", l)
}
