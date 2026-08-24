// binarytrees reference, Go. Struct pointers, collected by the GC.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type node struct{ l, r *node }

func build(d int) *node {
	if d == 0 {
		return nil
	}
	return &node{build(d - 1), build(d - 1)}
}

func check(t *node) int64 {
	if t == nil {
		return 1
	}
	return 1 + check(t.l) + check(t.r)
}

func main() {
	maxdepth := 14
	if len(os.Args) > 1 {
		maxdepth, _ = strconv.Atoi(os.Args[1])
	}
	longlived := build(maxdepth)
	for d := 4; d <= maxdepth; d += 2 {
		iters := int64(1) << uint(maxdepth-d+4)
		var acc int64
		for i := int64(0); i < iters; i++ {
			acc += check(build(d))
		}
		fmt.Printf("%d trees of depth %d check %d\n", iters, d, acc)
	}
	fmt.Printf("long-lived tree of depth %d check %d\n", maxdepth, check(longlived))
}
