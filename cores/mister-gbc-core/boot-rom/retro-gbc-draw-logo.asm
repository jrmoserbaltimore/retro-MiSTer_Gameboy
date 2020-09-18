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
SECTION "DrawLogo", ROM0[$0160]
LOAD "DrawLogoCode", WRAM0[$c160]

db "DRAW LOGO"
DrawLogo:
EXPORT DrawLogo

; TODO: Fancy logo drawing here

ret
