// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// This is a full CPU memory bus controller.

// TODO:  Figure how to share IO/HRAM/Interrupt with other modules:
//     - HRAM is totally controlled here
//     - Video RAM I/O registers belong to VRAM
//       - FF40-FF42, FF44, FF45, FF47-FF4A
//       - FF46 (OAM)
//       - FF68-FF6A (CGB)
//       - FF51-FF55 (CGB OAM)
//       - FF4F (CGB VRAM Bank)
//     - Sound
//       - FF10-14, FF16-FF1E, FF20-FF26, FF30-3F
//     - Joystick (here?)
//       - FF00
//     - Serial (I/O?)
//       - FF01-FF02
//     - Timer (not MBC3 RTC) (Here?)
//       - FF04-FF07
//     - Interrupt (Definitely needs to be in Gameboy)
//       - FFFF Interrupt Enable
//       - FF0F Interrupt Flag
//     - GBC etc
//       - FF4D Prepare speed switch (Gameboy reg)
//       - FF56 IR port (I/O?)
//       - FF6C obj prio mode (Video?)
//       - FF70 WRAM bank (handled here)
module GBCMemoryBus
#(
    parameter string DeviceType = "Xilinx"
)
(
    logic Clk,
    logic ClkEn,
    // Communication to main system.  System can call for boot from ROM, and controller can call
    // for save states and save RAM.
    IRetroComm.Target Comm,

    // RAM for memory map
    IRetroMemoryPort.Initiator SystemRAM, // Gameboy system RAM
    IRetroMemoryPort.Initiator VideoRAM, // Video module

    // Cartridge controller
    IRetroMemoryPort.Initiator Cartridge,
    // System bus it exposes
    IRetroMemoryPort.Target MemoryBus
);

    logic IsCGB;
    logic ['hff00:'hffff][7:0] IOHRAM;

    wire AddressCart;
    wire AddressVRAM;
    wire AddressWRAM;
    wire AddressOAM;
    wire AddressIOHRAM;
    
    logic [7:0] DOutReg;

    // ======================================================
    // = Map Cartridge to $0000 to $7FFF and $A000 to $BFFF =
    // ======================================================
    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space
    // 3 inputs
    assign AddressCart = MemoryBus.Address[15] == '0 || MemoryBus.Address[15:13] == 3'b101;

    assign Cartridge.Access = AddressCart && MemoryBus.Access;
    assign Cartridge.Write = AddressCart && MemoryBus.Write;
    assign Cartridge.DToTarget = MemoryBus.DToTarget;

    // ==================================
    // = Map VideoRAM to $8000 to $9FFF =
    // ================================== 
    // $FF4F [0] selects which bank
    // 1000 0000 0000 0000
    // 1001 1111 1111 1111
    // 3 inputs
    assign AddressVRAM = (MemoryBus.Address[15:13] == 3'b100);
    assign VideoRAM.Access = AddressVRAM && MemoryBus.Access;
    assign VideoRAM.Write = AddressVRAM && MemoryBus.Write;

    // VRAM bank or OAM
    assign VideoRAM.Address = AddressVRAM
                            ? {2'b00, IOHRAM['hff4f][0] & IsCGB, MemoryBus.Address[12:0]}
                            : MemoryBus.Address; 
    assign VideoRAM.DToTarget = MemoryBus.DToTarget;

    // =======================================================
    // = Map SystemRAM to $C000 to $DFFF echo $E000 to $FDFF =
    // =======================================================
    // Bank 0 at $C000 to $CFFF
    // Banks 1-7 at $D000 to $DFFF

    // System RAM Bank 0:
    // 1100 0000 0000 0000
    // 1100 1111 1111 1111

    // System RAM bank 1-7:
    // 1101 0000 0000 0000
    // 1101 1111 1111 1111

    // Have to skip OAM
    // 7 inputs
    assign AddressWRAM = (MemoryBus.Address[15:14] == 3'b11 && MemoryBus.Address[13:9] != 'b11111);

    assign SystemRAM.Access = AddressWRAM && MemoryBus.Access;
    assign SystemRAM.Write = AddressWRAM && MemoryBus.Write;

    // Banks are 4KiB, so the address for $D000-$DFFF is 12 bits plus the bank number at the top.
    // Bank select 0 puts bank 1 at $D000.
    // The bank select is $FF70 [2:0]
    // 6 inputs
    assign SystemRAM.Address[14:12] = (MemoryBus.Address[13:12] == 'b00) ? 'b00 : // Accessing the lower bank
                                      (!IsCGB || IOHRAM['hff70][2:0] == 'b000) ? 'b01 : // 00 = bank 1, also Bank 1 on CGB
                                      IOHRAM['hff70][2:0]; // Select from an upper bank on CGB
    assign SystemRAM.Address[11:0] = MemoryBus.Address[11:0];
    assign SystemRAM.DToTarget = MemoryBus.DToTarget;

    // $FE00-$FE9F OAM table
    // $FF00-$FF7F I/O
    // $FF80-$FFFE HRAM
    //       $FFFF Interrupt register
    // 10 inputs
    assign AddressOAM = MemoryBus.Address[15:8] == 'hfe &&
                       (MemoryBus.Address[7] == '0 || MemoryBus.Address[5] == 1'b0);
    assign AddressIOHRAM = MemoryBus.Address[15:8] == 'hff;

    always_comb
    begin
        if (AddressCart) // Cartridge
        begin
            MemoryBus.DToInitiator = Cartridge.DToInitiator;
            MemoryBus.Ready = Cartridge.Ready;
            MemoryBus.DataReady = Cartridge.DataReady;
            // GamePakBus.Audio = ?;
        end else if (AddressVRAM)
        begin
            // Gameboy talks to the VRAM now
            MemoryBus.DToInitiator = VideoRAM.DToInitiator;
            MemoryBus.Ready = VideoRAM.Ready;
            MemoryBus.DataReady = VideoRAM.DataReady;
        end else if (AddressWRAM)
        begin
            MemoryBus.DToInitiator = SystemRAM.DToInitiator;
            MemoryBus.Ready = SystemRAM.Ready;
            MemoryBus.DataReady = SystemRAM.DataReady;
        end else if (AddressOAM)
            // TODO:  OAM
        begin
        end else if (AddressIOHRAM)
        begin
            MemoryBus.Ready = '1;
            MemoryBus.DataReady = '1;
            MemoryBus.DToInitiator = IOHRAM[MemoryBus.Address];
        end else begin
            // Not implemented/accessible, ignore
            MemoryBus.DToInitiator = '0;
            MemoryBus.Ready = '1;
            MemoryBus.DataReady = '1;
        end
    end
    
    always_ff @(posedge Clk)
    if (ClkEn)
    begin
        // HRAM
        if (AddressIOHRAM && MemoryBus.Write)
            IOHRAM[MemoryBus.Address] <= MemoryBus.DToTarget;
    end

endmodule