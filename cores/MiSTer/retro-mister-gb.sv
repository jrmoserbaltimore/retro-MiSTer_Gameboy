// vim: sw=4 ts=4 et
//

// This is the core shim.  RetroConosle connects everything to this; it then
// connects to the RetroGBCMister core module.

// XXX:  Are any cores inable to use CATC and BRAM caching to compensate for
// memory latency?  If so, we never need SRAM.
module RetroCoreShim
(
    // The console sends a core system clock (e.g. 200MHz) and a clock-enable
    // to produce the console's reference clock.
    input logic CoreClock, // Core system clock
    input logic ce,

    // DDR System RAM or other large
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


    // System RAM and VRAM are in BRAM.  A physical cartridge doesn't need ROM
    // mapping cache, and there's plenty of BRAM for ROM mapping cache even
    // for the largest games.
    //
    // This happily simplifies the cartridge controller.
endmodule

module RetroGBCMister
(
    input Clk,
    IDDR3.Component DDRChip0,

    // FIXME:  input for comm with HDMI/DP?
    output logic [12:0] AV;

    // ================
    // = External Bus =
    // ================
    // Cartridge and serial bus only in this configuration.
    // Uses 30 I/O GamePak + 4 I/O serial = 34 I/O

    // GamePak bus
    output logic CartridgeClk,
    output logic CartridgeReset,
    output logic [15:0] CartridgeAddress,
    input logic [7:0] CartridgeDin,
    output logic [7:0] CartridgeDout,
    output logic CartridgeCS,
    output logic CartridgeRead,
    output logic CartridgeWrite,
    input logic CartridgeAudioIn,

    // Serial bus for Game-Link cable
    output logic SerialOut,
    output logic SerialIn,
    output logic SD, // CPU pin 14? Disconnected in the cable
    output logic SerialClk,

    // Controller I/O, from µC
    input logic ControllerClk,
    input logic ControllerIn,
    output logic ControllerOut,

    // Core
    RetroComm.Initiator Core
);
