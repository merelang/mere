// mat4xvec4 reference, Go. The `float64()` conversions are what Go's spec
// names as the way to prevent a fused multiply-add, the same precaution the
// matmul row carries -- without them this row prints different bits from
// everyone else.
package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

func mk(count int, seed int64) []float64 {
	v := make([]float64, count)
	x := seed
	for i := 0; i < count; i++ {
		x = (1103515245*x + 12345) % 2147483648
		v[i] = float64(x%2001-1000) / 1000.0
	}
	return v
}

func main() {
	n := 20000
	if len(os.Args) > 1 {
		if k, err := strconv.Atoi(os.Args[1]); err == nil {
			n = k
		}
	}
	m := mk(16, 20260907)
	vs := mk(4*n, 77770707)
	var ax, ay, az, aw float64
	for r := 0; r < 5000; r++ {
		for i := 0; i < n; i++ {
			x, y := vs[4*i], vs[4*i+1]
			z, w := vs[4*i+2], vs[4*i+3]
			ax += float64(m[0]*x) + float64(m[4]*y) + float64(m[8]*z) + float64(m[12]*w)
			ay += float64(m[1]*x) + float64(m[5]*y) + float64(m[9]*z) + float64(m[13]*w)
			az += float64(m[2]*x) + float64(m[6]*y) + float64(m[10]*z) + float64(m[14]*w)
			aw += float64(m[3]*x) + float64(m[7]*y) + float64(m[11]*z) + float64(m[15]*w)
		}
	}
	s := ax + ay + az + aw
	fmt.Printf("n %d\n", n)
	fmt.Printf("checksum %d %d\n", f2b(s)>>32, f2b(s)&0xFFFFFFFF)
}

func f2b(f float64) uint64 { return math.Float64bits(f) }
