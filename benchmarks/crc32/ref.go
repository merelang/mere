// crc32 reference, Go. Bitwise, no table, not hash/crc32.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ref <file>")
		os.Exit(2)
	}
	buf, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var crc uint32 = 0xFFFFFFFF
	for _, b := range buf {
		c := crc ^ uint32(b)
		for k := 0; k < 8; k++ {
			if c&1 == 1 {
				c = (c >> 1) ^ 0xEDB88320
			} else {
				c = c >> 1
			}
		}
		crc = c
	}
	crc ^= 0xFFFFFFFF
	fmt.Printf("bytes %d\n", len(buf))
	fmt.Printf("crc32 %d\n", crc)
}
