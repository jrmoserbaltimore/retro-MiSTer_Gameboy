// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Every Game Boy Color mapper implemented at once.
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
module GBCMapper
(
    IWishbone.SysCon SysCon,
    input logic Clk,
    input logic ClkEn,
    input logic Reset, // XXX
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
    
    // ROM size packed to 4 bits ('b0101 is the only upper nibble, so just truncate)
    logic [3:0] ROMSize;
    logic [2:0] RAMSize; 
    
    logic BankingMode; // MBC1 $6000-$7FFF
    
    logic [8:0] ROMBankMask;
    logic [3:0] RAMBankMask;

    // RTC registers are copied from the RTC module when latched.
    logic [4:0] RTCRegisters[7:0];
    wire RTCLatched;
    assign RTCLatched = BankingMode;

    logic [5:0] MapperType;

    logic [4:0] CartFeatures;
    wire HasRAM;
    wire HasBattery;
    wire HasTimer;
    wire HasRumble;
    wire HasSensor;
    wire TimerAccess;
    
    assign HasRAM = CartFeatures[0];
    assign HasBattery = CartFeatures[1];
    assign HasTimer = CartFeatures[2];
    assign HasRumble = CartFeatures[3];
    assign HasSensor = CartFeatures[4];

    logic RAMEnabled;
    //logic TimerEnabled = '0;
    //logic FlashEnabled = '0;
    //logic FlashWriteEnabled = '0;
    logic [8:0] UpperROMBank; // $0000-$3fff
    logic [8:0] LowerROMBank; // $4000-$7fff
    logic [3:0] RAMBank;
    logic [22:0] LIAddress;
    logic [16:0] CRAddress; 

    wire i_valid = MemoryBus.CYC & MemoryBus.STB;

    // ===========================
    // = Wishbone Bus Management =
    // ===========================
    logic InitCycle;
    logic BusSwitch;
    logic BusSwitchRegister;
    logic [7:0] RegisterReadBuffer;
    logic BusSwitchPendingBus; // if not register read, 0 = ROM 1 = RAM
    logic [4:0] OutstandingTransactions;
    // Must only assign to output when not sending a STALL signal.
    // Must receive any input appearing on a clock cycle when a STALL is NOT sent.
    // Stall if either bus is stalling, Initiator changed buses, or we can't count more pending ACKs
    assign MemoryBus.STALL = LoadImage.STALL | CartridgeRAM.STALL | BusSwitch | &OutstandingTransactions;

    always_ff @(posedge SysCon.CLK)
    begin
        var int DeltaOT;
        var int NewOT;
        DeltaOT = '0;
        NewOT = '0;
        if (!MemoryBus.CYC || SysCon.RST)
        begin
            LoadImage.CYC <= '0;
            CartridgeRAM.CYC <= '0;
            BusSwitch <= '0;
            InitCycle <= SysCon.RST;
        end else if (BusSwitch && !OutstandingTransactions) // STALL with no pending transactions
        begin
            // Register writes always complete immediately with no feedback except the ACK, so just
            // ACK those after completion.
            //
            // For a register read, buffer the response.
            //
            // When switching from LoadImage to CartridgeRAM, put the inputs onto the bus but don't
            // raise STB until no outstanding transactions.
            
            // If buffered register read, send ACK; if not, the data response is immaterial anyway.
            MemoryBus.ACK <= BusSwitchRegister;
            MemoryBus.ERR <= '0;
            MemoryBus.RTY <= '0;
            MemoryBus.DAT_ToInitiator <= RegisterReadBuffer;

            // When there's merely a buffered register, we just un-stall by clearing BusSwitch.
            // The mapper will receive the current data sitting on the bus in the next cycle; the
            // Initiator will see the stall end and will prepare data for the following cycle.
            
            // When changing between LoadImage and CartridgeRAM, the stall comes in the cycle AFTER
            // receiving the new read.  The read must be placed on the new bus, but CYC and STB
            // left low.
            //
            // When it's time to switch over, if it's not an intermediate register access switch,
            // swap the CYC signals and set STB to CYC.
            if (!BusSwitchRegister)
            begin
                LoadImage.CYC <= ~LoadImage.CYC;
                LoadImage.STB <= ~LoadImage.CYC;
                CartridgeRAM.CYC <= ~CartridgeRAM.CYC;
                CartridgeRAM.STB <= ~CartridgeRAM.CYC;
                DeltaOT += 1;
            end

            // Done here
            BusSwitch <= '0;
            BusSwitchRegister <= '0;
        end else if (!i_valid || MemoryBus.STALL)
        begin
            // Do nothing on stall or no valid input
        end else if (
                     (!MemoryBus.ADDR[15] && MemoryBus.WE) // Write to mapper registers
                     || (MemoryBus.ADDR[15:8] == 'hfe) // write to internal registers
                     || (TimerAccess && MemoryBus.ADDR[15:13] == 'b101) // RTC register access 
                    )
        begin
            // TODO:  Add RTC register stuff
            // Writing to registers is safe after having sent any prior commands, as the addresses
            // sent to LoadImage and CartridgeRAM are calculated based on the registers at STB
            BusSwitch <= |OutstandingTransactions;
            if (!OutstandingTransactions)
            begin
                MemoryBus.ACK <= '1;
                MemoryBus.ERR <= '0;
                MemoryBus.RTY <= '0;
                // Stick the timer data on there, the only register that's read this way
                //MemoryBus.DAT_ToInitiator <= ;
            end
            // ===================================
            // = Mapper internal register access =
            // ===================================
            // No-op outside InitCycle; reads always ignored
            if (InitCycle && (MemoryBus.ADDR[15:8] == 'hfe) && MemoryBus.WE)
            begin
                // Sets up the registers.  Writing non-zero to $FE50 locks these until reset
                if (MemoryBus.ADDR[7:4] == 'ha)
                case (MemoryBus.ADDR[3:0])
                    'h0:
                        MapperType <= MemoryBus.DAT_ToTarget[5:0];
                    'h1:
                        ROMSize <= MemoryBus.DAT_ToTarget;
                    'h2:
                        RAMSize <= MemoryBus.DAT_ToTarget;
                    'h3:
                        ROMBankMask[7:0] <= MemoryBus.DAT_ToTarget;
                    'h4:
                        ROMBankMask[8] <= MemoryBus.DAT_ToTarget[0];
                    'h5:
                        RAMBankMask <= MemoryBus.DAT_ToTarget[3:0];
                    'h6:
                        CartFeatures <= MemoryBus.DAT_ToTarget[4:0];
                endcase
                else if (MemoryBus.ADDR[7:0] == 'h50) // Final step in boot rom, lock registers
                    InitCycle <= !MemoryBus.DAT_ToTarget;
            end
            // ==========================
            // = Mapper register access =
            // ==========================
            if (!MemoryBus.ADDR[15]) // Below $8000
            begin
                // Writes to mapper registers must control the stored register values so the simple read
                // logic doesn't get bad input.
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
                        if (!MapperType[MBC5] || !MemoryBus.ADDR[12]) // <= 'h2fff for MBC5
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
                    end
                    3'b101: // 'ha000..'hbfff, RAM and timer
                    begin
                        if (TimerAccess)
                        begin
                        end
                    end
                endcase // Mappers MBC1 to MBC5
                // MBC6:  Net de Get Minigame @ 100, no other games, and not useful
                // MBC7:  Kirby Tilt 'n Tumble, Command Master
                // MMM01:  Taito variety pack
                // TAMA5:  Tamogaci
                // HuC1:  a few games
            end // ROM-space Mapper registers (<$8000)
        end // Register access
        // =================
        // = ROM bank read =
        // =================
        else if (!MemoryBus.ADDR[15]) // & 'h8000)) // Read from mapped ROM
        begin
            BusSwitch <= CartridgeRAM.CYC;
            BusSwitchRegister <= '0;
            if (!CartridgeRAM.CYC)
            begin
                LoadImage.CYC <= '1;
                LoadImage.STB <= '1;
                // If OT is ~0 we're stalled anyway
                DeltaOT += 1;
            end
            LoadImage.ADDR <=
            {
                // First or second bank?
                MemoryBus.ADDR[14] ? UpperROMBank : LowerROMBank,
                MemoryBus.ADDR[13:0]
            };
        end // ROM bank read
        // =================
        // = ROM bank read =
        // =================
        else if (MemoryBus.ADDR[15:13] == 'b101) // Read from mapped RAM
        begin
            BusSwitch <= LoadImage.CYC;
            BusSwitchRegister <= '0;
            if (!LoadImage.CYC)
            begin
                CartridgeRAM.CYC <= '1;
                CartridgeRAM.STB <= '1;
                DeltaOT += 1;
            end
            CartridgeRAM.ADDR <= CRAddress;
            CartridgeRAM.WE <= MemoryBus.WE;
        end // RAM bank read
        // Manage OutstandingTransactions:
        //   - Increment if sending a transaction (if either bus CYC&STB)
        //   - Decrement if receiving a transaction (if either bus ACK|ERR|RTY)
        //   - If outstanding transactions are 0 and there is no CYC&STB, close both buses.
        DeltaOT -= (LoadImage.ACK|LoadImage.ERR|LoadImage.RTY) & LoadImage.CYC;
        DeltaOT -= (CartridgeRAM.ACK|CartridgeRAM.ERR|CartridgeRAM.RTY) & CartridgeRAM.CYC; 
        NewOT = OutstandingTransactions + DeltaOT;
        OutstandingTransactions <= NewOT;
        // This only hits zero if we're not deploying a new transaction next cycle and all
        // responses have been received.  As such, close all buses.
        //
        // It only occurs when there aren't outstanding transactions already because NewOT will
        // become non-zero on the cycle of a bus switch, and if a bus switch is pending we want
        // to let them switch instead of closing out.
        if (!NewOT && !OutstandingTransactions)
        begin
            LoadImage.CYC <= '0;
            CartridgeRAM.CYC <= '0;
        end
    end

    // $0000-$00FF should be the 256-byte boot rom
    // $0143:  CGB flag ($80 CGB and DMG, $C0 CGB only)
    // $0146:  SGB flag ($00 CGB only, $03 SGB functions)

    // =======================
    // = ROM bank Addressing =
    // =======================
    // Setting the ROM bank address bits combinationally simplifies the access code.
    
    // Never write to ROM
    assign LoadImage.WE = '0;
    //assign LoadImage.DAT_ToTarget = '0;
    //assign LoadImage.SEL = '0;

    // This translates incoming addresses to the correct address in LoadImage and CartridgeRAM
    assign LIAddress[13:0] = MemoryBus.ADDR[13:0];
    assign LIAddress[22:14] = MemoryBus.ADDR[14] ? UpperROMBank : LowerROMBank;
    always_comb
    begin
        if (MapperType[MBC1] || MapperType[MBC2] || MapperType[MBC3] || MapperType[MBC5])
        begin
            // Can't be 0
            UpperROMBank[0] = ROMBankID[0] &
                              (
                                ROMBankID[4:1] // MBC1
                                || (
                                    MapperType[MBC5]
                                    || (MapperType[MBC3] && ROMBankID[6:5])
                                   )
                              );
            UpperROMBank[4:1] = (ROMBankID[4:1] & ROMBankMask[4:1]);
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
    // FIXME:  REWRITE THE BELOW
    // ===================
    // = RAM bank access =
    // ===================
    // MBC3 has a real-time clock mappable into its RAM bank.
    // As with the ROM bank, just do good house keeping when setting registers.
    // FIXME:  Rework this, it's very broken 
    assign TimerAccess = HasTimer && RAMBankID[3] && MemoryBus.STB && RAMEnabled;
    //assign CartridgeRAM.Access = MemoryBus.ADDR && (MemoryBus.ADDR[15:13] == 'b101)
    //                             && RAMEnabled && !TimerAccess;
    assign CartridgeRAM.WE  = MemoryBus.WE && CartridgeRAM.STB;
    assign CartridgeRAM.DAT_ToTarget = MemoryBus.DAT_ToTarget; // Is this ever not true?
    assign CartridgeRAM.ADDR[12:0] = MemoryBus.ADDR[12:0];
    assign CartridgeRAM.SEL = '1;

    always_comb
    if (
        i_valid &&
        // MemoryBus.Address >= 'ha000 && MemoryBus.Address < 'hc000
        MemoryBus.ADDR[15:13] == 'b101 // Cartridge RAM range
       )
    begin
        if (MapperType >= ROM && MapperType <= MBC5)
        begin
            // MBC1 doesn't bank RAM if banking mode is 0, RAM is small, or ROM is large.
            if (MapperType == MBC1 && (BankingMode == '0 || RAMSize < 'h2 || ('h8 >= ROMSize && ROMSize >= 'h5)))
                CartridgeRAM.ADDR[16:13] = MemoryBus.ADDR[12:0];
            else
                CartridgeRAM.ADDR[16:13] = RAMBankID[3:0];
        end
    end
    else
        CartridgeRAM.ADDR[16:13] = '0;

    // Set the timer registers on clock tick
    // FIXME:  Need to latch the registers when appropriate
    // FIXME:  When setting the clock, store the offset from the real RTC
    always_ff @(posedge Clk)
    if (TimerAccess && MemoryBus.WE && MemoryBus.ADDR[15:13] == 'b101) // Cartridge RAM range
    begin
        // Write to the timer registers
        RTCRegisters[RAMBankID[2:0]] <= MemoryBus.DAT_ToInitiator;
    end
    
    /*  FIXME:  Broken
    // Set the bus to access
    // Only ROM and CRAM area are valid
    always_comb
    //if (MemoryBus.Access && !MemoryBus.Write && MemoryBus.Address[15] == '0) //< 'h8000)
    if (!(MemoryBus.Address & 'h8000)) // ROM
    begin
        MemoryBus.DAT_ToInitiator = LoadImage.DAT_ToInitiator;
    end else // if (MemoryBus.Address[15:13] == 'b101) // Cartridge RAM range
    begin
        if (TimerAccess)
            MemoryBus.DToInitiator = RTCRegisters[RAMBankID[2:0]];
        else
            MemoryBus.DToInitiator = RAMEnabled ? CartridgeRAM.DToInitiator : '0;
    end
    */
endmodule