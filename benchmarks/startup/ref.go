// startup reference, Go.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	var n int64
	if len(os.Args) > 1 {
		n, _ = strconv.ParseInt(os.Args[1], 10, 64)
	}
	fmt.Printf("startup %d\n", n*n+1)
}
