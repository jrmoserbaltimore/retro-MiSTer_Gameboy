// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md

module GBCAudio
#(
    parameter DeviceType = "Xilinx",
    parameter LowPower = 0
)
(
    ISysCon SysCon,
    input logic Ce, // Paces the Gameboy clock
    input logic GB2x, // If in double-speed mode

    input logic [7:0] Pulse1Registers ['h10:'h14],
    input logic [7:0] Pulse2Registers ['h16:'h19],
    input logic [7:0] WaveRegisters ['h1a:'h1e],
    input logic [7:0] NoiseRegisters ['h20:'h23],
    input logic [7:0] SoundControlRegisters ['h24:'h26],
    input logic [7:0] WavePattern ['h30:'h3f],

    // Digital 48000Hz output, 24-bit little-endian
    IWishbone.Initiator AudioBus
);

    // Audio output buffers
    logic [23:0] SampleBuffer [0:1];
    wire [23:0] SampleBufferLeft = SampleBuffer[0];
    wire [23:0] SampleBufferRight = SampleBuffer[1];

    wire [7:0] SampleBytesLeft [2:0] = {
                    SampleBufferLeft[23:16],
                    SampleBufferLeft[15:8],
                    SampleBufferLeft[7:0]
                    };
    wire [7:0] SampleBytesRight [2:0] = {
                    SampleBufferRight[23:16],
                    SampleBufferRight[15:8],
                    SampleBufferRight[7:0]
                    };

    logic [1:0] SampleByteIndex;

    logic [1:0] SoundGeneratorIndex;
    // Tone generator
    module PulseWave
    #(
        parameter Sweep = 1
    )
    (
        // Sweep for channel 1
        input logic [2:0] SweepTime, // $ff10 bits 6-4
        input logic SweepDirection, // $ff10 bit 3
        input logic [2:0] SweepShift, // $ff10 bits 2-0

        // Both channels use these
        input logic [1:0] DutyCycle, // $ff16 and $ff11 bits 7-6
        input logic [5:0] SoundLength, // $ff16 and $ff11 bits 5-0
        input logic [3:0] InitialVolume, // $ff17 and $ff12 bits 7-4
        input logic EnvelopeDirection, // $ff17 and $ff12 bit 3
        input logic EnvelopeSweep, // $ff17 and $ff12 bits 2-0
        input logic [10:0] Frequency, // $ff19 2-0 and $ff18 ($ff14 and $ff13, respectively)
        input logic Counter, // $ff19 and $ff14 bit 6
        input logic Restart, // $ff19 and $ff14 bit 7

        input logic MakeSample,
        output logic SampleReady,
        output logic [23:0] Sample[1:0]
    );

    endmodule

    module DigitalWave
    (
        input logic On, // $ff1a bit 7
        input logic [7:0] SoundLength, // $ff1b
        input logic [1:0] Volume, // $ff1c bits 6-5
        input logic [10:0] Frequency, // $ff1d 2-0 and $ff1e
        input logic Counter, // $ff1e bit 6
        input logic Restart, // $ff1e bit 7
        input logic [7:0] WavePattern ['h0:'hf],

        input logic MakeSample,
        output logic SampleReady,
        output logic [23:0] Sample[1:0]
    );
    endmodule

    // TODO:  Noise channel
    PulseWave Pulse1
    (
        .SweepTime(Pulse1Registers['h10][6:4]),
        .SweepDirection(Pulse1Registers['h10][3]),
        .SweepShift(Pulse1Registers['h10][2:0]),

        .DutyCycle(Pulse1Registers['h11][7:6]),
        .SoundLength(Pulse1Registers['h11][5:0]),
        .InitialVolume(Pulse1Registers['h12][7:4]),
        .EnvelopeDirection(Pulse1Registers['h12][3]),
        .EnvelopeSweep(Pulse1Registers['h12][2:0]),
        .Frequency({Pulse1Registers['h14][2:0], Pulse1Registers['h13]}),
        .Counter(Pulse1Registers['h14][6]),
        .Restart(Pulse1Registers['h14][7])
    );

    PulseWave #(.Sweep(0)) Pulse2
    (
        .SweepTime('h0),
        .SweepDirection('h0),
        .SweepShift('h0),
        
        .DutyCycle(Pulse2Registers['h16][7:6]),
        .SoundLength(Pulse2Registers['h16][5:0]),
        .InitialVolume(Pulse2Registers['h17][7:4]),
        .EnvelopeDirection(Pulse2Registers['h17][3]),
        .EnvelopeSweep(Pulse2Registers['h17][2:0]),
        .Frequency({Pulse2Registers['h19][2:0], Pulse1Registers['h18]}),
        .Counter(Pulse2Registers['h19][6]),
        .Restart(Pulse2Registers['h19][7])
    );

    DigitalWave DigitalAudio
    (
        .On(WaveRegisters['h1a][7]),
        .SoundLength(WaveRegisters['h1b]),
        .Volume(WaveRegisters['h1c][6:5]),
        .Frequency({WaveRegisters['h1e][2:0], WaveRegisters['h1d]}),
        .Counter(WaveRegisters['h1e][6]),
        .Restart(WaveRegisters['h1e][7]),
        .WavePattern(WavePattern['h30:'h3f])
    );

    always_ff @(posedge SysCon.CLK)
    if (SysCon.RST)
    begin
        AudioBus.Open();
    end else
    begin
        AudioBus.Prepare();
        // TODO:  Follow timing, generate/validate sample readiness, output to bus
        for (int i = 0; i <= 1; i++) 
            SampleBuffer[i] = Pulse1.Sample[i][23:2] + Pulse2.Sample[i][23:2]
                          + DigitalAudio.Sample[i][23:2];
    end

 endmodule