// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// This is a full CPU memory bus controller.
//
// HRAM etc:
//   GameBoy->SystemBus (2 clock)
// Video:
//   GameBoy->SystemBus->Video (5 clock)
// Cartridge:
//  Gameboy->SystemBus->Mapper->Cache/BRAM (7 clock)
//
//
// Retro-GBC Registers:
//  - Mapper Registers
//    - $FEA0 MapperType
//    - $FEA1 ROMSize
//    - $FEA2 RAMSize
//    - $FEA3 ROMBankMask[7:0]
//    - $FEA4 ROMBankMask[8]
//    - $FEA5 RAMBankMask[3:0]
//    - $FEA6 Cartridge characteristics
//      - .0 HasRAM
//      - .1 HasBattery
//      - .2 HasTimer
//      - .3 HasRumble
//      - .4 HasSensor
//  - $FEA7 - Platform flag
//    - Bit 0:  0=DMG, 1=GBC
//    - Bit 1:  0=DMG compatibility, 1=GBC Only
//    - Bit 2:  SGB
// Areas to map:
//   - Mapper
//     - $0000-$7FFF
//     - $A000-$BFFF
//     - Retro Registers $FEA0-$FEA6
//   - Video
//     - $8000-$9FFF (VRAM, with bank select bit)
//     - $FE00-$FE9F (OAM)
//     - Registers FF40-FF42, FF44-FF45, FF47-FF49, FF4A-FF4B
//     - CGB Registers FF68-FF6C, FF70
//   - Sound
//     - Sound Channel Registers FF10-14, FF16-FF1E, FF20-FF26
//     - Waveform Register FF30-3F
//   - I/O
//     - FF00 (Joystic)
//     - FF01-FF02 (Serial I/O)
//     - FF04-FF07 (Timer)
//     - FF56 (IR port)
// Internal areas:
//   - Bank control
//     - FF4F (CGB VRAM Bank)
//     - FF70 (CGB WRAM Bank)
//   - DMA
//     - FF46 (OAM)
//     - FF51-FF55 (CGB HDMA)
//   - FF80-FFFE (HRAM)
// Game Boy registers:
//  - FFFF Interrupt Enable
//  - FF0F Interrupt Flag
//  - FF4D (Prepare speed switch)
//  - FF50 Exit Boot ROM
//
// TODO:
//   - Implement DMA
//   - Gameboy Color detection
//   - LCD interrupt?
module GBCMemoryBus
#(
    parameter DeviceType = "Xilinx",
    parameter LowPower = 0
)
(
    IWishbone.SysCon SysCon,

    // RAM for memory map
    IWishbone.Initiator SystemRAM, // Gameboy system RAM
    IWishbone.Initiator VideoRAM, // Video module

    // Cartridge controller
    IWishbone.Initiator Cartridge,
    // System bus it exposes
    // Communication to main system via TGC.  System can call for boot from ROM, and controller can
    // call for save states and save RAM.
    IWishbone.Target MemoryBus
);

    logic IsCGB;
    wire VRAMBank;
    wire [2:0] WRAMBank;
    wire [7:0] OAMDMA;
    wire [15:0] HDMASource;
    wire [12:0] HDMADest;
    wire [6:0] HDMALength;
    wire InitCycle;
    wire HDMAMode;
    logic [7:0] HRAM ['h00:'hff];

    assign OAMDMA = HRAM['h46];
    assign VRAMBank = HRAM['h4f][0];
    assign HDMASource = {HRAM['h51], HRAM['h52][7:4], '0};
    assign HDMADest = {HRAM['h53], HRAM['h54][7:4], '0};
    assign HDMALength = HRAM['h55][6:0];
    assign HDMAMode = HRAM['h55][7];
    assign WRAMBank = HRAM['h70][2:0];
    assign InitCycle = !HRAM['h50];

    wire AddressMapper;
    wire AddressIOHRAM;
    wire AddressVRAM;
    wire AddressWRAM;
    wire AddressOAM;
    wire AddressRetroRegs;
    wire i_valid;
    
    // $fea0..$fea7
    assign AddressRetroRegs = MemoryBus.ADDR[15:8] == 'hfea && !MemoryBus.ADDR[3];
    
    assign i_valid = MemoryBus.CYC && MemoryBus.STB;

    assign AddressOAM = MemoryBus.ADDR[15:8] == 'hfe
                     && MemoryBus.ADDR[7:5] != 'b101 // 0xa
                     && MemoryBus.ADDR[7:6] != 'b11; // more than 0xa
    // ==================================
    // = Map VideoRAM to $8000 to $9FFF =
    // ================================== 
    // $FF4F [0] selects which bank
    // 1000 0000 0000 0000
    // 1001 1111 1111 1111
    // VRAM and OAM are dual-port, accessible by the System Bus and the Video device concurrently.
    // During access by the Video device in mode 2, Video sends CTG='b01 (OAM).  In mode 3, it sends
    // it sends CTG='b11 (Video and OAM).
    //
    // The System Bus sendsn CTG='b1 during an OAM DMA, which overrides video access to OAM and
    // causes blank lines to be drawn.  With HDMA, nothing special happens, aside from pausing the
    // CPU during HDMA transfer.  The System Bus pauses the CPU by responding to an access request
    // with RTY, which tells the Gameboy to continue stalling the CPU and to acknowledge a ClkEn
    // rather than stalling.
    assign AddressVRAM = MemoryBus.ADDR[15:13] == 'b100;

    // VRAM Address:
    // VRAMBank + ADDR[12:0]
    assign AddressIOHRAM = MemoryBus.ADDR[15:8] == 'hff;
    assign AddressBootEnd = AddressIOHRAM && MemoryBus.ADDR[7:0] == 'h50;
    assign AddressWRAM = MemoryBus.ADDR[15:13] == 'b110;
    
    logic [7:0] DOutReg;

    // ======================================================
    // = Map Cartridge to $0000 to $7FFF and $A000 to $BFFF =
    // ======================================================
    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space
    // 3 inputs
    assign AddressMapper = !MemoryBus.ADDR[15] || MemoryBus.ADDR[15:13] == 'b101;

    // VRAM bank or OAM
    // VRAM address is always
    // AddressOAM ? MemoryBus.ADDR : { 2'b00, VRAMBank, MemoryBus.ADDR[12:0] }

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

    // Banks are 4KiB, so the address for $D000-$DFFF is 12 bits plus the bank number at the top.
    // Bank select 0 puts bank 1 at $D000.
    // The bank select is $FF70 [2:0]
    // 2 inputs
    // { (MemoryBus.ADDR[13:12] == 'b00) ? 'b00 : (WRAMBank || 'b00),
    //   MemoryBus.ADDR[11:0] }

    logic BusSwitch;
    wire BusSwitchRegister;
    wire BusSwitchSystemRAM;
    wire BusSwitchVideoRAM;
    wire BusSwitchCartridge;
    logic [7:0] RegisterReadBuffer;
    logic [3:0] BusSwitchPendingBus;
    logic [4:0] OutstandingTransactions;
    
    assign BusSwitchRegister = BusSwitchPendingBus[0];
    assign BusSwitchSystemRAM = BusSwitchPendingBus[1];
    assign BusSwitchVideoRAM = BusSwitchPendingBus[2];
    assign BusSwitchCartridge = BusSwitchPendingBus[3];

    // Stall if either bus is stalling, Initiator changed buses, or we can't count more pending ACKs.
    // Better have a skid buffer.
    assign MemoryBus.STALL = SystemRAM.STALL || VideoRAM.STALL || Cartridge.STALL || BusSwitch
                            || &OutstandingTransactions;

    always_ff @(posedge SysCon.CLK)
    begin
        var int DeltaOT;
        if (SysCon.RST)
        begin
            // Set all outgoing CYC to 0, drop all pending responses
            SystemRAM.CYC <= '0;
            VideoRAM.CYC <= '0;
            Cartridge.CYC <= '0;
        end else if (BusSwitch && !OutstandingTransactions) // STALL with no pending transactions
        begin
            // if it was a register access, just ACK and load memory
            MemoryBus.ACK <= BusSwitchRegister;
            MemoryBus.ERR <= '0;
            MemoryBus.RTY <= '0;
            MemoryBus.DAT_ToInitiator <= RegisterReadBuffer;
            // Else strobe the correct bus
            if (!BusSwitchRegister)
            begin
                SystemRAM.CYC <= BusSwitchSystemRAM;
                SystemRAM.STB <= BusSwitchSystemRAM;
                VideoRAM.CYC <= BusSwitchVideoRAM;
                VideoRAM.STB <= BusSwitchVideoRAM;
                Cartridge.CYC <= BusSwitchCartridge;
                Cartridge.STB <= BusSwitchCartridge;
                DeltaOT += 1;
            end

            // Done here
            BusSwitch <= '0;
        end else if (i_valid && !MemoryBus.STALL)
        begin
            if (AddressMapper ||(InitCycle && AddressRetroRegs))
            begin
                // Switch to cartridge bus
                BusSwitch <= !Cartridge.CYC;
                BusSwitchPendingBus <= 'b1000;
                if (!(SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC))
                begin
                    Cartridge.CYC <= '1;
                    Cartridge.STB <= '1;
                    DeltaOT += 1;
                end
                Cartridge.ADDR <= MemoryBus.ADDR;
                Cartridge.WE <= MemoryBus.WE;
            end
            if (AddressIOHRAM)
            begin
                if (MemoryBus.ADDR[7])
                begin
                    // Place HRAM directly
                    //BusSwitch <= |OutstandingTransactions;
                    BusSwitch <= SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC; 
                    BusSwitchPendingBus <= 'b0001; // Register

                    // Store immediately
                    if (MemoryBus.WE) HRAM[MemoryBus.ADDR[7:0]] <= MemoryBus.DAT_ToTarget;
                    // ACK immediately and return data if nothing else is going on
                    if (!(SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC))
                    begin
                        MemoryBus.ACK <= '1;
                        MemoryBus.DAT_ToInitiator <= HRAM[MemoryBus.ADDR[7:0]];
                    end
                    // Store into the buffer in any case, unless low power
                    if (!LowPower || SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC)
                        RegisterReadBuffer <= HRAM[MemoryBus.ADDR[7:0]];
                end else case (MemoryBus.ADDR[6:0])
                'h46, // OAM DMA
                'h4f, // CGB VRAM Bank
                'h51, // CGB HDMA
                'h52,
                'h53,
                'h54,
                'h55,
                'h70: // WRAM Bank
                    begin
                        // XXX: Duplicate code
                        // Place HRAM directly
                        //BusSwitch <= |OutstandingTransactions;
                        BusSwitch <= SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC; 
                        BusSwitchPendingBus <= 'b0001; // Register
    
                        // Store immediately
                        if (MemoryBus.WE) HRAM[MemoryBus.ADDR[7:0]] <= MemoryBus.DAT_ToTarget;
                        // ACK immediately and return data if nothing else is going on
                        if (!(SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC))
                        begin
                            MemoryBus.ACK <= '1;
                            MemoryBus.DAT_ToInitiator <= HRAM[MemoryBus.ADDR[7:0]];
                        end
                        // Store into the buffer in any case, unless low power
                        if (!LowPower || SystemRAM.CYC || VideoRAM.CYC || Cartridge.CYC)
                            RegisterReadBuffer <= HRAM[MemoryBus.ADDR[7:0]];
                    end
                endcase
            end
        end
    end

endmodule