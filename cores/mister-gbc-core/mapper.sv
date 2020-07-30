// vim: sw=4 ts=4 et
// Every Game Boy Color mapper implemented at once.
//
// Save RAM is interesting:  CartridgeRAM writes go to a cache, which writes back every several
// hundred cycles or on eviction.  This writeback triggers a message indicating what RAM has
// changed.  The host then can copy RAM into a save RAM file or a PITR history.  
//
// FIXME:  Set up method to indicate game has battery-backed RAM and of what size.
// FIXME:  HuC1 might be worth implementing
module GBCMapper
(
    input logic Clk,
    input logic ClkEn,
    // Pass caching modules for both of these.  CartridgeRAM can cache from DDR etc. (paging)
    // LoadImage and SystemRAM will incur delays fixed by CATC. 
    IRetroMemoryPort.Initiator LoadImage,
    IRetroMemoryPort.Initiator CartridgeRAM,

    // Export the memory bus back to the controller
    IRetroMemoryPort.Target MemoryBus
);
    enum integer
    {
        ROM=1,
        MBC1=2,
        MBC2=3,
        MBC3=4,
        MBC5=5,
        MBC6=6,
        MBC7=7,
        MMM01=8,
        Camera=9,
        TAMA5=10,
        HuC3=11,
        HuC1=12
    } MapperTypes;

    
    // The header indicates how many ROM and RAM banks the cartridge has, which also determines
    // mapper behavior.
    logic [8:0] ROMBankID; // Up to 512 16K banks
    logic [3:0] RAMBankID; // Up to 16 Cartridge RAM banks, or MBC3 RTC register indexes
    
    // ROM size packed to 4 bits ('b0101 is the only upper nibble, so just truncate)
    logic [3:0] ROMSize;
    logic [3:0] RAMSize; 
    
    logic BankingMode = '0; // MBC1 $6000-$7FFF
    
    logic [8:0] ROMBankMask = '0;

    logic [4:0][7:0] RTCRegisters;
    logic RTCLatched = '0;

    logic [5:0] CartridgeType; // Skip bits 7-6
    logic [3:0] MapperType;
    logic HasRam;
    logic HasBattery;
    logic HasTimer;
    logic HasRumble;
    logic HasSensor;
    uwire TimerAccess;
    
    logic RAMEnabled = '0;
    //logic TimerEnabled = '0;
    logic FlashEnabled = '0;
    logic FlashWriteEnabled = '0;

    // $0000-$00FF should be the 256-byte boot rom
    // $0143:  CGB flag ($80 CGB and DMG, $C0 CGB only)
    // $0146:  SGB flag ($00 CGB only, $03 SGB functions)
    // $0147:  Mapper type
    // $0148:  ROM size (layout)
    
    // ========================================================
    // = Determine mapper, ram, battery, and other attributes =
    // ========================================================
    // These are combinational but may take longer than a tick. Inputs only change when loading a
    // new load image, so the initialization process needs to delay long enough after changing
    // CartridgeType.
    always_comb
    begin
        case (CartridgeType)
            'h00,
            'h08,
            'h09:
                MapperType <= ROM;
            'h01,
            'h02,
            'h03:
                MapperType <= MBC1;
            'h05,
            'h06:
                MapperType <= MBC2;
            'h0b,
            'h0c,
            'h0d:
                MapperType <= MMM01;
            'h0f,
            'h10:
                begin
                    HasTimer <= '1;
                    MapperType <= MBC3;
                end
            'h11,
            'h12,
            'h13:
                begin
                    HasTimer <= '0;
                    MapperType <= MBC3;
                end
            'h19,
            'h1a,
            'h1b:
                begin
                    HasRumble <= '1;
                    MapperType <= MBC5;
                end
            'h1c,
            'h1d,
            'h1e:
                begin
                    HasRumble <= '0;
                    MapperType <= MBC5;
                end
            'h20:
                MapperType <= MBC6;
            'h22:
                begin
                    HasSensor <= 0;
                    MapperType <= MBC7;
                end
            'h3c: // 'hfc without the top 2 bits
                MapperType <= Camera;
            'h3d:
                MapperType <= TAMA5;
            'h3e:
                MapperType <= HuC3;
            'h3f:
                MapperType <= HuC1;
            default:
                // We don't care about sensor, rumble, or timer here
                MapperType <= '0;
        endcase
    end
    
    always_comb
    begin
        case (CartridgeType)
            'h02,
            'h08,
            'h0c,
            'h12,
            'h1a,
            'h1d:
                begin
                    HasRam <= '1;
                    HasBattery <= '0;
                end
            'h06,
            'h0f:
                begin
                    HasRam <= '0;
                    HasBattery <= '1;
                end
            'h03,
            'h09,
            'h0d,
            'h10,
            'h13,
            'h1b,
            'h1e,
            'h22,
            'h3f: // 'hff without the top 2 bits
                begin
                    HasRam <= '1;
                    HasBattery <= '1;
                end
            default:
                begin
                    HasRam <= '0;
                    HasBattery <= '0;
                end
        endcase
    end

    // =================
    // = ROM bank read =
    // =================
    
    // Never write to ROM
    assign LoadImage.Write = '0;

    always_comb
    begin
        // Set the ROM bank mask using the count of 16KiB ROM banks.
        if (ROMSize[3:2] == 'b11) // The special 11xx = '52h '53h '54h between 64 and 128 banks
            ROMBankMask = 128 - 1;
        else
            ROMBankMask = (2 << ROMSize) - 1;
    end

    // This continuously sets the address at which to access LoadImage, but doesn't necessarily
    // access it.
    always_comb
    begin
    if (MapperType >= ROM && MapperType <= MBC5)
        begin
            LoadImage.Address[13:0] = MemoryBus.Address[13:0];
            if (MemoryBus.Address[15:14] == 'b00) //< 'h4000)
            begin
                LoadImage.Address[18:14] = '0;
                // MBC1 can remap bank 0 in advanced banking on large ROMs; it uses the RAM bank ID
                // XXX:  This doesn't work with MBC1m (multi-cart), which map the RAM bank bits to
                // bits 4-5 instead of 5-6
                LoadImage.Address[20:19] = (
                                            MapperType == MBC1 &&
                                            'h8 >= ROMSize && ROMSize >= 'h5 &&
                                            BankingMode == '1
                                           )
                                           ? RAMBankID[1:0] // MBC1 weird mode-1 stuff
                                           : '0; // non-MBC1
                LoadImage.Address[22:21] = '0; // Blank
            end
            else
            begin
                // Upper ROM bank
                if (MapperType == MBC1)
                begin
                    // XXX:  Again:  does not work with MBC1m
                    LoadImage.Address[18:14] = (ROMBankID[4:0] == '0) ? '1 : ROMBankID[4:0];
                    LoadImage.Address[20:19] = ('h8 >= ROMSize && ROMSize >= 'h5)
                                               ? RAMBankID[1:0]
                                               : '0;
                    LoadImage.Address[22:21] = '0;
                end
                else
                begin
                LoadImage.Address[22:14] = (ROMBankID[3:0] == '0 && MapperType == MBC2)
                        ? '1
                        : ROMBankID[8:0];
                end
            end
        end
        // Mappers beyond MBC5 are highly specialized and not supported.
        // MBC6 is only one game; MBC7 has accelerometers.
        // HuC1 used IR COMM, Pokemon TCG used this
    end
    
    // ===================
    // = RAM bank access =
    // ===================
    // MBC3 has a real-time clock mappable into its RAM bank.
    // As with the ROM bank, just do good house keeping when setting registers.
    
    assign TimerAccess = HasTimer && RAMBankID[3];
    assign CartridgeRAM.Access = MemoryBus.Access && (MemoryBus.Address[15:13] == 'b101)
                                 && RAMEnabled && !TimerAccess;
    assign CartridgeRAM.Write  = MemoryBus.Write && CartridgeRAM.Access;
    assign CartridgeRAM.Dout = MemoryBus.Din; // Is this ever not true?
    assign CartridgeRAM.Address[12:0] = MemoryBus.Address[12:0];
    
    always_comb
    // 5 inputs to minimize resource usage
    if (
        //ClkEn &&
        !TimerAccess &&
        MemoryBus.Access &&
        // MemoryBus.Address >= 'ha000 && MemoryBus.Address < 'hc000
        MemoryBus.Address[15:13] == 'b101 // Cartridge RAM range
       )
    begin
        if (MapperType >= ROM && MapperType <= MBC5)
        begin
            LoadImage.Access = '0;
            LoadImage.Write = '0;

            // MBC1 doesn't bank RAM if banking mode is 0, RAM is small, or ROM is large.
            if (MapperType == MBC1 && (BankingMode == '0 || RAMSize < 'h2 || ('h8 >= ROMSize && ROMSize >= 'h5)))
                CartridgeRAM.Address[16:13] = 4'b0;
            else
                CartridgeRAM.Address[16:13] = RAMBankID[3:0];
        end
        if (TimerAccess)
            MemoryBus.Dout = RTCRegisters[RAMBankID[2:0]];
        else
            MemoryBus.Dout = RAMEnabled ? CartridgeRAM.Din : '0;
    end

    // Set the timer registers on clock tick
    // FIXME:  Need to latch the registers when appropriate
    // FIXME:  When setting the clock, store the offset from the real RTC
    always_ff @(posedge Clk)
    if (ClkEn && TimerAccess && MemoryBus.Access && MemoryBus.Address[15:13] == 'b101) // Cartridge RAM range
    begin
        if (RAMEnabled)
        begin
            // Write to the registers
            if (MemoryBus.Write)
                RTCRegisters[RAMBankID[2:0]] <= MemoryBus.Din;
            //else
            //    MemoryBus.Dout <= RTCRegisters[RAMBankID[2:0]];
        end
    end
    
    // Set the bus to access
    // Only ROM and CRAM area are valid
    always_comb
    //if (MemoryBus.Access && !MemoryBus.Write && MemoryBus.Address[15] == '0) //< 'h8000)
    if (MemoryBus.Address[15] == '0) //< 'h8000) // ROM
    begin
        MemoryBus.Dout = LoadImage.Dout;
    end else //if (MemoryBus.Address[15:13] == 'b101) // Cartridge RAM range
    begin
        MemoryBus.Dout = CartridgeRAM.Din;
    end

    // ==========================
    // = Mapper register access =
    // ==========================

    always_ff @(posedge Clk)
    if (ClkEn && MemoryBus.Access && MemoryBus.Write && MemoryBus.Address < 'h8000)
    begin
        // Writes to mapper registers must control the stored register values so the simple read
        // logic doesn't get bad input.
        if (MapperType == ROM)
        begin
            // This space intentionally left blank
        end
        else if (MapperType >= MBC1 && MapperType <= MBC5)
        begin
            // Type MBC1-MBC5 are fairly similar, and the same logic can make a number of decisions
            // about which action to take for which mapper.  These mappers support different sizes
            // of ROM and RAM.
            if (
                'h1fff >= MemoryBus.Address && MemoryBus.Address >= 'h0000
                && !(MapperType == MBC2 && !MemoryBus.Address[8]) // MBC2 is special
               )
            begin
                //$0000-$1FFF   RAM enable              MBC1, MBC2, MBC3, MBC5
                //              Timer enable            MBC3
                RAMEnabled <= (MemoryBus.Din[3:0] == 'ha);
            end
            else if ('h3fff >= MemoryBus.Address && MemoryBus.Address >= 'h2000)
            begin
                //$2000-$3FFF   ROM Bank number         MBC1, MBC2, MBC3
                //$2000-$2FFF   ROM Bank low bits       MBC5
                //$3000-$3FFF   ROM Bank high bits      MBC5
                if (MapperType != MBC5 || MemoryBus.Address <= 'h2fff)
                begin
                    // MBC1 and MBC3 force '0 to '1
                    ROMBankID[7:0] <= (MemoryBus.Din[7:0] == '0 && MapperType != MBC5) ?
                        '1 : MemoryBus.Din & ROMBankMask[7:0];
                end
                else if (MapperType == MBC5)
                begin
                    ROMBankID <= {MemoryBus.Din[0] & ROMBankMask[8], ROMBankID[7:0]};
                end
            end
            else if (MemoryBus.Address >= 'h4000 && MemoryBus.Address <= 'h5fff)
            begin
                //$4000-$5FFF   RAM bank number         MBC1, MBC3, MBC5
                //              ROM bank high bits      MBC1 (1Mb+ carts)
                //              RTC Register select     MBC3 (higher values)
                // MBC1 behavior is based on RAM and ROM size
                // MBC3 and MBC5 behave normally
                RAMBankID <= MemoryBus.Din[3:0];
            end
            else if (MemoryBus.Address >= 'h6000 && MemoryBus.Address <= 'h7fff)
            begin
                //$6000-$7FFF   Banking mode select     MBC1
                //              Latch clock data        MBC3
                if (MapperType == MBC1)
                    BankingMode <= MemoryBus.Din[0];
                else if (MapperType == MBC3)
                begin
                    // TODO:  Fetch RTC data
                    RTCLatched <= MemoryBus.Din[0];
                end
            end
        end
        else //if (MapperType == MBC6) // Unsupported
        begin
            //$0000-$03FF   RAM enable              MBC6
            //$0400-$07FF   RAM Bank A select       MBC6
            //$0800-$0BFF   RAM Bank B select       MBC6
            //$0C00-$0FFF   Flash enable            MBC6
            //$1000         Flash write enable      MBC6
            //$2000-$27FF   ROM/Flash bank A        MBC6
            //$2800-$2FFF   ROM/Flash bank A select MBC6
            //$3000-$37FF   ROM/Flash bank B        MBC6
            //$3800-$3FFF   ROM/Flash bank B select MBC6
        end
    end
endmodule