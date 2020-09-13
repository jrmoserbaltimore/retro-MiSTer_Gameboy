; vim: sw=4 ts=4 et
; Retro-1 initialization ROM
; License:  MIT
;
; This sets up the Retro-1 Game Boy on boot.  When using a software ROM, it
; reads the ROM header and sets up the RetroGB mapper via registers in the
; $FEA0-$FEA4 range.

; This section is loaded into WRAM0 at initialization.
; Boot ROM needs to `CALL $C000` when using a software ROM.
;
; This is position-independent code
SECTION "RetroBoot", ROM0[$0000]
LOAD "RetroBootCode", WRAM0

MAPPER_TYPE equ $fea0
ROM_SIZE equ $fea1
RAM_SIZE equ $fea2
ROM_BANK_MASK_LO equ $fea3
ROM_BANK_MASK_HI equ $fea4
CART_FEATURES equ $fea5

HDR_TYPE equ $0147
HDR_ROM_SIZE equ $0148
HDR_RAM_SIZE equ $0149

EntryPoint:
jr .Enter

db "ADV-BOOT"

.Enter:
; Set MapperType to ROM
ld A, $01
ld [MAPPER_TYPE], A
;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Set up ROM size and mask ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 'h00 - 32Kbyte, no banking
; 'h01 - 64Kbyte, 4 banks
; 'h02 - 128Kbyte, 8 banks
; 'h03 - 256Kbyte, 16 banks
; 'h04 - 512Kbyte, 32 banks
; 'h05 - 1024Kbyte, 64 banks
; 'h06 - 2048Kbyte, 128 banks
; 'h07 - 4096Kbyte, 256 banks
; 'h08 - 8192Kbyte, 512 banks
; 'h52 - 72 banks
; 'h53 - 80 banks
; 'h54 - 96 banks
; 'h00 to 'h04 are straightforward; 'h52 to 'h54 are between 64 and 128 banks.
; This logic packs them into the >8 range
.rom_size_detect:
;ld HL, HDR_ROM_SIZE
ld A, [HDR_ROM_SIZE]
bit 4, A ; Check if the top nybble is $0101, e.g. 52 53 54
jr Z, .set_rom_size
set 3, A ; if it's one of the odd ones, pack into 4 bytes by making it 'b1xxx
.set_rom_size:
;ld HL, ROM_SIZE
ld [ROM_SIZE], A ; write to register; only affects [3:0]

; ROM bank mask is 9 bits, with two special cases:
;  - For 256 and 512 bank, bit shifts don't work
;  - 128 bank is also the mask for 72, 80, 96
.set_rom_bank_mask:
ld HL, ROM_BANK_MASK_HI
ld [HL], $00
; No banking?
cp A, $00
jr Z, .set_mask_done

; less than 256 banks?  Compute
cp A, $07
jr C, .set_mask_calculate
; if it's equal, set it as 256
jr Z, .set_mask_512
; if not equal, then we have to test for 512 or odd 128 banks

; for >$08, it's 128-bit mask; else it's 512
.set_mask_512:
cp A, $08
; if B > A, it's a 128-bit mask
jr C, .set_mask_128
; Else it's 512
; Set the hi bit in the mask to 1 and the lo register to $ff
ld [HL], $01 ;appears to be 512
.set_mask_256:  ; leave the high register 0 if 256
ld A, $ff ; mask all on
jr .set_mask_done

; ROM bank mask is 'b01111111 for 72, 80, 96, and 128 banks
.set_mask_128:
ld A, $06 ; 128 banks

.set_mask_calculate:
; shift 2 << n
ld B, A ; copy counter to B
ld A, 2 ; Mask
.set_mask_calculate_loop:
sla A
dec B
jr NZ, .set_mask_calculate
; make mask
dec A
.set_mask_done:
ld [ROM_BANK_MASK_LO], A


