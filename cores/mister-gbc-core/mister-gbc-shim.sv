// vim: sw=4 ts=4 et
// Game Boy Color Shim.  The shim sets up for an actual core, creating RAM objects, mapping the
// expansion port (e.g. to a cartridge), exposing the controller properly to the core, managing
// CATC, handling cache, and so forth.

// This is the core shim.  RetroConosle connects everything to this, which then connects to the
// core module.  In here we set up various types of RAM, clock control, the cartridge controller,
// and any peripherals.
module RetroCoreShim
#(
    parameter string DeviceType = "Xilinx"
)
(
    // The console sends a core system clock (e.g. 200MHz) and a clock-enable to produce the
    // console's reference clock.
    input logic CoreClock, // Core system clock
    input logic ClkEn,

    // DDR System RAM or other large RAM.
    // MainRAM should be DMA/IOMMU controlled, and the host must indicate the location of the load
    // image. 
    RetroMemoryPort.Initiator MainRAM,
    // DDR, HyperRAM, or SRAM on the expansion bus
    RetroMemoryPort.Initiator ExpansionRAM0,
    RetroMemoryPort.Initiator ExpansionRAM1,
    RetroMemoryPort.Initiator ExpansionRAM2,

    output logic [12:0] AV,  // AV
    // ================
    // = External Bus =
    // ================

    // Cartridge bus wide enough for NES, 69 I/O
    output logic CartridgeClk,
    input logic [68:0] CartridgeIn,
    output logic [68:0] CartridgeOut,

    // Controller I/O, from µC
    input logic ControllerClk,
    input logic ControllerIn,
    output logic ControllerOut,

    // Expansion
    input logic [31:0] ExpansionPortIn,
    output logic [31:0] ExpansionPortOut,

    // Console
    RetroComm.Target Console
);

    uwire Delay;
    uwire Reset;
    uwire Ce;
    
    uwire Read, Write;
    uwire [15:0] Address;
    uwire [7:0] DataIn, DataOut;
    uwire AudioIn;
    uwire CS, Ready, DataReady;

    uwire CartDelay;
    uwire MainRAMDelay;
    uwire VRAMDelay;
    
    // The cartridge controller needs to always provide both Ready and DataReady unless waiting
    // for operations.  These may frequently fall between clock ticks.  When using a hardware
    // cartridge, both of these should be kept on.
    assign Delay = ~(Ready & DataReady);

    // ======================
    // = System RAM Objects =
    // ======================
    // We create BRAMs in the shim so a different shim can use the GBC Cartridge Controller without
    // dedicating the BRAM exclusively to the GBC when not running.
    RetroBRAM
    #(
        .AddressBusWidth(15),
        .DeviceType(DeviceType)
    ) GBSystemRAM;

    RetroBRAM
    #(
        .AddressBusWidth(15),
        .DeviceType(DeviceType)
    ) GBVideoRAM;
    // TODO:  Chunk of BRAM for cartridge cache
    // TODO:  Chunk of BRAM for mappers

    // ========
    // = CATC =
    // ========
    // Cartridge controller triggers Delay if data isn't ready
    RetroCATC CATC(
        .Clk(CoreClk),
        .Delay(Delay),
        .ClkEn(ClkEn),
        .Reset(Reset),
        .ClkEnOut(Ce)
    );

    // =================================
    // = Interface to hardware GamePak =
    // =================================
    IGBCGamePak GamePak(
        .Clk(CartridgeClk),
        .Write(CartridgeOut[2]),
        .Read(CartridgeOut[3]),
        .CS(CartridgeOut[4]),
        .Address(CartridgeOut[20:5]),
        .DataIn(CartridgeIn[28:21]),
        .DataOut(CartridgeOut[28:21]),
        .Reset(CartridgeOut[29]),
        .Audio(CartridgeIn[30])
    );

    // ========================
    // = Interface to GameBoy =
    // ========================
    IRetroMemoryPort
    #(
        .AddressBusWidth(16),
        .DataBusWidth(1)
    )
    GamePakFrontend
    (
        .Clk(CoreClk),
        .Address(Address),
        .DInitiator(DataIn),
        .DTarget(DataOut),
        .Access(Read),
        .Write(Write),
        .Ready(Ready),
        .DataReady(DataReady)
    );

    IGBCGamePakBus GamePakBus
    (
        .CS(CS),
        .Reset(Reset),
        .AudioIn(AudioIn)
    );

    // Cartridge Controller is either pass-through or storage + mappers
    GBCCartridgeController CartridgeController
    (
        // .Clk(CoreClk), // FIXME:  How do we handle clocks and clock domains?
        .ClkEn(Ce), // Note:  Operations fetching/caching virtual cart must continue regardless
        
        // System and video BRAMs
        .SystemRAM(GBSystemRAM),
        .VideoRAM(GBVideoRAM),

        // Example:  Physical GamePak
        .GamePak(GamePak.Controller),
        // GamePak virtual interface for core
        .MemoryBus(GamePakFrontend.Target),
        .GamePakBus(GamePakBus.Controller)
    );
    
    // 
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
endmodule

// Core module:  Abstract to clock/CE, RAM elements, AV, cartridge, peripherals.
// Cartridge controler acts as the whole CPU memory bus.
module RetroMisterGBCCore
(
    input Clk,
    input ClkEn,

    // FIXME:  input for comm with HDMI/DP?
    output logic [12:0] AV,

    // CPU memory bus, attached to the cartridge controller
    IRetroMemoryPort.Initiator MemoryBus,
    // Other GamePak pins
    IGBCGamePakBus.GameBoy GamePak,

    // ================
    // = External Bus =
    // ================
    // Cartridge and serial bus only in this configuration.
    // Uses 30 I/O GamePak + 4 I/O serial = 34 I/O

    // Serial bus for Game-Link cable
    output logic SerialOut,
    input logic SerialIn,
    output logic SD, // CPU pin 14? Disconnected in the cable
    output logic SerialClk
);

endmodule