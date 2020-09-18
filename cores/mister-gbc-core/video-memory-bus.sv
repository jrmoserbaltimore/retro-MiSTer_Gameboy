// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Video shim to communicate with MiSTer video.v module

// Registers:
//   - FF40-FF42, FF44, FF45, FF47-FF4A
//   - FF46 (OAM DMA)
//   - FF68-FF6A (CGB Palette data)
//     - FF69, FF6B (Palette data write) inaccessible during Mode 3
//   - FF51-FF55 (CGB VRAM DMA)
//   - FF4F (CGB VRAM Bank select)
//   - FF6C obj prio mode (Video?)
//
// Memory:
//   - $8000-$9fff VRAM (module) (Inaccessible during Mode 3)
//   - $FE00-$FE9F OAM table (Inaccessible during mode 2-3)
//
// VRAM and OAM are single-port memories and must be separate.  OAM is just a 160-byte array.
// 
module GBCVideoMemoryBus
(
    input logic Clk,
    input logic ClkEn,
    // Actual VRAM module
    IRetroMemoryPort.Initiator VideoRAM,

    // TODO:  Mode here, from ppu
    // TODO:  Another Target bus from ppu
    // the system memory controller accesses VRAM and OAM through here.
    // Acknowledges Address[13:0] as VRAM banks, plus the actual OAM addresses
    IRetroMemoryPort.Target MemoryBus
);

    logic[1:0] Mode;
    // OAM, expose as a memory port separate from VRAM because VRAM is accessible during mode 2
    logic ['hfe9f:'hfe00] OAM;

    wire AddressOAM, ReadOAM, WriteOAM;
    wire AddressVRAM, ReadVRAM, WriteVRAM;

    // VRAM is only 13 bits, and here assumes the caller only calls OAM with the correct addresses
    assign AddressOAM = MemoryBus.Address[15] == '1;
    assign ReadOAM = AddressOAM && MemoryBus.Access && !MemoryBus.Write;
    assign WriteOAM = AddressOAM && MemoryBus.Access && MemoryBus.Write;

    assign AddressVRAM = !MemoryBus.Address[15];
    assign ReadVRAM = AddressVRAM && MemoryBus.Access && !MemoryBus.Write;
    assign WriteVRAM = AddressVRAM && MemoryBus.Access && MemoryBus.Write;

    // Avoiding multiple drivers
    logic Passthrough;
    wire [7:0] OAMData;
    logic DataBuffer;

    assign OAMData = (!ReadOAM || Mode[1]) ? 'hff : OAM[MemoryBus.Address];

    logic [13:0] VRAMAddress;

    logic VRAMAccess;
    logic VRAMBuffer; // Outgoing buffer
    logic VRAMWrite;
    
    // On mode 3, this module accesses VRAM.
    assign VideoRAM.Address = (Mode == 'h3) ? VRAMAddress : MemoryBus.Address[13:0];
    assign VideoRAM.DToTarget = (Mode == 'h3) ? VRAMBuffer : MemoryBus.DToTarget;
    // Mode 3 only internal, else only if memory bus addresses VRAM
    assign VideoRAM.Access = (Mode == 'h3) ? VRAMAccess : (MemoryBus.Access && AddressVRAM);
    assign VideoRAM.Mask = '0;
    
    assign VideoRAM.Write = (Mode == 'h3) ? VRAMWrite : (MemoryBus.Write && AddressVRAM);
    // When servicing requests locally, set Passthrough to 0 and assign to DataBuffer.
    assign MemoryBus.DToInitiator = Passthrough ? VideoRAM.DToInitiator : DataBuffer;
    
    // XXX:  'Ready' is probably bad interface here.
    assign MemoryBus.Ready = Passthrough ? VideoRAM.Ready : '1;
    // Data is always immediately ready locally
    assign MemoryBus.DataReady = Passthrough ? VideoRAM.DataReady : '1;

    // OAM Access doesn't work during Mode 2 ('b10) or 3('b11)
    always_ff @(posedge Clk)
    begin
        if (AddressOAM)
        begin
            // Serve OAM locally. In modes 2 and 3, return 0xff and do not write OAM
            Passthrough <= '0;
            if (ReadOAM)
                DataBuffer <= OAMData;
            else if (WriteOAM && !Mode[1])
                OAM[MemoryBus.Address] <= MemoryBus.DToTarget;
        end else //if (AddressVRAM)
        begin
            // Always pass through unless mode is 3.  Return 0xff in mode 3.
            Passthrough <= (Mode == 2'b11) ? '0 : '1;
            DataBuffer <= 'hff;
        end
        
        // TODO:  Internal VRAM/OAM access
        // A separate VRAM bus takes priority.  Depending on mode, pass through to VRAM or OAM
        // for that bus and feed the system bus 0xff.
    end
endmodule