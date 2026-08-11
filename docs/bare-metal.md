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

`-rvg <file>` emits the debug map. It takes the same flags, and must be given the
same ones as the `-rv` that produced the binary — the map records addresses, and
`--bare` / `--ram` / `--load-base` move them.

`-rvs` prints an assembly listing (the same flags apply) and `-rvd` disassembles
a binary. The disassembler knows the CSR instructions, `mret` and `wfi`.

`-rvg` prints a **debug map** for the binary, which is what makes source-level
debugging possible — see below.

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
- **Booting the same kernel under QEMU** would give an external reference — the
  way Klaus and Blargg do for the 6502 and Game Boy emulators — and separate a
  kernel bug from an emulator bug. It needs RAM relocated to `0x80000000`.
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
