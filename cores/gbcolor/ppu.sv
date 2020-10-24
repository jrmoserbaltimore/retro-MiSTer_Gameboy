// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Pixel processing unit
//
// Memory:
//   - $8000-$9fff VRAM (module) (Inaccessible during Mode 3)
//   - $FE00-$FE9F OAM table (Inaccessible during mode 2-3)
//
// Registers FF40-FF45, FF47-FF4B
// 'h40,  // LCD Control Register
// 'h41,  // Video status
// 'h42,  // Scroll Y
// 'h43,  // Scroll X
// 'h44,  // LCDC Y coordinate
// 'h45,  // LY Compare
// 'h47,  // Monochrome background palette data
// 'h48,  // Monochrome sprite palette 0 data
// 'h49,  // Monochrome sprite palette 1 data
// 'h4a,  // Window Y Position
// 'h4b,  // Window X Position minus 7
//
// CGB Registers FF68-FF6C
// 'h68,  // CGB:  Background palette index
// 'h69,  // CGB:  Background palette color data
// 'h6a,  // CGB:  Sprite palette index
// 'h6b,  // CGB:  Sprite palette color data
// 'h6c:  // CGB:  Object priority mode
//
// VRAM and OAM are single-port memories and must be separate.  OAM is just a 160-byte array.
// 
module GBCVideoPU
(
    ISysCon SysCon,
    input logic ClkEn, // To keep in sync with CPU
    // Actual VRAM
    IWishbone.Initiator VideoRAM,
    // Passes pixel-by-pixel output in RGB 5-5-5 
    IWishbone.Initiator VideoOut,

    output logic [2:0] VideoStatus,

    // The system memory controller accesses VRAM, OAM, and registers
    IWishbone.Target SystemBus
);

    logic [7:0] VRegs ['h40:'h4b];
    logic [7:0] CGBRegs ['h68:'h6c];

    // OAM, expose as a memory port separate from VRAM because VRAM is accessible during mode 2
    logic [7:0] OAM ['h00:'h9f];

    always_ff @(posedge SysCon.CLK)
    begin
        VRegs['h40][0] <= 1;
    end
endmodule