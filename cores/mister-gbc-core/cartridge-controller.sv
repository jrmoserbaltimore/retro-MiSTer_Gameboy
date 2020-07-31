// vim: sw=4 ts=4 et
// GBC Cartridge Controller
//
// This is a full CPU memory bus controller.

module GBCCartridgeController
#(
    parameter string DeviceType = "Xilinx",
    parameter PowerDown = 1 // Set if the GamePak is powered down when not in use
)
(
    logic Clk,
    logic ClkEn,
    // Communication to main system.  System can call for boot from ROM, and controller can call
    // for save states and save RAM.
    IRetroComm.Target Comm,
    // Mapper for digital, GamePak for physical cartridge  
    IRetroMemoryPort.Initiator Mapper,
    IGBCGamePak.Controller GamePak,
    
    // Expose to system bus
    IRetroMemoryPort.Target MemoryBus,
    // expose to GBC Core ??? Or handle logic here?
    IGBCGamePakBus.Controller GamePakBus
);

    logic UseCartridge;
    logic IsCGB;

    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space

    // When using cartridge, the mapper just scrambles around
    assign Mapper.Address = MemoryBus.Address;
    assign Mapper.DToTarget = MemoryBus.DToTarget;
    assign Mapper.Access = MemoryBus.Access;
    assign Mapper.Mask = MemoryBus.Mask;
    assign Mapper.Write = MemoryBus.Write;
    assign Mapper.Clk = Clk;
    assign Mapper.ClkEn = ClkEn && !UseCartridge;

    generate
        if (PowerDown)
        begin
            assign GamePak.Write = MemoryBus.Write;
            assign GamePak.Read = MemoryBus.Access;
            assign GamePak.CS = GamePakBus.CS;
            assign GamePak.Address = MemoryBus.Address;
            assign GamePak.DToPak = MemoryBus.DToTarget;
            assign GamePak.Reset = GamePakBus.Reset;
        end else always_comb
        begin
            if (UseCartridge)
            begin
                // Pass through
                GamePak.Write = MemoryBus.Write;
                GamePak.Read = MemoryBus.Access;
                GamePak.CS = GamePakBus.CS;
                GamePak.Address = MemoryBus.Address;
                GamePak.DToPak = MemoryBus.DToTarget;
                GamePak.Reset = GamePakBus.Reset;
            end else
            begin
                // Do nothing with the gamepak
                GamePak.Clk = '0;
                GamePak.Write = '0;
                GamePak.Read = '0;
                GamePak.CS = '0;
                GamePak.Address = '0;
                GamePak.DToPak = '0;
                GamePak.Reset = '0;
            end
        end
    endgenerate

    always_comb
    begin
        if (UseCartridge)
        begin
            MemoryBus.DToInitiator = GamePak.DFromPak;
            MemoryBus.Ready = '1;
            MemoryBus.DataReady = '1;

            GamePakBus.Audio = GamePak.Audio;
        end
        else
            // Switch to mapper
            MemoryBus.DToInitiator = Mapper.DToInitiator;
            MemoryBus.Ready = Mapper.Ready;
            MemoryBus.DataReady = Mapper.DataReady;
        begin
            
        end
    end

endmodule