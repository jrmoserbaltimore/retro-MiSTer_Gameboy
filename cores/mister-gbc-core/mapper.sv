// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Every useful Game Boy Color mapper implemented at once.
//
// The LoadImage address bus is hard-coded to 23 bits or 8 megabytes, the largest game.
//
// Boot cycle:
//
//  - On SysCon.RST, enter initialization sequence
//  - The gameboy puts a boot ROM at $0000
//  - the gameboy (Retro) copies a Retro setup program into WRAM at $C000
//  - The Game Boy enters at $0000, which jumps to $C000
//  - The Retro setup program writes to a set of mapper registers:
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
//  - Pre-boot sets MapperType to 1 (ROM) to access header
//  - Pre-boot reads header to set up ROM type and characteristics
//  - Pre-boot initializes mapper by writing to registers
//  - Pre-boot sets $FEA0 to mapper type and returns into boot setup ROM
//  - Once boot ROM writes non-zero to $FF50, mapper registers are fixed
//
// This avoids doing work in here, instead relying on a custom boot ROM.
//
// The mapper appears to be logic depth 6 and not much routing.  tv80 Z80 is 7ns critical path.
module GBCMapper
(
    IWishbone.SysCon SysCon,
    // Pass caching modules for both of these.  CartridgeRAM can cache from DDR etc. (paging)
    // LoadImage and SystemRAM will incur delays fixed by CATC. 
    IWishbone.Initiator LoadImage,
    IWishbone.Initiator CartridgeRAM,
    IWishbone.Initiator RTC,

    // Export the memory bus back to the controller
    IWishbone.Target MemoryBus
);
    enum integer
    {
        ROM=0,
        MBC1=1,
        MBC2=2,
        MBC3=3,
        MBC5=4,
        MBC6=5,
        MBC7=6,
        MMM01=7,
        Camera=8,
        TAMA5=9,
        HuC3=10,
        HuC1=11
    } MapperTypes;

    // The header indicates how many ROM and RAM banks the cartridge has, which also determines
    // mapper behavior.
    logic [8:0] ROMBankID; // Up to 512 16K banks
    logic [3:0] RAMBankID; // Up to 16 Cartridge RAM banks, or MBC3 RTC register indexes

    logic BankingMode; // MBC1 $6000-$7FFF

    // RTC registers are copied from the RTC module when latched.
    logic [4:0] RTCRegisters[7:0];
    wire RTCLatched;
    assign RTCLatched = BankingMode;

    // Registers for init by boot rom
    logic [7:0] RetroRegisters [6:0];
    wire [5:0] MapperType = RetroRegisters[0][5:0];
    // ROM size packed to 4 bits ('b0101 is the only upper nibble, so just truncate)
    wire [3:0] ROMSize = RetroRegisters[1][3:0];
    wire [2:0] RAMSize = RetroRegisters[2][2:0];
    wire [8:0] ROMBankMask;
    assign ROMBankMask[7:0] = RetroRegisters[3];
    assign ROMBankMask[8] = RetroRegisters[4][0];
    wire [3:0] RAMBankMask = RetroRegisters[5][3:0];
    wire [4:0] CartFeatures = RetroRegisters[6][4:0];

    wire HasRAM = CartFeatures[0];
    wire HasBattery = CartFeatures[1];
    wire HasTimer = CartFeatures[2];
    wire HasRumble = CartFeatures[3];
    wire HasSensor = CartFeatures[4];

    logic RAMEnabled;
    //logic TimerEnabled = '0;
    //logic FlashEnabled = '0;
    //logic FlashWriteEnabled = '0;
    logic [8:0] UpperROMBank; // $0000-$3fff
    logic [8:0] LowerROMBank; // $4000-$7fff
    logic [3:0] RAMBank;

    wire TimerAccess = HasTimer && RAMBankID[3] && MemoryBus.STB && RAMEnabled;

    wire ROMAddress = {
                        // First or second bank?
                        MemoryBus.ADDR[14] ? UpperROMBank : LowerROMBank,
                        MemoryBus.ADDR[13:0]
                      };
    wire CRAMAddress = { RAMBank, MemoryBus.ADDR[12:0] };

    // Nice and easy:  ROM bank access is below 'h8000
    wire AddressROM = !MemoryBus.ADDR[15];

    // $c000-$f000    
    wire AddressCRAM = MemoryBus.ADDR[15:13] == 'b101;

    // 'b01 - LoadImage
    // 'b10 - CartridgeRAM
    // 'b11 - RTC
    logic [1:0] RequestOutstanding;

    assign MemoryBus.ForceStall = LoadImage.Stalled() || CartridgeRAM.Stalled() || RTC.Stalled()
                                  || RequestOutstanding;

    always_ff @(posedge SysCon.CLK)
    if (SysCon.RST)
    begin
        // Clear internal state for stall, ACK/ERR/RTY
        MemoryBus.Unstall();
        MemoryBus.PrepareResponse();
        RequestOutstanding = '0;
    end else
    begin
        MemoryBus.PrepareResponse();
        LoadImage.Prepare();
        CartridgeRAM.Prepare();
        RTC.Prepare();

        // ================================
        // == General Access Arbitration ==
        // ================================
        // Something is accessing the mapper and we're not stalled

        // Requests will not be outstanding when doing DMA (return garbage) or HDMA (RTY)
        case (RequestOutstanding)
        'b01:
            if (LoadImage.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(LoadImage.GetResponse());
            end
        'b10:
            if (CartridgeRAM.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(CartridgeRAM.GetResponse());
            end
        'b11:
            if (RTC.ResponseReady())
            begin
                RequestOutstanding <= '0;
                MemoryBus.SendResponse(RTC.GetResponse());
            end
        endcase        

        if (!MemoryBus.STALL && MemoryBus.RequestReady())
        begin
            // $0000-$7fff
            if (AddressROM)
            begin
                if (MemoryBus.WE)
                begin
                    // ==========================
                    // = Mapper register access =
                    // ==========================
                    // Writes to mapper registers must control the stored register values so the simple read
                    // logic doesn't get bad input.
                    // ACK the request immediately
                    MemoryBus.SendResponse('hff);
                    if (MapperType[ROM])
                    begin
                        // This space intentionally left blank
                    end
                    if (MapperType[4:1]) // MBC1 to MBC5
                    case (MemoryBus.ADDR[15:13])
                        // Type MBC1-MBC5 are fairly similar, and the same logic can make a number of decisions
                        // about which action to take for which mapper.  These mappers support different sizes
                        // of ROM and RAM.
                        3'b000: // 'h0000 to 'h1fff
                        begin
                            //$0000-$1FFF   RAM enable (set to $0a) MBC1, MBC2, MBC3, MBC5
                            //              Timer enable            MBC3
                            if (!MapperType[MBC2] || MemoryBus.ADDR[8])
                                RAMEnabled <= (MemoryBus.DAT_ToTarget[3:0] == 'ha);
                            else // Always below 'h2fff for MBC5
                                ROMBankID[7:0] <= (!MemoryBus.DAT_ToTarget && !MapperType[MBC5])
                                                  ? '1
                                                  : MemoryBus.DAT_ToTarget & ROMBankMask[7:0];
                        end
                        3'b001: //('h2000..'h3fff)
                        begin
                            //$2000-$3FFF   ROM Bank number         MBC1, MBC2, MBC3
                            //$2000-$2FFF   ROM Bank low bits       MBC5
                            //$3000-$3FFF   ROM Bank high bits      MBC5
                            if (MapperType[MBC2] && MemoryBus.ADDR[8])
                                RAMEnabled <= (MemoryBus.DAT_ToTarget[3:0] == 'ha);
                            else if (!MapperType[MBC5] || !MemoryBus.ADDR[12]) // <= 'h2fff for MBC5
                            begin
                                // MBC1 and MBC3 force '0 to '1
                                ROMBankID[7:0] <= (!MemoryBus.DAT_ToTarget && !MapperType[MBC5])
                                                  ? '1
                                                  : MemoryBus.DAT_ToTarget & ROMBankMask[7:0];
                            end else // MBC5 high bits
                            begin
                                ROMBankID <= {MemoryBus.DAT_ToTarget[0] & ROMBankMask[8], ROMBankID[7:0]};
                            end
                        end
                        3'b010: // ('h4000..'h5fff)
                        begin
                            //$4000-$5FFF   RAM bank number         MBC1, MBC3, MBC5
                            //              ROM bank high bits      MBC1 (1Mb+ carts)
                            //              RTC Register select     MBC3 (higher values)
                            // MBC1 behavior is based on RAM and ROM size
                            // MBC3 and MBC5 behave normally
                            // FIXME:  Doesn't set ROM bank high bits for MBC1 1Mb+
                            RAMBankID <= MemoryBus.DAT_ToTarget[3:0];
                        end
                        3'b011: //('h6000..'h7fff)
                        begin
                            //$6000-$7FFF   Banking mode select     MBC1
                            //              Latch clock data        MBC3
                            // Both registers are the BankingMode register; they're exclusive to their
                            // respective mappers
                            BankingMode <= MemoryBus.DAT_ToTarget[0];
                            // TODO:  If (TimerAccess) and BankingMode 0 -> 1, latch
                        end
                        3'b101: // 'ha000..'hbfff, RAM and timer
                        begin
                            if (TimerAccess)
                            begin
                            // TODO:  RTC access
                                // FIXME:  Need to latch the registers when appropriate
                                // FIXME:  When setting the clock, store the offset from the real RTC
                            
                                // Write to the timer registers
                                //if (MemoryBus.WE) RTCRegisters[RAMBankID[2:0]] <= MemoryBus.DAT_ToInitiator;
                            end
                        end
                    endcase // Mappers MBC1 to MBC5
                    // MBC6:  Net de Get Minigame @ 100, no other games, and not useful
                    // MBC7:  Kirby Tilt 'n Tumble, Command Master
                    // MMM01:  Taito variety pack
                    // TAMA5:  Tamogaci
                    // HuC1:  a few games
                end else // Register access
                begin
                    // =================
                    // = ROM bank read =
                    // =================
                    LoadImage.RequestData(ROMAddress);
                    RequestOutstanding <= 2'b01;
                end // ROM bank read
            end // Addressing ROM $0000-$7fff area        

            // ===================
            // = RAM bank access =
            // ===================
            // $c000-$dfff
            if (AddressCRAM) // Read from mapped RAM
            begin
                if (MemoryBus.WE)
                    CartridgeRAM.SendData(CRAMAddress, MemoryBus.GetRequest());
                else
                    CartridgeRAM.RequestData(CRAMAddress);
                RequestOutstanding <= 2'b10;
            end // RAM bank read

            // ===================================
            // = Mapper internal register access =
            // ===================================
            // System bus filters out writes when boot ROM is closed
            if (MemoryBus.ADDR[15:4] == 'hfea)
            begin
                // Sets up the registers.  Writing non-zero to $FE50 locks these until reset
                if (MemoryBus.WE)
                    RetroRegisters[MemoryBus.ADDR[3:0]] <= MemoryBus.GetRequest();
                MemoryBus.SendResponse(RetroRegisters[MemoryBus.ADDR[3:0]]);
            end
        end // !MemoryBus.STALL && MemoryBus.RequestReady()
    end

    // =======================
    // = ROM bank Addressing =
    // =======================
    // Setting the ROM bank address bits combinationally simplifies the access code.
    always_comb
    begin
        // This if statement should select an output from a MUX, so in parallel to its contents.
        if (MapperType[MBC1] || MapperType[MBC2] || MapperType[MBC3] || MapperType[MBC5])
        begin
            // Can't be 0 except on MBC5
            // This is two logic levels deep and leaves resources for two wires; it begins at the
            // root of this always_comb block.
            // 5-LUT: ROMBankID[4:1] || MapperType[MBC5]
            // 5-LUT: ROMBankID[0] & (A || (MapperType[MBC3] && ROMBankID[6:5]))
            // Might save the Mux by ORing with MapperType[ROM]
            UpperROMBank[0] = ROMBankID[0] &
                              (
                                ROMBankID[4:1] // MBC1
                                || MapperType[MBC5]
                                || (MapperType[MBC3] && ROMBankID[6:5])
                              );
            // One logic level from root
            UpperROMBank[4:1] = (ROMBankID[4:1] & ROMBankMask[4:1]);
            // In total, each bit depends on:
            // MapperType[MBC1], BankingMode, RAMBankID, ROMBankMask, ROMBankID, ROMBankMask
            // One 6-LUT per bit (or to select a mux).
            if (MapperType[MBC1])
            begin
                UpperROMBank[6:5] = (BankingMode && ROMBankMask[5]) ? RAMBankID[1:0] : '0;
                UpperROMBank[8:7] = '0;
            end else
            begin
                UpperROMBank[8:5] = ROMBankID[8:5] & ROMBankMask[8:5];
            end
            
            LowerROMBank[4:0] = '0;
            // MBC1 advanced mode with large ROM, switch the lower bank on the RAM bank register.
            // Other mappers:  lower bank is 0.
            LowerROMBank[6:5] = (BankingMode && ROMBankMask[5]) ? RAMBankID[1:0] : '0;
            LowerROMBank[8:7] = '0;
            
            // Mux into a 2-output 6-LUT (two 2-LUT), or 1 5-LUT per bit.
            // Logic depth 2 is still our critical path.
            RAMBank = ((BankingMode && !ROMBankMask[5]) || !MapperType[MBC1])
                      ? RAMBankID & RAMBankMask // Anything not MBC1 with RAM banking off
                      : '0; // MBC1 if RAM banking off
        end else
        begin
            // ROM is just the lower 15 bits of the address
            LowerROMBank = '0;
            UpperROMBank = '1;
        end
        // Mappers beyond MBC5 are highly specialized and not supported.
        // MBC6 is only one game; MBC7 has accelerometers.
        // HuC1 used IR COMM, Pokemon TCG used this
    end

endmodule