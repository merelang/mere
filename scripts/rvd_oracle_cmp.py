#!/usr/bin/env python3
"""Compare `mere -rvd` output against riscv64-elf-objdump, instruction by
instruction, over a binary's code region. Driven by scripts/rvd_oracle_check.sh.

Exit 0 and print a one-line summary on agreement; exit 1 and print the
disagreements (with addresses and the raw word, so the failure names the
encoding rather than describing it) otherwise.

Two things are checked, because they fail differently:

  * mnemonics, over every instruction the oracle decoded -- this is what
    catches "not decoded at all" (opcodes 0x1B/0x3B were missing entirely) and
    "decoded as the wrong instruction" (srli printed as srai whenever the shift
    amount had bit 5 set, because f7 = 0 is not the RV64 discriminator).

  * full operands, over the load/store family -- a mnemonic-only check passes a
    disassembler that prints the right instruction with the wrong offset, and an
    offset is precisely what a listing gets read for. The bug this gate was
    written after was an offset.

A "?" or ".word" from this side inside the code region is a failure, not a
skip: the oracle decoded it, so it is an instruction, so a name is owed.
"""
import re
import sys

REGS = ("zero ra sp gp tp t0 t1 t2 fp s1 a0 a1 a2 a3 a4 a5 a6 a7 "
        "s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6").split()
NAME_TO_X = {REGS[i]: "x%d" % i for i in range(32)}
# objdump also knows x8 as s0; this backend's listing calls it fp
NAME_TO_X["s0"] = "x8"

# `mere -rvd` prints pseudo-instructions the way a human writes them; the oracle
# is asked for no-aliases, so it prints the real one. Map ours onto theirs.
PSEUDO = {
    "mv": "addi", "li": "addi", "nop": "addi", "not": "xori", "seqz": "sltiu",
    "ret": "jalr", "j": "jal", "jr": "jalr",
    "beqz": "beq", "bnez": "bne", "neg": "sub", "negw": "subw", "snez": "sltu",
}
MEM = ("ld", "sd", "lw", "sw", "lb", "sb", "lh", "sh", "lbu", "lhu", "lwu")
# the oracle emits these for words that are not instructions on this arch
ORACLE_JUNK = ("unimp", "bad", "c.unimp", ".word", ".short", ".byte", ".insn")

MINE_RE = re.compile(r"\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*)$")
ORC_RE = re.compile(r"\s*([0-9a-f]+):\s*([0-9a-f]{8})\s+(\S+)\s*([^#\n]*)")


def parse(path, rx):
    out = {}
    with open(path) as fh:
        for line in fh:
            m = rx.match(line.replace("\t", " "))
            if m:
                out[int(m.group(1), 16)] = (m.group(2), m.group(3), m.group(4).strip())
    return out


def regs_to_x(operands):
    """Rewrite ABI register names to xN, tokenizing so that s1 inside s10 is
    never rewritten -- a substring replacement would turn `s10` into `x9` + `0`
    and invent a disagreement in the register that carried the bug."""
    return re.sub(r"[a-z][a-z0-9]*",
                  lambda m: NAME_TO_X.get(m.group(0), m.group(0)),
                  operands).replace(" ", "")


def main():
    mine_path, orc_path, end = sys.argv[1], sys.argv[2], int(sys.argv[3])
    mine = parse(mine_path, MINE_RE)
    orc = parse(orc_path, ORC_RE)

    mnem_ok = mnem_bad = 0
    ops_ok = ops_bad = 0
    unnamed = 0
    problems = []

    for addr in sorted(mine):
        if addr >= end or addr not in orc:
            continue
        _, m_mn, m_ops = mine[addr]
        o_word, o_mn, o_ops = orc[addr]
        if o_mn in ORACLE_JUNK:
            continue                      # not an instruction on this arch either

        if m_mn in ("?", ".word"):
            unnamed += 1
            if len(problems) < 10:
                problems.append("%7x  %s  mere gave no name; objdump says %s %s"
                                % (addr, o_word, o_mn, o_ops))
            continue

        if PSEUDO.get(m_mn, m_mn) != o_mn:
            mnem_bad += 1
            if len(problems) < 10:
                problems.append("%7x  %s  mere=%-22s objdump=%s"
                                % (addr, o_word, m_mn + " " + m_ops, o_mn + " " + o_ops))
            continue
        mnem_ok += 1

        if m_mn in MEM:
            if regs_to_x(m_ops) == o_ops.replace(" ", ""):
                ops_ok += 1
            else:
                ops_bad += 1
                if len(problems) < 10:
                    problems.append("%7x  %s  %s operands: mere='%s' objdump='%s'"
                                    % (addr, o_word, m_mn, m_ops, o_ops))

    if not mnem_ok and not problems:
        print("nothing in the code region was comparable — the oracle decoded none of it")
        return 1

    if problems or mnem_bad or ops_bad or unnamed:
        print("mnemonic mismatches=%d  operand mismatches=%d  unnamed in code region=%d"
              % (mnem_bad, ops_bad, unnamed))
        for p in problems:
            print(p)
        return 1

    print("%d instructions, %d load/store operands, all agree" % (mnem_ok, ops_ok))
    return 0


if __name__ == "__main__":
    sys.exit(main())
