// vim: sw=4 ts=4 et
// Copyright (c) 2020 Moonset Technologies, LLC
// License:  MIT, see LICENSE.md
//
// Game Boy Color GamePak interface
interface IGBCGamePak
(
);
    logic Clk;
    logic Write;
    logic Read;
    logic CS;
    logic Address [15:0];
    logic DFromPak [7:0];
    logic DToPak [7:0];
    logic Reset;
    logic Audio;

    modport Controller
    (
        output Clk,
        output Write,
        output Read,
        output CS,
        output Address,
        input DFromPak,
        output DToPak,
        output Reset,
        input Audio
    );
endinterface

interface IGBCGamePakBus
(

);
    logic CS;
    logic Reset;
    logic Audio;
    
    modport Controller
    (
        input CS,
        input Reset,
        output Audio
    );
    
    modport GameBoy
    (
        output CS,
        output Reset,
        input Audio
    );
endinterface