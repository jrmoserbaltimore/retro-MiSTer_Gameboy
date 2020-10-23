; vim: sw=4 ts=4 et
; A Game Boy boot rom
; License:  MIT
;
; This loads at $00..$ff on Game Boy power up, entering at $00.
; It checks $C002 for the string "ADV-BOOT" and, if so, jumps to $C000, which
; must be a jr to an entry point or a single RET or else the game boy crashes.

; This is position-independent code
SECTION "RetroBoot", ROM0[$0000]

ADV_BOOT_BASE equ $c000
ADV_BOOT_STRING equ ADV_BOOT_BASE + 2
VRAM_BASE equ $8000

EntryPoint:

ld SP, $fffe ; Setup stack

; clear VRAM
; 0x8000: 1000 0000 0000 0000
; 0x9fff: 1001 1111 1111 1111
;           ^ loop until this bit is 1
xor A,A
ld HL, VRAM_BASE

.vram_clear:
ld [HLI],A
bit 5, H
jr z, .vram_clear

; Initialize audio
.initialize_sound
ld HL, $ff26  ; bit 7 all sound on(1)/off(0)
ld A, $80
ld C, $11
ld [HLD],A ; Enable the audio circuitry
; Set up Channel 1
; Duty cycle 50%
ld [C],A
inc C
; Volume envelope 0xf, decreasing envelope, sweep=3
ld A, $f3  ; 1111 0011
LD [C],A
; set $ff25:  sounds 1 and 2 go to both terminals; 3 and 4 to SO2
ld [HLD], A

; set SO2 and SO1 to max volume
ld [HL], $77 ; 0111 0111


.initialize_bg_palette:
; Original Game Boy: $f3 3: black, 2: black, 3: black, 4: white
; Dark Mode! W W W B
ld A, $03
ld [$ff00+$47],A

; At this point, the original Nintendo boot ROM starts drawing things
; and playing sounds.
;
; If we have an advanced boot program in WRAM, we jump there and let
; that set up and draw.

; Check for an advanced boot ROM copied into $c000 WRAM
ld HL, .advanced_boot_string
ld BC, ADV_BOOT_STRING
ld DE, .advanced_boot_skip
.advanced_boot_check_loop:
; Compare the two bytes; if unequal, skip the advanced boot image
ld A, [BC]
cp A, [HL]
jr NZ, .advanced_boot_skip
; increment both BC and HL
inc BC
inc HL
; If the low byte of HL is the byte ofter the end of the magic string,
; jump out of the loop.  L and E comparison is independent of the base
; in the WRAM code
ld A, L
cp A, E
jr Z, .advanced_boot
jr .advanced_boot_check_loop

.advanced_boot:
; Call the code at $c000
call ADV_BOOT_BASE

jr .hdr_checksum ; Skip the logo checksum, animation, and sound

.advanced_boot_string:
db "ADV-BOOT"
.advanced_boot_skip:

; This is where the real boot program begins

; Nintendo logo checksum
.logo_checksum:
ld HL, $0104
ld B, $30
xor A, A ; Clear A
.logo_checksum_loop:
add A,[HL]
inc HL
dec B
jr NZ, .logo_checksum_loop

; Actual Nintendo logo: 0x1546, checksum = $46
cp A, $46
; jr nz, .not_nintendo_logo
; TODO: Play MGB ding sound here

; TODO: read $104..$133 and place this logo at the top of the screen.

; TODO:  Load and scroll
; TODO:  Play jingle:
;   - if sum of $104..$133 matches expected logo, GBC sound
;   - if no match, other sound, but don't halt


; If we used an advanced boot ROM, skip all the above and go here
.hdr_checksum:
ld B, $19
ld A, B

ld HL, $134
.hdr_checksum_loop:
add A, [HL]
inc HL
dec B
jr nz, .hdr_checksum_loop
add A, [HL]
jr nz, .hdr_checksum_good

; just halt
.hdr_checksum_halt:
halt
jr .hdr_checksum_halt

.hdr_checksum_good:
jr exit_boot_rom_hop
SECTION "RetroBoot2", ROM0[$007f]
exit_boot_rom_hop:
jr exit_boot_rom
SECTION "RetroBoot3", ROM0[$00fc]
exit_boot_rom:
; Disable boot ROM
; Values used:
;  $01 - DMG
;  $ff - Gameboy Pocket
;  
ld A, $01 
ld [$ff00+$50],A
