# Bare metal (the RV32I backend)

`mere -rv` lowers a program all the way to a flat little-endian RV32IM binary —
no external assembler, no linker, no runtime beneath it. `--bare` goes one step
further: no host, no syscalls, no operating system. The program is handed the
machine and does its own I/O.

Everything here is specific to this backend. On the other four, the names below
refuse at compile time, because there is no honest interpretation of a physical
address or a trap vector in a hosted process.

```sh
mere -rv examples/riscv_backend.mere > prog.bin        # a hosted program
mere -rv --bare examples/riscv_bare_uart.mere > prog.bin   # no host at all
```

The binary runs on the Mere-written RV32I emulator in the
[memu](https://github.com/284km/memu) project (`riscv-runc`), which is where the
matching device side lives: a UART, a CLINT, CSRs and traps.

## Flags

| Flag | Meaning |
|---|---|
| `--ram <MB>` | The RAM the binary expects, 4–256, default 8. The stack starts at the top of it, so an emulator must be sized to match |
| `--bare` | No host. The program's top-level `main` is handed the machine as a `Raw`; the print builtins are refused |
| `--load-base <addr>` | Load somewhere other than address 0, 4KB-aligned. Everything absolute in the binary shifts with it |

The three flags may come in any order. `-rvg <file>` prints the **debug map** that
makes source-level debugging possible (see below); it must be given the same flags
as the `-rv` that produced the binary, since the map records addresses and all
three of them move addresses. `-rvs` prints an assembly listing and `-rvd`
disassembles a binary — the disassembler covers RV32IM and RV64IM (including
`ld`/`sd`/`lwu` and the `addiw`/`addw`/`mulw` family), the CSR instructions,
`mret` and `wfi`.

`sh scripts/rvd_oracle_check.sh` holds that disassembler to
`riscv64-elf-objdump`, comparing every instruction in the code region of four
real binaries at both widths — mnemonics throughout, and full operands over the
load/store family, because a listing is read for its offsets. It skips cleanly
when no RISC-V objdump is installed, and its summary line names how many cases
and which widths actually ran.

This gate exists because the disassembler did not have one for a long time, and
that cost real hours: it is not part of any program's behaviour, so nothing went
red when it fell behind the backend. Once `-rv64` existed, `ld` and `sd` were
most of every binary and both read as `?`, leaving 41% of a listing unreadable —
and `srli x, y, 32` printed as `srai`, which is worse, because a wrong name is
believed. An instrument with no gate goes quietly wrong exactly when you start
to depend on it.

## Memory map

Derived from the RAM size rather than hardcoded, so a program can be built for a
machine of any size:

```
  load_base + 0x000000   code (starts at _start, PC begins here)
  load_base + 0x200000   globals, then the heap growing up
                  ...
                         the stack, growing down from stack_top
  stack_top              reserved region, 128KB:
    + 0x1000               trap register save area (32 words)
    + 0x1100               the registered trap handler
    + 0x1104               trap depth
    + 0x2000               machine_scratch — yours, 48KB
    + 0x10000              the trap handler's stack (grows down), then
                           the print scratch buffer, framebuffer, keys
  load_base + ram_bytes  end
```

The heap and the stack grow toward each other with nothing in between. Every
allocation checks for the collision (`bgeu gp, sp`) and stops with a message
rather than overwriting a live frame — silently corrupting a return address with
string data is what it used to do.

Device MMIO sits **above any RAM**, so a device address does not move when
`--ram` does:

| address | device |
|---|---|
| `0x10000000` | UART data (write to send, read to receive) |
| `0x10000005` | UART line status: bit 5 transmitter ready, bit 0 data waiting |
| `0x10008000` | CLINT `mtime` |
| `0x10008008` | CLINT `mtimecmp` |

`0x10000000` is where QEMU's `virt` machine puts UART0, so a driver written
against it is not learning a private convention. The fantasy console's
framebuffer and key registers predate this and still live in the reserved top of
RAM, which means they move with `--ram`; see the deferred list at the end.

Which side the devices are on depends on where RAM was put, and the machine
window is a `max` rather than a sum for that reason: at the default base the
devices are above RAM, and on `virt` (below) RAM starts at 2GB and every device
is beneath it.

## Raw memory is a capability

A `Raw` is a **window**: a base and a length. It is opaque, nothing constructs
one, and there is no function that mints one. The only source is the argument
`--bare` hands to `main`, and `raw_window` can only narrow. Offsets are relative
to the window, so this reads as a promise:

```mere
let putc = fn (uart: Raw) -> fn (c: int) -> raw_poke8 uart 0 c;

let main = fn (mach: Raw) ->
  let uart = raw_window mach 0x10000000 256 in   // the UART, and nothing else
  putc uart 65;
```

`putc` can touch the UART and nothing else — not the heap, not the stack, not
another device — and that is visible in its signature rather than being a claim
about its body and every body it calls. That is the whole argument for a value
over an ambient builtin like the framebuffer's `fb_set`.

All three ways out are closed, and each fails differently:

| attempt | outcome |
|---|---|
| forge one from ints | a type error |
| widen a window | faults at construction |
| an offset past the end | faults at the access |

The bounds check is not optional: a window's length is a runtime field, so there
is nothing to fold at compile time even when the offset is a literal. Three
instructions on an MMIO poke buys a guarantee that holds.

`raw_base` and `raw_len` give a window's numbers back, because a stack pointer is
an address and hardware wants the number. Neither is authority — touching
anything still needs a window.

## CSRs

`csr_read` / `csr_write` lower to `csrrs` from `x0` and `csrrw` to `x0`. The
register number must be a **literal**: it is a 12-bit field of the instruction,
so a computed one has nowhere to go and is refused.

Unlike raw memory these are deliberately **not** behind a capability. A CSR has
no base and length to narrow, and the hardware already has machine / supervisor /
user mode to separate a kernel from a user process. Duplicating that in the type
system before there is a user mode to protect would be speculative.

## Traps

A trap handler cannot be an ordinary function: it is entered with every register
live and it leaves with `mret`, not `ret`. The language does not need to know
that — codegen already emits `_start`, so it emits the trampoline too, and you
write plain Mere.

It is **registered rather than named**, because a handler needs the machine
capability to do anything useful and an interrupt has no caller to hand it one.
A closure captures it instead:

```mere
let _ = set_trap_handler (fn cause ->
  if cause == 2147483655 then                  // 0x80000007: the timer
    let _ = tick () in
    csr_read 0x341                             // resume where we were
  else
    csr_read 0x341 + 4) in                     // a fault: step over it
```

The argument is `mcause`; the result is the PC to resume at, which the trampoline
writes to `mepc`. Anything else the handler wants is a `csr_read` away — `mepc`
(0x341), `mtval` (0x343) — so nothing has to be packed into a tuple, which would
mean allocating inside a trap.

Causes the emulator raises: `2` an instruction it does not implement, `5` / `7` a
load / store past the end of RAM, `11` an `ecall` when a kernel is installed,
`0x80000007` the timer. A program whose `mtvec` is still zero halts instead.

Two things the trampoline does that are worth knowing:

- **`mscratch` holds the save area's address**, because at trap entry there is no
  free register to build one in. That is what the CSR exists for.
- **The handler runs on a stack of its own.** Running it on the interrupted
  task's stack makes the handler's frame size a constraint on every task's stack,
  and turns any trap taken by a task with a nearly-full stack into a
  memory-corrupting event.

A trap taken *inside* the handler cannot be resumed — the save area is a single
global buffer, and entering it a second time has already overwritten the
interrupted context. The trampoline counts depth and refuses, with a message,
rather than continuing into nonsense.

If you install a trap vector, **clear it before returning from `main`**, or
`_start`'s exit `ecall` vectors into your own handler instead of halting.

## Tasks

A context switch needs no new mechanism. The trampoline saves the interrupted
register set to the area `trap_save` hands back and restores from it before
`mret`, so a handler switches tasks by copying through it:

```
  save area              ->  the outgoing task's TCB   (plus mepc, its resume PC)
  the incoming task's TCB ->  save area                (its PC becomes the result)
```

A task **is** a closure: `closure_code` gives the PC to start one at and
`closure_env` the value its first argument register must hold. That is ABI
knowledge, which a kernel legitimately has.

`machine_scratch` is RAM the runtime reserved and is not using — where a task's
arena comes from. A bare program owns no fixed address of its own: the heap grows
up from 2MB and the stack down from the top, so any address it picks is one the
compiler is already using.

### When to switch `gp`, which is easy to get wrong

`gp` is the heap's bump pointer. **Switch it exactly when the two contexts do not
share a heap.**

Sharing one heap between tasks looks workable — and it survives a scheduler that
only round-robins. It breaks the moment one context uses a `region`: the rollback
at the closing brace frees everything allocated since the mark, *including what
another task allocated while it was running*. That task then holds pointers into
memory the next allocation reuses.

So: give each task an arena carved from `machine_scratch` — heap up from the
bottom, stack down from the top, the same shape the main program has, so the
out-of-memory check guards each task for free — and switch every register.

```mere
let _ = vec_set tcb x_sp (raw_base scratch + raw_len scratch) in
let _ = vec_set tcb x_gp (raw_base scratch) in
```

Two programs built with different `--load-base` never share a heap either, so the
same rule covers a user process.

## A user process

A user process is an **ordinary** Mere program: not `--bare`, holding no
capability, naming no device, touching no CSR. It calls `print`, which lowers to
the same `ecall` every hosted program on this emulator has always used. With a
kernel installed that call traps (cause 11) and the kernel answers it.

```sh
mere -rv --bare  examples/riscv_bare_user.mere  > prog.bin
mere -rv --load-base 8388608 --ram 4 examples/riscv_user_prog.mere > user.bin
./rvrun 16
```

The emulator loads `prog.bin` at 0 and `user.bin` at 8MB — a bootloader's job,
done by the bootloader, since a kernel with no filesystem has to get its first
process from somewhere.

Worth being precise about what isolates that process: **the type system, not the
hardware.** Everything runs in machine mode, and the process is contained because
without `--bare` it cannot obtain a `Raw` at all — not because an MMU would stop
it. A real privilege boundary is future work.

## Booting somebody else's machine

Everything above runs on an emulator written in Mere, in this project's sibling.
That is a problem the moment something misbehaves: when the compiler, the
backend, the kernel *and* the machine are all self-written, "is the binary wrong
or is the emulator wrong?" has no answer inside the stack. Agreeing with yourself
is not evidence.

QEMU's `virt` board is the answer — an independent implementation of the same
specification. The same backend targets it with flags alone:

```sh
mere -rv --bare --load-base 0x80000000 --ram 8 examples/riscv_virt_hello.mere > virt.bin
qemu-system-riscv32 -M virt -bios none -nographic -kernel virt.bin
```

```
hello from qemu virt
built at run time: 42
fib 20 = 6765
mtime advances
```

`sh scripts/qemu_virt.sh` builds the `examples/riscv_virt_*.mere` programs, runs
them, and diffs the output. It skips cleanly when QEMU is not installed, so it is
an optional check rather than a dependency.

Three programs run: a bare one (UART, a run-time-allocated string, recursion),
a timer handler, and **the scheduler** — two tasks preempted by the clock, which
is the case most worth an outsider's opinion. A context switch is where an
emulator and the code it runs can be wrong *together*: the trampoline saves 31
registers to a known place and the emulator restores them, so if the two agreed
on a wrong order, nothing we own would notice. QEMU restores the register set its
own way, from the same bytes.

With `MEMU` pointed at a [memu](https://github.com/284km/memu) checkout, each
image is run on **both** machines and their output diffed:

```sh
MEMU=../memu sh scripts/qemu_virt.sh
  ok    riscv_virt_hello (4309 bytes, identical on both)
  ok    riscv_virt_timer (4597 bytes, identical on both)
  ok    riscv_virt_sched (7777 bytes, identical on both)
```

That is the point of the exercise: not "the binary does what we expected" but
*two independent implementations of this board agree, byte for byte, about the
same image*. Our emulator takes `virt` as its second argument to place RAM at
2GB; everything else about it is unchanged.

For that diff to mean anything the output has to be a function of the program
rather than of the clock, which is why the scheduler prints one letter per
**switch** instead of one per N iterations: virt gives each task 20ms of real
time, our emulator counts instructions, and both produce `ABABABA`.

**What it checks that our own emulator cannot:** instruction encodings, against a
decoder nobody here wrote. The layout `_start` builds, at a load base above 2GB.
The 16550 protocol, against a real device model. And the trap contract — `mtvec`,
`mstatus.MIE`, `mie.MTIE`, the CLINT's compare register, and the PC a handler
returns for `mepc` — which is the part most worth an outside opinion, because our
emulator implements one side of it and was written by the same person as the code
testing it.

Three addresses differ from our machine, and they are the whole port:

| | ours | virt |
|---|---|---|
| DRAM base | `0` | `0x80000000` |
| CLINT | `0x10008000` (mtime), `+8` (mtimecmp) | `0x0200bff8` (mtime), `0x02004000` (mtimecmp) |
| a way to exit | the host `ecall` in `_start` | write `0x5555` to the test finisher at `0x00100000` |

The exit is worth noticing: on `virt` powering the machine off is an ordinary
`raw_poke32` through an ordinary window. A way to stop is a device on this board,
not a language feature.

Two things a `virt` program must know: `mtime` there is a **10 MHz clock**, not
our emulator's instruction counter, so an interval is in real time rather than in
work done; and both CLINT registers are 64-bit, of which these examples touch the
low word only — honest for a program that runs for a fraction of a second, since
the high word stays zero for seven minutes.

## Debugging: the map, and what reads it

The binary has no header to hold debug information — this backend emits code and
nothing else — so `mere -rvg` writes a text sidecar. One record per line,
addresses ascending:

```
S <addr> <name>                                 every label
F <addr> <name> fsz= ra= fp= params= line=      a function and its frame
L <addr> <line> <col>                           the statement starting here
```

Two properties worth knowing:

- The map comes from **the same item list the assembler consumes**, so `-rv` and
  `-rvg` agree by construction. There is no separate debug build, and the map
  describes the bytes you actually ran.
- Line numbers are the ones **you** wrote. Source positions arrive counted from
  the top of the prelude-plus-source text the driver builds, and the map subtracts
  it; an address whose line lands inside the prelude gets no record at all, which
  is the honest answer for code the programmer did not write.

Frame layout is uniform (`[overflow][saved s-regs][fp][ra]`), so `fsz` / `ra` /
`fp` describe it completely: `lw ra, ra(fp)` and `lw fp, fp(fp)` walk to the
caller, which is all a backtrace needs.

```sh
mere -rv  --bare prog.mere > prog.bin
mere -rvg --bare prog.mere > prog.map
```

The reader is `riscv-dbg` in the [memu](https://github.com/284km/memu) project: a
debugger that stops at source lines, prints a backtrace, and **steps backwards**
via an undo log — one record per instruction, so reverse is exact rather than
replayed, and it crosses traps. Breaking inside an interrupt handler and stepping
back onto the line the timer interrupted is the thing that makes the map worth
emitting.

## Deferred, on purpose

- **The fantasy console's framebuffer and keys** are still ambient builtins
  (`fb_set`, `key`, `present`) at RAM-relative addresses, so they cannot be used
  together with a non-default `--ram`. Migrating them into the MMIO region and
  onto `raw_*` would remove the last hardware builtins that are not capabilities.
- **The shell and the user process under QEMU.** A bare program, a trap handler
  and the scheduler all boot on `virt` now, which covers the backend, the trap
  contract and the context switch. The shell would need its input piped in to be
  diffable, and the user-process pair needs a second image loaded with `-device
  loader` rather than `-kernel`. Both are a swap of addresses plus an invocation,
  not a redesign.
- **Nested traps** halt rather than nesting. Depth-indexed save areas would let a
  handler fault survivably.
- No MMU, no privilege modes, no PLIC (the UART is polled), no filesystem, and
  the scheduler in the examples is a hardcoded two-task round-robin with no
  `yield` or blocking.

## See also

- [stdlib-reference.md](stdlib-reference.md) — the builtin table for all of this
- [examples/README.md](../examples/README.md) — the seven bare-metal examples and
  what each one forced
- [codegen.md](codegen.md) — how the C / LLVM / Wasm backends are built, for
  contrast: this one emits machine code directly

## Vector extension (Q-110, v0.1.426)

`mere -rv` / `-rv64` lower the language's `u8x16` type to RVV 1.0 with VLEN 128,
LMUL 1 and SEW e8 (e16 only to read a widening reduction), and `bytes` to the
str block layout. The machine has to have the V extension: memu's
`riscv-runc` cores do (`rvv_check.py` holds them against QEMU with
`-cpu rv32,v=true,vlen=128`), and `_start` turns `mstatus.VS` on. A core
without V executes the same binary up to the first vector instruction and
traps there as illegal, which is the honest failure. `f64x2` is refused at
compile time: there is no floating-point unit to put the lanes in.

### Register residency (v0.1.430)

A `u8x16` expression tree is evaluated in `v1`..`v7` and boxed once, at its
root. The operands that are not vector builtins -- boxed variables, calls,
scalar arguments -- are evaluated first, in source order, onto the stack, so
no call runs while a vector value is live in a register. A let-bound `u8x16`
used only as an operand of vector builtins lives in `v8`..`v15` when no call
can run between its binding and its last use; otherwise it is boxed as
before. The builtins with a scalar result never box their operand tree.
