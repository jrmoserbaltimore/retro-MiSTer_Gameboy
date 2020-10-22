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
module RetroCoreShim
#(
    parameter DeviceType = "Xilinx",
    parameter CoreClock = 200000000 // 200MHz FPGA core clock
)
(
    // The console sends a core system clock (e.g. 200MHz) to produce the reference clock.
    IWishbone.SysCon SysCon, // Core system clock

    // DDR System RAM or other large RAM.

    IWishbone.Initiator MainRAM,
    // DDR, HyperRAM, or SRAM on the expansion bus
    IWishbone.Initiator ExpansionRAM0,
    IWishbone.Initiator ExpansionRAM1,
    IWishbone.Initiator ExpansionRAM2,

    output logic [23:0] Video,
    output logic [23:0] Audio, // 96kHz 24-bit, downsample to 48kHz 16-bit
    // ================
    // = External Bus =
    // ================

    // Cartridge bus wide enough for NES, 69 I/O
    output logic CartridgeClk,
//    input logic [68:0] CartridgeIn,
//    output logic [68:0] CartridgeOut,

    // Controller I/O, from µC
    input logic ControllerIn,
    output logic ControllerOut,

    // Expansion
    input logic [31:0] ExpansionPortIn,
    output logic [31:0] ExpansionPortOut,

    // Console
    IWishbone.Target Host
);

    wire Delay;
    wire Reset;
    wire Ce;
    
    wire Read, Write;
    wire [15:0] Address;
    wire [7:0] DataIn, DataOut;
    wire AudioIn;
    wire CS, Ready, DataReady;

    wire CartDelay;
    wire MainRAMDelay;
    wire VRAMDelay;
    
    // The cartridge controller needs to always provide both Ready and DataReady unless waiting
    // for operations.  These may frequently fall between clock ticks.  When using a hardware
    // cartridge, both of these should be kept on.
    assign Delay = ~(Ready & DataReady);

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

    (* dont_touch = "true" *)
    WishboneBRAM
    #(
        .AddressWidth(15),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBSystemRAM
    (
        .SysCon(IGBSystemRAM),
        .Initiator(IGBSystemRAM)
    );

    IWishbone
    #(
        .AddressWidth(14),
        .DataWidth(8) 
    ) IGBVideoRAM();

    (* dont_touch = "true" *)
    WishboneBRAM
    #(
        .AddressWidth(14),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBVideoRAM
    (
        .SysCon(IGBVideoRAM),
        .Initiator(IGBVideoRAM)
    );
    
    IWishbone
    #(
        .AddressWidth(17),
        .DataWidth(8) 
    ) IGBCartridgeRAM();

    (* dont_touch = "true" *)
    WishboneBRAM
    #(
        .AddressWidth(17),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) GBCartridgeRAM
    (
        .SysCon(IGBCartridgeRAM),
        .Initiator(IGBCartridgeRAM)
    );
    // TODO:  Chunk of BRAM for cartridge cache
    // TODO:  Chunk of BRAM for mappers

    // ========
    // = CATC =
    // ========
    // Cartridge controller triggers Delay if data isn't ready
    /*
    RetroCATC CATC(
        .Clk(CoreClk),
        .Delay(Delay),
        .ClkEn(ClkEn),
        .Reset(Reset),
        .ClkEnOut(Ce)
    );
    */

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

    // ========================
    // = Interface to GamePak =
    // ========================

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
    IRTC();
    // FIXME:  Hastily-assembled stuff to get this to actually synthesize
    
    IWishbone
    #(
        .AddressWidth(23),
        .DataWidth(8) 
    ) ILoadImage();

    (* dont_touch = "true" *)
    WishboneBRAM
    #(
        .AddressWidth(23),
        .DataWidth(8),
        .DeviceType(DeviceType)
    ) LoadImage
    (
        .SysCon(ILoadImage),
        .Initiator(ILoadImage)
    );
    
    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    IMapper();

    //(* dont_touch = "true" *)
    GBCMapper Mapper
    (
        .SysCon(IMapper),
        .LoadImage(ILoadImage),
        .CartridgeRAM(IGBCartridgeRAM),
        .RTC(IRTC), // XXX:  Placeholder
        .MemoryBus(IMapper)
    );

    //(* dont_touch = "true" *)
    GBCMemoryBus SystemBus
    (
        .SysCon(ISystemBus),
        // System and video BRAMs
        .SystemRAM(IGBSystemRAM),
        .VideoRAM(IGBVideoRAM),
        .VideoStatus(3'b000),
        .Cartridge(IMapper),
        .MemoryBus(Host) // Placeholder 
    );

    /*
    assign ISystemBus.DAT_ToTarget = Host.DAT_ToTarget;
    assign ISystemBus.CYC = Host.CYC;
    assign ISystemBus.STB = Host.STB;
    assign ISystemBus.ADDR = Host.ADDR;
    assign ISystemBus.WE = Host.WE;
    assign ISystemBus.SEL = Host.SEL;
    assign Host.ACK = ISystemBus.ACK;
    assign Host.ForceStall = ISystemBus.STALL;
    assign Host.DAT_ToInitiator = ISystemBus.DAT_ToInitiator;
    */
    assign IMapper.CLK = SysCon.CLK;
    assign ILoadImage.CLK = SysCon.CLK;
    assign IGBCartridgeRAM.CLK = SysCon.CLK;
    assign IGBSystemRAM.CLK = SysCon.CLK;
    assign IGBVideoRAM.CLK = SysCon.CLK;
    assign ISystemBus.CLK = SysCon.CLK;

    assign IMapper.RST = SysCon.RST;
    assign ILoadImage.RST = SysCon.RST;
    assign IGBCartridgeRAM.RST = SysCon.RST;
    assign IGBSystemRAM.RST = SysCon.RST;
    assign IGBVideoRAM.RST = SysCon.RST;
    assign ISystemBus.RST = SysCon.RST;

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