;;;;;;;;;;;;;;;;;;;;;;;
; Set up the RAM size ;
;;;;;;;;;;;;;;;;;;;;;;;
; 00h - None
; 01h - 2 KBytes
; 02h - 8 Kbytes
; 03h - 32 KBytes (4 banks of 8KBytes each)
; 04h - 128 KBytes (16 banks of 8KBytes each) <-- swap
; 05h - 64 KBytes (8 banks of 8KBytes each)   <-- these
.set_ram_size:
;ld HL, HDR_RAM_SIZE
ld A, [HDR_RAM_SIZE]
; Check if 4 or 5 by checking 'b1xxx
bit 3, A
jr Z, .set_ram_size_write
; flip the LSB if 4 or 5
xor A, $01
.set_ram_size_write:
;ld HL, RAM_SIZE
ld [RAM_SIZE], A

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Set up mappers and features ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
MAPPER_ROM equ 1
MAPPER_MBC1 equ 2
MAPPER_MBC2 equ 3
MAPPER_MBC3 equ 4
MAPPER_MBC5 equ 5
MAPPER_MBC6 equ 6
MAPPER_MBC7 equ 7
MAPPER_MMM01 equ 8
MAPPER_Camera equ 9
MAPPER_TAMA5 equ 10
MAPPER_HuC3 equ 11
MAPPER_HuC1 equ 12

HAS_RAM_BIT equ 0
HAS_BATTERY_BIT equ 1
HAS_TIMER_BIT equ 2
HAS_RUMBLE_BIT equ 3
HAS_SENSOR_BIT equ 4

.setup_mapper:
;ld HL, HDR_TYPE
ld A, [HDR_TYPE]

ld B, MAPPER_ROM
ld C, $00 ; Feature bits

cp A, $00
jr Z, .write_mapper_hop

cp A, $08
set HAS_RAM_BIT, C
jr Z, .write_mapper_hop

cp A, $09
set HAS_BATTERY_BIT, C
jr Z, .write_mapper_hop


ld B, MAPPER_MBC1
ld C, $00

cp A, $01
jr Z, .write_mapper_hop

cp A, $02
set HAS_RAM_BIT, C
jr Z, .write_mapper_hop

cp A, $03
set HAS_BATTERY_BIT, C
jr Z, .write_mapper_hop


ld B, MAPPER_MBC2
cp A, $05
jr Z, .write_mapper_hop
cp A, $06
set HAS_BATTERY_BIT, C
jr Z, .write_mapper_hop


ld B, MAPPER_MMM01
ld C, $00

cp A, $0b
jr Z, .write_mapper_hop

cp A, $0c
set HAS_RAM_BIT, C
jr Z, .write_mapper_hop

jr .write_mapper_hop_skip

.write_mapper_hop:
jr Z, .write_mapper

.write_mapper_hop_skip
cp A, $0d
set HAS_BATTERY_BIT, C
jr Z, .write_mapper


ld B, MAPPER_MBC3
ld C, $00

cp A, $11
jr Z, .write_mapper

set HAS_RAM_BIT, C
cp A, $12
jr Z, .write_mapper

set HAS_BATTERY_BIT, C
cp A, $13
jr Z, .write_mapper

set HAS_TIMER_BIT, C
cp A, $10 ; Timer, RAM, Battery
jr Z, .write_mapper

res HAS_RAM_BIT, C
cp A, $0f ; Timer, Battery


ld B, MAPPER_MBC5
ld C, $00

cp A, $19
jr Z, .write_mapper

cp A, $1a
set HAS_RAM_BIT, C
jr Z, .write_mapper

cp A, $1b
set HAS_BATTERY_BIT, C
jr Z, .write_mapper

cp A, $1e ; Rumble, RAM, Battery
set HAS_RUMBLE_BIT, C
jr Z, .write_mapper

cp A, $1d ; Rumble, RAM
res HAS_BATTERY_BIT, C
jr Z, .write_mapper

cp A, $1c ; just Rumble
res HAS_RAM_BIT, C
jr Z, .write_mapper


ld B, MAPPER_MBC6
ld C, $00
cp A, $20
jr Z, .write_mapper

ld B, MAPPER_MBC7
ld C, $00

cp A, $22
set HAS_RAM_BIT, C
set HAS_BATTERY_BIT, C
set HAS_RUMBLE_BIT, C
set HAS_SENSOR_BIT, C
jr Z, .write_mapper


ld C, $00 ; No more options
ld B, MAPPER_Camera
cp A, $fc
jr Z, .write_mapper

ld B, MAPPER_TAMA5
cp A, $fd
jr Z, .write_mapper

ld B, MAPPER_HuC3
cp A, $fe
jr Z, .write_mapper


ld B, MAPPER_HuC1
cp A, $ff
set HAS_RAM_BIT, C
set HAS_BATTERY_BIT, C
;jr .write_mapper

.write_mapper:
ld HL, MAPPER_TYPE
ld [HL], B
ld HL, CART_FEATURES
ld [HL], C

ret
