; A tiny playable Game Boy demo: move a sprite with the d-pad.
; Assembled with RGBDS. Runs on the Mere Game Boy emulator.

SECTION "Entry", ROM0[$100]
    nop
    jp Main

SECTION "Header", ROM0[$104]
    ds $150 - $104, 0        ; rgbfix fills the logo + header checksums

SECTION "Main", ROM0[$150]
Main:
    ; wait for VBlank, then turn the LCD off to safely write VRAM
.wait0:
    ldh a, [$FF44]             ; LY  ($FF44)
    cp 144
    jr c, .wait0
    xor a
    ldh [$FF40], a             ; LCDC off

    ; build one solid 8x8 tile as tile index 1 at $8010 (all color 3)
    ld hl, $8010
    ld c, 16
.tile:
    ld a, $FF
    ld [hl+], a
    dec c
    jr nz, .tile

    ; palettes: 11 10 01 00
    ld a, %11100100
    ldh [$FF47], a             ; BGP
    ldh [$FF48], a             ; OBP0

    ; sprite 0 at (Y=72, X=80), tile 1, no flags  ($FE00..$FE03)
    ld a, 72
    ld [$FE00], a
    ld a, 80
    ld [$FE01], a
    ld a, 1
    ld [$FE02], a
    xor a
    ld [$FE03], a

    ; LCD on + sprites on  (bit7 LCD, bit1 OBJ)
    ld a, %10000010
    ldh [$FF40], a

    ; --- sound on: NR52 master, NR51 routing, NR50 volume ---
    ld a, $80
    ldh [$FF26], a             ; NR52: APU on
    ld a, $FF
    ldh [$FF25], a             ; NR51: both channels to L+R
    ld a, $77
    ldh [$FF24], a             ; NR50: max volume, both sides

    ; startup arpeggio on channel 1 (four ascending notes)
    ld de, $060A
    call PlayNote
    ld c, 10
    call WaitFrames
    ld de, $0672
    call PlayNote
    ld c, 10
    call WaitFrames
    ld de, $06D6
    call PlayNote
    ld c, 10
    call WaitFrames
    ld de, $072A
    call PlayNote
    ld c, 10
    call WaitFrames

Loop:
.wv:
    ldh a, [$FF44]             ; wait for LY == 144 (VBlank)
    cp 144
    jr nz, .wv

    ; read the direction pad: select directions (bit4=0, bit5=1)
    ld a, $20
    ldh [$FF00], a
    ldh a, [$FF00]
    ldh a, [$FF00]             ; read twice (hardware settle; harmless here)
    ld b, a                  ; b: bit0=right 1=left 2=up 3=down (0 = pressed)

    ld a, [$FE01]            ; X
    bit 0, b
    jr nz, .nr
    inc a
.nr:
    bit 1, b
    jr nz, .nl
    dec a
.nl:
    ld [$FE01], a

    ld a, [$FE00]            ; Y
    bit 2, b
    jr nz, .nu
    dec a
.nu:
    bit 3, b
    jr nz, .nd
    inc a
.nd:
    ld [$FE00], a

    ; beep while any direction is held (re-trigger each frame -> sustained tone)
    ld a, b
    and $0F
    cp $0F
    jr z, .quiet
    ld de, $06D6
    call PlayNote
.quiet:

    ; wait for LY to leave 144 so we only move once per frame
.leave:
    ldh a, [$FF44]
    cp 144
    jr z, .leave
    jr Loop

; Trigger a 0.25s note on channel 1. freq_reg: lo in E, hi (bits2-0) in D.
PlayNote:
    ld a, %10000000            ; NR11: 50% duty, length index 0 -> ~0.25s
    ldh [$FF11], a
    ld a, $F0                  ; NR12: volume 15, no envelope
    ldh [$FF12], a
    ld a, e
    ldh [$FF13], a             ; NR13: frequency low
    ld a, d
    or %11000000               ; NR14: trigger + length-enable + freq high
    ldh [$FF14], a
    ret

; Wait C VBlanks (C != 0).
WaitFrames:
.w1:
    ldh a, [$FF44]
    cp 144
    jr nz, .w1
.w2:
    ldh a, [$FF44]
    cp 144
    jr z, .w2
    dec c
    jr nz, WaitFrames
    ret
