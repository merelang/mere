// matmul reference, Go.
//
// `float64(a*b)` and not `a*b`: the Go spec lets an implementation fuse a
// multiply and an add, and the gc compiler does exactly that on arm64. An
// explicit conversion rounds to float64 and is the spec's stated way to
// prevent the fusion -- without it this row's checksum differs from every
// other one in its low bits.
package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

func mk(n, seed int64) []float64 {
	v := make([]float64, n*n)
	x := seed
	for i := int64(0); i < n*n; i++ {
		x = (1103515245*x + 12345) % 2147483648
		v[i] = float64(x%2001-1000) / 1000.0
	}
	return v
}

func main() {
	n := int64(128)
	if len(os.Args) > 1 {
		v, _ := strconv.ParseInt(os.Args[1], 10, 64)
		n = v
	}
	a := mk(n, 20260825)
	b := mk(n, 77770707)
	c := make([]float64, n*n)
	for i := int64(0); i < n; i++ {
		for j := int64(0); j < n; j++ {
			acc := 0.0
			for k := int64(0); k < n; k++ {
				acc = acc + float64(a[i*n+k]*b[k*n+j])
			}
			c[i*n+j] = acc
		}
	}
	s := 0.0
	for i := int64(0); i < n*n; i++ {
		s = s + c[i]
	}
	bits := math.Float64bits(s)
	fmt.Printf("n %d\n", n)
	fmt.Printf("checksum %d %d\n", bits>>32, bits&0xFFFFFFFF)
}
