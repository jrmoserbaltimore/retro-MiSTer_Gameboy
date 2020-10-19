// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// This is a full CPU memory bus controller.
//
// HRAM etc:
//   GameBoy->SystemBus (2 clock)
// Video:
//   GameBoy->SystemBus->Video (2 clock)
// Cartridge:
//  Gameboy->SystemBus->Mapper->Cache/BRAM (4 clock)
// OAM DMA:
//  Returns 'hff, stack explodes.
// HDMA:
//  When HDMA is active, SystemBus returns RTY, causing CPU to legitimately pause for a cycle.
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
    // Upper RAM and I/O registers
    logic [7:0] HRAM ['h00:'hff];
    // Banks
    wire VRAMBank = HRAM['h4f][0];
    wire [2:0] WRAMBank = HRAM['h70][2:0];
    // DMA
    wire [7:0] OAMDMA = HRAM['h46];
    wire [15:0] HDMASource = {HRAM['h51], HRAM['h52][7:4], '0};
    wire [12:0] HDMADest = {HRAM['h53], HRAM['h54][7:4], '0};
    wire [6:0] HDMALength = HRAM['h55][6:0];
    wire HDMAMode = HRAM['h55][7];
    // Close out the boot ROM if this is != 0
    wire InitCycle = !HRAM['h50];

    wire AddressCartridge;
    wire AddressIOHRAM;
    wire AddressVRAM;
    wire AddressWRAM;
    wire AddressOAM;
    wire AddressRetroRegs;

    // $fea0..$fea7
    assign AddressRetroRegs = MemoryBus.ADDR[15:8] == 'hfea;

    assign AddressOAM = MemoryBus.ADDR[15:8] == 'hfe
                     && MemoryBus.ADDR[7:5] != 'b101 // 0xa
                     && MemoryBus.ADDR[7:6] != 'b11; // more than 0xa
    // ==================================
    // = Map VideoRAM to $8000 to $9FFF =
    // ================================== 
    // $FF4F [0] selects which bank
    // 1000 0000 0000 0000
    // 1001 1111 1111 1111
    //
    // VideoRAM address space is 
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
    wire AddressEcho = (MemoryBus.ADDR[15:13] == 'b111 && MemoryBus.ADDR[15:9] != 'b1111111);

    // ======================================================
    // = Map Cartridge to $0000 to $7FFF and $A000 to $BFFF =
    // ======================================================
    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space
    //   - $FEA0-$FEA6 configuration registers during init
    // 3 inputs
    assign AddressCartridge = !MemoryBus.ADDR[15] || MemoryBus.ADDR[15:13] == 'b101
                           || ((AddressRetroRegs && !MemoryBus.ADDR[3]
                               && MemoryBus.ADDR[2:0] != 'b111) && !InitCycle);

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
    // This algorithm constructs a correct address from an EchoRAM address.
    wire [13:0] WRAMAddress = { MemoryBus.ADDR[12] ? (WRAMBank || 'b01) : 'b00, MemoryBus.ADDR[11:0] };

    logic [7:0] DMACount;
    logic [7:0] DMACycles;
    wire DMAActive = DMACount != 'hff;
    logic HDMAActive;

    // 'b01 - Cartridge
    // 'b10 - Video
    // 'b11 - WRAM    
    logic [1:0] RequestOutstanding;
    
    // Stalls are to keep the game boy in sync
    assign MemoryBus.ForceStall =
                           // Any bus stalled
                           Cartridge.Stalled() || VideoRAM.Stalled() || SystemRAM.Stalled()
                           // waiting on any request from any bus, stalled or not
                        || RequestOutstanding
                           // DMA did not finish in the time it should, so stall the Game Boy
                        || (DMAActive && !DMACycles);
    
    always_ff @(posedge SysCon.CLK)
    if (SysCon.RST)
    begin
        // Clear internal state for stall, ACK/ERR/RTY
        MemoryBus.Unstall();
        MemoryBus.PrepareResponse();
        DMACount <= 'hff;
        HDMAActive <= '0;
        //HRAM <=  '{default:'0};
        HRAM['h50] <= '0; // init cycle
        RequestOutstanding = '0;
    end else
    begin
        MemoryBus.PrepareResponse();
        Cartridge.Prepare();
        VideoRAM.Prepare();
        SystemRAM.Prepare();

        // =============
        // == OAM DMA ==
        // =============
        if (DMAActive)
        begin
            // OAM DMA occurs all at once; the system bus counts out the OAM DMA period separate
            // from the actual operation.
            // DMA becomes active after a write to the DMA register, which won't occur if waiting
            // for other buses.
            if (!VideoRAM.Stalled())
            case (OAMDMA[7:5])
            'b000,
            'b101: // Source is cartridge
            begin
                if (Cartridge.ResponseReady() || DMACount == 160)
                begin
                    // Both buses are available, so transfer the data to OAM and start the next rq
                    DMACount <= DMACount - 1;
                    if (DMACount) Cartridge.RequestData({OAMDMA, DMACount - 1});
                    
                    // VRAM bus is available, so send the data we just got to that
                    // TGA 'b1:  OAM
                    // TGC 'b1:  OAM DMA cycle, terminates the cycle when ADDR=0
                    if (DMACount != 160)
                        VideoRAM.SendData(DMACount, Cartridge.GetResponse(),,'b1,'b1);
                end
            end
            'b100: // Source is video
            begin
                // Note that the method used for transfers from 8000h-9FFFh (display RAM) is
                // different from that used for transfers from other addresses.
                // TGA 'b0:  Normal address space
                // TGA 'b1:  OAM DMA cycle,  copy from normal address space to OAM.  Terminates
                // after copying to OAM['h00]
                if (DMACount != 160)
                    VideoRAM.SendData({ VRAMBank, OAMDMA[4:0], DMACount }, '0,,'0,'1);
                DMACount <= DMACount - 1; 
            end
            'b110: // WRAM
            begin
                if (SystemRAM.ResponseReady() || DMACount == 160)
                begin
                    // Both buses are available, so transfer the data to OAM and start the next rq
                    DMACount <= DMACount - 1;
                    if (DMACount) SystemRAM.RequestData(
                                { OAMDMA[4] ? (WRAMBank || 'b01) : 'b00, OAMDMA[3:0], DMACount - 1}
                               );
                    if (DMACount != 160)
                        VideoRAM.SendData(DMACount, SystemRAM.GetResponse(),,'b1,'b1);
                end
            end
            endcase
        end

        // ==========
        // == HDMA ==
        // ==========
        // TODO:  HDMA with interaction with video mode

        // ================================
        // == General Access Arbitration ==
        // ================================
        // Something is accessing the system bus and we're not stalled

        // Requests will not be outstanding when doing DMA (return garbage) or HDMA (RTY)
        case (RequestOutstanding)
        'b01:
            if (Cartridge.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(Cartridge.GetResponse());
            end
        'b10:
            if (VideoRAM.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(VideoRAM.GetResponse());
            end
        'b11:
            if (SystemRAM.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(SystemRAM.GetResponse());
            end
        endcase        
        if (!MemoryBus.STALL && MemoryBus.RequestReady())
        begin
            // FIXME:  Make sure DMA and HDMA behavior are correct
            if (HDMAActive || DMAActive)
            begin
                // decrement to 0 but no further
                DMACycles <= DMACycles - (DMAActive & |DMACycles);
                // If DMA, return garbage.  This instruction floods the stack with 320 bytes.
                if (DMAActive) MemoryBus.SendResponse('hff, 'b0);
                // If HDMA, indicate that the memory bus is held, so the CPU pauses, but the
                // Game Boy is not delayed (doesn't trigger CATC)
                if (HDMAActive) MemoryBus.SendRetry();
            end else if (!HDMAActive)
            begin
                // $0000-$7fff
                // $a000-$bfff
                // $fea0-$fea6
                if (AddressCartridge)
                begin
                    if (MemoryBus.WE)
                        Cartridge.SendData(MemoryBus.ADDR, MemoryBus.DAT_ToTarget);
                    else
                        Cartridge.RequestData(MemoryBus.ADDR);
                    RequestOutstanding <= 'b01;
                end

                // $8000-$9fff
                if (AddressVRAM)
                begin
                    // 14-bit address space addresses two banks of 8192
                    if (MemoryBus.WE)
                        VideoRAM.SendData({VRAMBank, MemoryBus.ADDR[12:0]}, MemoryBus.DAT_ToTarget);
                    else
                        VideoRAM.RequestData({VRAMBank, MemoryBus.ADDR[12:0]});
                    RequestOutstanding <= 'b10;
                end

                // $a000-$bfff:  Cartridge, above
                // $c000-$fdff
                if (AddressWRAM || AddressEcho)
                begin
                    if (MemoryBus.WE)
                        SystemRAM.SendData(WRAMAddress, MemoryBus.DAT_ToTarget);
                    else
                        SystemRAM.RequestData(WRAMAddress);
                    RequestOutstanding <= 'b11;
                end

                // $fe00-$fe9f
                if (AddressOAM)
                begin
                    // TGA address tag is OAM ('b1)
                    if (MemoryBus.WE)
                        VideoRAM.SendData({6'b0, MemoryBus.ADDR[7:0]}, MemoryBus.DAT_ToTarget,,'b1);
                    else
                        VideoRAM.RequestData({6'b0, MemoryBus.ADDR[7:0]},,,'b1);
                    RequestOutstanding <= 'b10;
                end

                // $fea0-$fea6:  Cartridge, above
                
                // $fea7-$feff
                // Just toss random data out
                if (AddressRetroRegs && !AddressCartridge)
                begin
                    MemoryBus.SendResponse(HRAM[MemoryBus.ADDR[7:0]]);
                end
                
                // $ff00-$ffff
                // IO and HRAM access works during DMA but not HDMA
                if (AddressIOHRAM)
                begin
                    // Always ACK
                    MemoryBus.SendResponse(HRAM[MemoryBus.ADDR[7:0]]);
                    if (MemoryBus.WE)
                    begin
                        HRAM[MemoryBus.ADDR[7:0]] <= MemoryBus.DAT_ToTarget;
                        case (MemoryBus.ADDR[7:0])
                            'h46: // OAM DMA
                            begin
                                DMACount <= 160;
                                DMACycles <= 160;
                            end
                        endcase
                    end
                end
                
                if (AddressRetroRegs)
                begin
                end
            end // !HDMAActive
        end // !MemoryBus.STALL && MemoryBus.RequestReady()
    end
// Verification
`ifdef FORMAL
    // Skid Buffer Process:
    //  - Clock 0:  sender => STB0
    //  - Clock 1:  skid bufer <= STALL
    //              sender => STB1 (!)
    //                     => skid buffer => reg, STB1
    //  - Clock 2:  sender <= STALL
    //              sender => STB2
    //                     => skid buffer
    //   Assume:  if STALL and CYC and STB on this clock, all inputs remain stable on next clock

    // Bus management process:
    //  CYC&STB:
    //   - 
`endif

endmodule