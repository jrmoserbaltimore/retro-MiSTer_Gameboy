// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md

module GBCIOSystem
#(
    parameter DeviceType = "Xilinx",
    parameter LowPower = 0
)
(
    ISysCon SysCon,
    input logic Ce, // Paces the Gameboy clock
    input logic GB2x, // If in double-speed mode
    // Joypad
    input logic [1:0] JoypadID, // for Super Gameboy
    input logic [7:0] Keys,

    // Serial
    input logic SerialClkIn,
    output logic SerialClkOut,
    input logic SerialIn,
    output logic SerialOut,

    // IR port
    input logic IRIn,
    output logic IROut,

    // Digital 48000Hz output, 24-bit little-endian
    IWishbone.Initiator IOBus,

    // Interrupts
    //  2 - Timer (INT 50)
    //  3 - Serial (INT 58)
    //  4 - Joypad (INT 60)
    output logic [4:2] Interrupt,
    // 8-bit addressing to $ffxx
    IWishbone.Target SystemBus
);

    // Audio registers

    logic [7:0] Pulse1Registers ['h10:'h14];
    logic [7:0] Pulse2Registers ['h16:'h19];
    logic [7:0] WaveRegisters ['h1a:'h1e];
    logic [7:0] NoiseRegisters ['h20:'h23];
    logic [7:0] SoundControlRegisters ['h24:'h26];
    logic [7:0] WavePattern ['h30:'h3f];

    GBCAudio APU
    (
        .SysCon(SysCon),
        .Ce(Ce),
        .GB2x(GB2x),
        
        .Pulse1Registers(Pulse1Registers),
        .Pulse2Registers(Pulse2Registers),
        .WaveRegisters(WaveRegisters),
        .NoiseRegisters(NoiseRegisters),
        .SoundControlRegisters(SoundControlRegisters),
        .WavePattern(WavePattern),
        .AudioBus(IOBus)
    );

endmodule