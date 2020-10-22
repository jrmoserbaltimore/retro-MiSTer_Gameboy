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
// Note the pixel pipeline will synchronize with the CPU clock and stall when the CPU is stalled.
// OAMDMA in particular can occur despite the stall; the video device notes the starting point of
// OAMDMA and counts each executed synchronized clock to ensure no sprite drawing occurs on DMA
// timing.
// 
//
// Retro-GBC Registers:
//  - Mapper Registers (Done)
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
//   - Mapper (Done)
//     - $0000-$7FFF
//     - $A000-$BFFF
//     - Retro Registers $FEA0-$FEA6
//   - Video (Done)
//     - $8000-$9FFF (VRAM, with bank select bit)
//     - $FE00-$FE9F (OAM)
//     - Registers FF40-FF45, FF47-FF4B
//     - CGB Registers FF68-FF6C
//   - Sound
//     - Sound Channel Registers FF10-14, FF16-FF1E, FF20-FF26
//     - Waveform Register FF30-3F
//   - I/O [XXX:  Just make this one Wishbone bus? with 4 address spaces? Combine with sound?]
//     - FF00 (Joypad) (Done)
//     - FF01-FF02 (Serial I/O)
//     - FF04-FF07 (Timer)
//     - FF56 (IR port) (Done)
// Internal areas:
//   - Bank control (Done)
//     - FF4F (CGB VRAM Bank)
//     - FF70 (CGB WRAM Bank)
//   - DMA
//     - FF46 (OAM) (Done)
//     - FF51-FF55 (CGB HDMA)
//   - HRAM (Done)
//     - FF80-FFFE
// Game Boy registers:  [Direct map?]
//  - FFFF Interrupt Enable
//  - FF0F Interrupt Flag
//  - FF4D (Prepare speed switch)
//  - FF50 Exit Boot ROM
//
// TODO:
//   - Gameboy Color detection
//   - LCD interrupt?
module GBCMemoryBus
#(
    parameter DeviceType = "Xilinx",
    parameter LowPower = 0
)
(
    ISysCon SysCon,

    // RAM for memory map
    IWishbone.Initiator SystemRAM, // Gameboy system RAM
    // Video address spaces:
    //  - TGA = 2'b00:  VRAM
    //  - TGA = 2'b01:  OAM
    //  - TGA = 2'b10:  Registers
    // Video modes:
    //  - TGC = 1'b0:  Regular
    //  - TGC = 1'b1:  OAM DMA (if address space is VRAM, copy from VRAM rather than input to OAM)
    IWishbone.Initiator VideoRAM, // Video module
    input logic [2:0] VideoStatus, // from FF41, read-only
    // Cartridge controller
    IWishbone.Initiator Cartridge,
    
    // Wishbone bus for joypad is overkill:  it's one register and no timing concerns
    input logic [5:0] JoypadIn,
    output logic [5:4] JoypadOut,
    
    // Same is true of the IR port (ff56)
    // 2:  Read data (Bit 1, read-only)
    // 1:  Write data (Bit 0)
    // 0:  Data read enable (Bits 6-7)
    input logic [2:0] IRIn,  
    output logic [1:0] IROut,
    
    //IWishbone.Initiator AudioPU,
    // TODO:  serial, timer/divider??
    
    // System bus it exposes
    // Communication to main system via TGC.  System can call for boot from ROM, and controller can
    // call for save states and save RAM.
    IWishbone.Target MemoryBus
);

    logic IsCGB;
    // Upper RAM and I/O registers
    logic [7:0] HRAM ['h00:'hff];
    //assign HRAM['h41][2:0] = VideoStatus; // read-only video registers
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

    wire AddressOAM = MemoryBus.ADDR[15:8] == 'hfe
                     && MemoryBus.ADDR[7:5] != 'b101 // 0xa
                     && MemoryBus.ADDR[7:5] != 'b110 // more than 0xa
                     && MemoryBus.ADDR[7:5] != 'b111;
    // $fea0..$fea7
    wire AddressRetroRegs = MemoryBus.ADDR[15:8] == 'hfe && !AddressOAM;
    
    wire AddressIOHRAM = MemoryBus.ADDR[15:8] == 'hff;
    wire AddressWRAM = MemoryBus.ADDR[15:13] == 'b110;
    wire AddressEcho = (MemoryBus.ADDR[15:13] == 'b111 && !AddressOAM && !AddressIOHRAM && !AddressRetroRegs);
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
    wire AddressVRAM = MemoryBus.ADDR[15:13] == 'b100;
    // Registers FF40-FF45, FF47-FF4B
    // CGB Registers FF68-FF6C

    // VRAM Address:
    // VRAMBank + ADDR[12:0]

    // ======================================================
    // = Map Cartridge to $0000 to $7FFF and $A000 to $BFFF =
    // ======================================================
    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space
    //   - $FEA0-$FEA6 configuration registers during init
    // 3 inputs
    wire AddressCartridge = !MemoryBus.ADDR[15] || MemoryBus.ADDR[15:13] == 'b101;
//                           || ((AddressRetroRegs && !MemoryBus.ADDR[3]
//                               && MemoryBus.ADDR[2:0] != 'b111) && !InitCycle);

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
    
    // this is done with these wires because Vivado's simulator sees fs as 1 when all the inputs are 0.
    wire cs = Cartridge.Stalled();
    wire vs = VideoRAM.Stalled();
    wire ss = SystemRAM.Stalled();
    wire dc = (DMAActive && !DMACycles);
    
    //wire fs = Cartridge.Stalled() || VideoRAM.Stalled() || SystemRAM.Stalled() || RequestOutstanding || (DMAActive && !DMACycles);
    //wire fs2 = cs || vs || ss || dc || RequestOutstanding;
    
    // Stalls are to keep the game boy in sync
    assign MemoryBus.ForceStall = cs || vs || ss || dc || RequestOutstanding;
                           // Any bus stalled
                        //   Cartridge.Stalled() || VideoRAM.Stalled() || SystemRAM.Stalled()
                           // waiting on any request from any bus, stalled or not
                        //|| RequestOutstanding
                           // DMA did not finish in the time it should, so stall the Game Boy
                        //|| (DMAActive && !DMACycles);

    always_ff @(posedge SysCon.CLK)
    if (SysCon.RST)
    begin
        // Clear internal state for stall, ACK/ERR/RTY
        MemoryBus.Unstall();
        MemoryBus.PrepareResponse();
        Cartridge.Open();
        VideoRAM.Open();
        SystemRAM.Open();
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
            'b001,
            'b010,
            'b011: // Source is cartridge
            begin
                if (Cartridge.ResponseReady() || DMACount == 160)
                begin
                    // Both buses are available, so transfer the data to OAM and start the next rq
                    DMACount <= DMACount - 1;
                    if (DMACount) Cartridge.RequestData({OAMDMA, DMACount - 1});
                    
                    // VRAM bus is available, so send the data we just got to that
                    // TGA 'b01:  OAM
                    // TGC 'b1:  OAM DMA cycle, terminates the cycle when ADDR=0
                    if (DMACount != 160)
                        VideoRAM.SendData(DMACount, Cartridge.GetResponse(),,2'b01,1'b1);
                end
            end
            'b100,
            'b101: // Source is video
            begin
                // Note that the method used for transfers from 8000h-9FFFh (display RAM) is
                // different from that used for transfers from other addresses.
                // TGA 'b00:  Normal address space
                // TGA 'b1:  OAM DMA cycle,  copy from normal address space to OAM.  Terminates
                // after copying to OAM['h00]
                if (DMACount != 160)
                    VideoRAM.SendData({ VRAMBank, OAMDMA[4:0], DMACount }, '0,,2'b00,1'b1);
                DMACount <= DMACount - 1; 
            end
            'b110: // WRAM
            begin
                if (SystemRAM.ResponseReady() || DMACount == 160)
                begin
                    // Both buses are available, so transfer the data to OAM and start the next rq
                    DMACount <= DMACount - 1;
                    if (DMACount) SystemRAM.RequestData(
                                { OAMDMA[4] ? (WRAMBank || 2'b01) : 2'b00, OAMDMA[3:0], DMACount - 1}
                               );
                    if (DMACount != 160)
                        VideoRAM.SendData(DMACount, SystemRAM.GetResponse(),,2'b01,1'b1);
                end
            end
            default:  DMACount <= DMACount - 1; // XXX:  Should never happen
            endcase
        end

        // ==========
        // == HDMA ==
        // ==========
        // TODO:  HDMA with interaction with video mode

        if (HDMAActive)
        begin
            if (!HRAM['h55][7] || HRAM['h41][1:0] == 2'b00)
            begin
                // Either general-purpose ($ff55[7]==0) or only during H-Blank
                
                // TODO:
                //   - if it's time to do a transfer (LY-0-143, 
                //     - if counter == 0
                //       - $ff55[7], set counter to 15
                //     - else counter <= counter - 1
                //     - Transfer byte to VRAM
                //     - Reduce total HDMA transfer by 1 byte 
            end
        end
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
        if (!MemoryBus.Stalled() && MemoryBus.RequestReady())
        begin
            // FIXME:  Make sure DMA and HDMA behavior are correct
            // Each cycle, decrement to 0 but no further.
            // When this hits 0 during OAMDMA, the gameboy stalls (CATC will catch it up).
            // When OAMDMA finishes before DMACycles counts down, the system bus continues to
            // behave as if DMA is ongoing
            DMACycles <= DMACycles - |DMACycles;
            if (HDMAActive)
            begin
                // If HDMA, indicate that the memory bus is held, so the CPU pauses, but the
                // Game Boy is not delayed (doesn't trigger CATC)
                MemoryBus.SendRetry();
            end else if ((DMAActive || DMACycles) && !AddressIOHRAM)
            begin
                // If DMA is still running, return garbage.  This instruction floods the stack
                // with 320 bytes.  HRAM is still accessible.
                MemoryBus.SendResponse('hff, 2'b00);
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
                    RequestOutstanding <= 2'b01;
                end

                // $8000-$9fff
                if (AddressVRAM)
                begin
                    // 14-bit address space addresses two banks of 8192
                    if (MemoryBus.WE)
                        VideoRAM.SendData({VRAMBank, MemoryBus.ADDR[12:0]}, MemoryBus.DAT_ToTarget);
                    else
                        VideoRAM.RequestData({VRAMBank, MemoryBus.ADDR[12:0]});
                    RequestOutstanding <= 2'b10;
                end

                // $a000-$bfff:  Cartridge, above
                // $c000-$fdff
                if (AddressWRAM || AddressEcho)
                begin
                    if (MemoryBus.WE)
                        SystemRAM.SendData(WRAMAddress, MemoryBus.DAT_ToTarget);
                    else
                        SystemRAM.RequestData(WRAMAddress);
                    RequestOutstanding <= 2'b11;
                end

                // $fe00-$fe9f
                if (AddressOAM)
                begin
                    // TGA address tag is OAM ('b01)
                    if (MemoryBus.WE)
                        VideoRAM.SendData({6'b0, MemoryBus.ADDR[7:0]}, MemoryBus.DAT_ToTarget,,2'b01);
                    else
                        VideoRAM.RequestData({6'b0, MemoryBus.ADDR[7:0]},,,2'b01);
                    RequestOutstanding <= 2'b10;
                end

                // $fea0-$fea6:  Cartridge, above

                // $fea7-$feff
                // Just toss random data out
                if (AddressRetroRegs && !AddressCartridge)
                begin
                    case (MemoryBus.ADDR[7:0])
                    'ha0, 'ha1, 'ha2, 'ha3, 'ha4, 'ha5, 'ha6:
                        begin
                            if (MemoryBus.WE && InitCycle)
                                Cartridge.SendData(MemoryBus.ADDR, MemoryBus.DAT_ToTarget);
                            else
                                Cartridge.RequestData(MemoryBus.ADDR);
                            RequestOutstanding <= 2'b01;
                        end
                    'ha7:
                        begin
                            if (MemoryBus.WE && InitCycle) IsCGB <= MemoryBus.GetRequest();
                            MemoryBus.SendResponse(IsCGB);
                        end
                    default:
                        MemoryBus.SendResponse(8'hff);
                    endcase
                end

                // $ff00-$ffff
                // IO and HRAM access works during DMA but not HDMA
                if (AddressIOHRAM)
                begin
                    // Always ACK on HRAM access
                    if (MemoryBus.ADDR[7])
                    begin
                        MemoryBus.SendResponse(HRAM[MemoryBus.ADDR[7:0]]);
                        if (MemoryBus.WE) HRAM[MemoryBus.ADDR[7:0]] <= MemoryBus.GetRequest();
                    end else
                    begin // I/O access
                        case (MemoryBus.ADDR[7:0])
                            'h00: // Joypad
                            begin
                                if (MemoryBus.WE) JoypadOut = MemoryBus.DAT_ToTarget[5:4];
                                MemoryBus.SendResponse({2'b00, JoypadIn});
                            end
                            'h46: // OAM DMA
                            begin
                                if (MemoryBus.WE)
                                begin
                                    DMACount <= 160;
                                    DMACycles <= 160;
                                    HRAM[MemoryBus.ADDR[7:0]] <= MemoryBus.GetRequest();
                                end
                                MemoryBus.SendResponse(HRAM[MemoryBus.ADDR[7:0]]);
                            end
                            // Registers FF40-FF45, FF47-FF4B
                            // CGB Registers FF68-FF6C
                            'h40,  // LCD Control Register
                            'h41,  // Video status
                            'h42,  // Scroll Y
                            'h43,  // Scroll X
                            'h44,  // LCDC Y coordinate
                            'h45,  // LY Compare
                            'h47,  // Monochrome background palette data
                            'h48,  // Monochrome sprite palette 0 data
                            'h49,  // Monochrome sprite palette 1 data
                            'h4a,  // Window Y Position
                            'h4b,  // Window X Position minus 7
                            'h68,  // CGB:  Background palette index
                            'h69,  // CGB:  Background palette color data
                            'h6a,  // CGB:  Sprite palette index
                            'h6b,  // CGB:  Sprite palette color data
                            'h6c:  // CGB:  Object priority mode
                            begin
                                // Address space is registers TGA='b10
                                if (MemoryBus.WE)
                                    VideoRAM.SendData({6'b0, MemoryBus.ADDR[7:0]},
                                                      MemoryBus.GetRequest(),,2'b10);
                                else
                                    VideoRAM.RequestData({6'b0, MemoryBus.ADDR[7:0]},,,2'b10);
                                RequestOutstanding <= 2'b10;
                            end
                            'h56:  // CGB IR port
                            begin
                                // 2:  Read data (Bit 1, read-only)
                                // 1:  Write data (Bit 0)
                                // 0:  Data read enable (Bits 6-7)
                                if (MemoryBus.WE)
                                    IROut <= {MemoryBus.ADDR[0], &MemoryBus.ADDR[7:6]};
                                MemoryBus.SendResponse({IRIn[0], IRIn[0], // Data read enable
                                                        4'b0000, // Empty
                                                        IRIn[2], IRIn[1]}); // Read/write bits
                            end
                            default: // Send garbage
                                MemoryBus.SendResponse('hff); //(HRAM[MemoryBus.ADDR[7:0]] | 'h80);
                        endcase
                    end
                end // I/O and HRAM access
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