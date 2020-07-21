// vim: sw=4 ts=4 et
// Every Game Boy Color mapper implemented at once.

module GBCMapper
(
    input logic Clk,
    input logic ClkEn,
    IRetroMemoryPort.Initiator LoadImage,
    IRetroMemoryPort.Initiator SystemRAM,
    IRetroMemoryPort.Initiator ROMCache,

    // Export the memory bus back to the controller
    IRetroMemoryPort.Target MemoryBus
);

    // $0000-$00FF should be the 256-byte boot rom
    // $0143:  CGB flag ($80 CGB and DMG, $C0 CGB only)
    // $0146:  SGB flag ($00 CGB only, $03 SGB functions)
    // $0147:  Mapper type
    // $0148:  ROM size (layout)
    
    // Type 00 gives a 32Kbyte ROM and 8K RAM
endmodule