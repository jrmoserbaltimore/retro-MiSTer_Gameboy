// vim: sw=4 ts=4 et

// Game Boy Color GamePak interface
interface IGBCGamePak
(
);
    logic Clk;
    logic Write;
    logic Read;
    logic CS;
    logic Address [15:0];
    logic DataIn [7:0];
    logic DataOut [7:0];
    logic Reset;
    logic Audio;

    modport Controller
    (
        output Clk,
        output Write,
        output Read,
        output CS,
        output Address,
        input DataIn,
        output DataOut,
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