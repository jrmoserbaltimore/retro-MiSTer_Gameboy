// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Game Boy Color Shim.  The shim sets up for an actual core, creating RAM objects, mapping the
// expansion port (e.g. to a cartridge), exposing the controller properly to the core, managing
// CATC, handling cache, and so forth.

// This is the core shim.  RetroConosle connects everything to this, which then connects to the
// core module.  In here we set up various types of RAM, clock control, the cartridge controller,
// and any peripherals.
//
// Detecting DMG, CGB, GBA:
//   - DMG:  CPU A register == 0x01 (also SGB)
//   - MGB:  CPU A register == 0xff (Gameboy Pocket, SGB2)
//   - CGB:  CPU A register == 0x11, B[0] == 0
//   - GBA:  CPU A register == 0x11, B[0] == 1
//
// Host controls:
//  - Pause (disables CE)
//  - Reset (propagates through Game Boy SysCon)
//  - Load boot ROM
//  - Read WRAM
//  - Write WRAM (for enhanced boot ROM)
//  - Read VRAM
//  - Write VRAM
//  - Read Cartridge RAM (for saving)
//  - Write Cartridge RAM (for loading)
//  - Address bus read
//  - Address bus write
//  - Read registers (Save state)
//  - Write registers (Load state)

module RetroCoreShim
#(
    parameter DeviceType = "Xilinx",
    parameter CoreClock = 200000000 // 200MHz FPGA core clock
)
(
    // The console sends a core system clock (e.g. 200MHz) to produce the reference clock.
    ISysCon SysCon, // Core system clock is exactly 2^23 Hz

    // DDR System RAM or other large RAM.

    IWishbone.Initiator MainRAM,
    // DDR, HyperRAM, or SRAM on the expansion bus
    IWishbone.Initiator ExpansionRAM0,
    //IWishbone.Initiator ExpansionRAM1,
    //IWishbone.Initiator ExpansionRAM2,

    IWishbone.Initiator VideoOut,
    IWishbone.Initiator AudioOut, // 96kHz 24-bit, downsample to 48kHz 16-bit
    // ================
    // = External Bus =
    // ================

    // Cartridge bus wide enough for NES, 69 I/O
    output logic CartridgeClk,
//    input logic [68:0] CartridgeIn,
//    output logic [68:0] CartridgeOut,

    // Expansion
    input logic [31:1] ExpansionPortIn,
    output logic [31:1] ExpansionPortOut,

    // Console
    IWishbone.Target Host
);

    logic IsPaused;
    logic Ce;
    logic GB2x; // placeholder
    logic [6:1] Interrupt; // Placeholder

    logic GBReset;

    wire [1:0] JoypadID;
    wire [7:0] Keys;
    
    wire Read, Write;
    wire [15:0] Address;
    wire [7:0] DataIn, DataOut;
    wire AudioIn;
    wire CS, Ready, DataReady;

    // The cartridge controller needs to always provide both Ready and DataReady unless waiting
    // for operations.  These may frequently fall between clock ticks.  When using a hardware
    // cartridge, both of these should be kept on.
    //assign Delay = ~(Ready & DataReady);

    ISysCon GBSysCon();
    assign GBSysCon.CLK = SysCon.CLK;
    assign GBSysCon.RST = SysCon.RST | GBReset;

    // ================
    // = Video Device =
    // ================
    
    wire [2:0] VideoStatus;

    IWishbone
    #(
        .AddressWidth(14),
        .DataWidth(8) 
    ) IGBVideoRAM();

    WishboneBRAM
    #(
        .AddressWidth(14),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBVideoRAM
    (
        .SysCon(SysCon),
        .Initiator(IGBVideoRAM.Target)
    );

    IWishbone
    #(
        .AddressWidth(14),
        .DataWidth(8),
        .TGAWidth(2),
        .TGDWidth(1) 
    ) IGBVideoPU();
    
    GBCVideoPU VideoPU
    (
        .SysCon(SysCon),
        .ClkEn(Ce),
        .VideoRAM(IGBVideoRAM),
        .VideoOut(VideoOut),
        .VideoStatus(VideoStatus),
        .SystemBus(IGBVideoPU.Target)
    );

    // ===============
    // = I/O Devices =
    // ===============
    
    logic SerialClkIn;
    logic SerialClkOut;
    logic SerialIn;
    logic SerialOut;
    logic IRIn;
    logic IROut;
 
    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    IRTC();
    // FIXME:  Get an actual RTC object

    IWishbone
    #(
        .AddressWidth(8),
        .DataWidth(8) 
    ) IIOSystem();

    GBCIOSystem IOBus
    (
        .SysCon(SysCon),
        .Ce(Ce),
        .GB2x(GB2x),
        .JoypadID(JoypadID),
        .Keys(Keys),
        .SerialClkIn(SerialClkIn),
        .SerialClkOut(SerialClkOut),
        .SerialIn(SerialIn),
        .SerialOut(SerialOut),
        .IRIn(IRIn),
        .IROut(IROut),
        .IOBus(AudioOut),
        .Interrupt(Interrupt[4:2]),
        .SystemBus(IIOSystem.Target)
    );
    // =================================
    // = Interface to hardware GamePak =
    // =================================
    /*
    IGBCGamePak GamePak(
        .Clk(CartridgeClk),
        .Write(CartridgeOut[2]),
        .Read(CartridgeOut[3]),
        .CS(CartridgeOut[4]),
        .Address(CartridgeOut[20:5]),
        .DFromPak(CartridgeIn[28:21]),
        .DToPak(CartridgeOut[28:21]),
        .Reset(CartridgeOut[29]),
        .Audio(CartridgeIn[30])
    );
    */

    // =======================
    // = Interface to Mapper =
    // =======================
    
    IWishbone
    #(
        .AddressWidth(17),
        .DataWidth(8) 
    ) IGBCartridgeRAM();

    WishboneBRAM
    #(
        .AddressWidth(17),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBCartridgeRAM
    (
        .SysCon(SysCon),
        .Initiator(IGBCartridgeRAM.Target)
    );

    IWishbone
    #(
        .AddressWidth(23),
        .DataWidth(8) 
    ) ILoadImage();

    // FIXME:  Need to instantiate a cache here, not an 8MB BRAM
    /*
    WishboneCache
    #(
        .AddressWidth(23),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) LoadImage
    (
        .SysCon(SysCon),
        .Initiator(ILoadImage.Target)
    );
    */

    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    IMapper();

    GBCMapper Mapper
    (
        .SysCon(SysCon),
        //.LoadImage(ILoadImage.Initiator),
        .LoadImage(ExpansionRAM0),
        .CartridgeRAM(IGBCartridgeRAM.Initiator),
        .RTC(IRTC.Initiator), // XXX:  Placeholder
        .MemoryBus(IMapper.Target)
    );

    // ======================
    // = System RAM Objects =
    // ======================
    // We create BRAMs in the shim so a different shim can use the GBC Cartridge Controller without
    // dedicating the BRAM exclusively to the GBC when not running.
    IWishbone
    #(
        .AddressWidth(15),
        .DataWidth(8) 
    ) IGBSystemRAM();

    WishboneBRAM
    #(
        .AddressWidth(15),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBSystemRAM
    (
        .SysCon(SysCon),
        .Initiator(IGBSystemRAM.Target)
    );

    // ==============
    // = System Bus =
    // ==============

    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    ISystemBus();
    
    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    ISystemBusSkid();

    WishboneSkidBuffer
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    SystemBusSkid
    (
        .SysCon(SysCon),
        .Initiator(ISystemBus.Target),
        .Target(ISystemBusSkid.Initiator)
    );
    // ========
    // = CATC =
    // ========
    // When stalling during a tick, CATC buffers the tick

    RetroCATC
    #(
        .ReferenceClock(2**23)
    ) CATC
    (
        .SysCon(SysCon),
        .Stall(ISystemBus.Stalled()),
        .ClkEn(!IsPaused),
        .ClkEnOut(Ce)
    );
    
    GBCMemoryBus SystemBus
    (
        .SysCon(SysCon),
        // System and video BRAMs
        .SystemRAM(IGBSystemRAM.Initiator),
        .VideoRAM(IGBVideoPU.Initiator),
        .VideoStatus(VideoStatus),
        .IOSystem(IIOSystem.Initiator),
        .Cartridge(IMapper.Initiator), // FIXME: Find a way to swap out to cartridge
        .MemoryBus(ISystemBusSkid.Target) // Skid buffer 
    );

    // XXX:  Hack to make it synthesize for testing and LUT count.
    logic irq; // FIXME:  Hook up to IRQ
    logic m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [7:0] cpu_di, cpu_do;
    wire [15:0] cpu_addr;
    assign ISystemBus.CYC = 1'b1;
    assign ISystemBus.STB = !rd_n||!wr_n||!mreq_n; // read/write/request?  is !mreq_n just stb? 
    assign ISystemBus.ADDR = cpu_addr;
    assign ISystemBus.DAT_ToTarget = cpu_do;
    assign ISystemBus.WE = !wr_n;
    assign cpu_di = ISystemBus.DAT_ToInitiator;

    // =======
    // = CPU =
    // =======

    tv80s CPU
    (
        .reset_n(!SysCon.RST),
        .clk(SysCon.CLK),
        .cen(Ce),
        // XXX:  is this sufficient?  Wait until receiving an ack?
        .wait_n(!ISystemBus.ACK),
        .int_n(!irq),
        .nmi_n(1'b1), // No NMI
        .busrq_n(1'b1), // no bus requests
        // Outputs
        .m1_n(m1_n),
        .mreq_n(mreq_n),
        .iorq_n(iorq_n),
        .rd_n(rd_n),
        .wr_n(wr_n),
        .rfsh_n(rfsh_n),
        .halt_n(halt_n),
        .busak_n(busak_n),
        .A(cpu_addr),
        .di(cpu_di),
        .dout(cpu_do)
        // stop:  stop (output)
    );
    
    logic [15:0] addrct;
    
    always_ff @(posedge SysCon.CLK)
    begin
        if (SysCon.RST)
        begin
            Host.Unstall();
        end
    end
    /*
    RetroMyCore TheCore
    (
        .Clk(CoreClk),
        .ClkEn(Ce),
        .AV(AV),
        .MemoryBus(GamePakFrontend.Initiator),
        .GamePak(GamePakBus.Gameboy),
        // TODO:  Serial controller
        // etc.
        .SerialOut(0),
        .SerialIn(0),
        .SD(0),
        .SerialClk(0)
    );
    */
endmodule