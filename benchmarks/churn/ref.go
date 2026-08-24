// churn reference, Go. Built-in map; delete is O(1).
package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	n, _ := strconv.ParseInt(os.Args[1], 10, 64)
	live, _ := strconv.ParseInt(os.Args[2], 10, 64)
	pad := "------------------------------------------"
	m := make(map[string]string)
	for i := int64(0); i < n; i++ {
		m["s"+strconv.FormatInt(i, 10)] = strconv.FormatInt(i, 10) + pad
		if i >= live {
			delete(m, "s"+strconv.FormatInt(i-live, 10))
		}
	}
	var acc int64
	for j := n - live; j < n; j++ {
		acc += int64(len(m["s"+strconv.FormatInt(j, 10)]))
	}
	fmt.Printf("live %d\n", len(m))
	fmt.Printf("checksum %d\n", acc)
}
