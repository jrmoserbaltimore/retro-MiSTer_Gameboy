// vim: sw=4 ts=4 et
// This is a full CPU memory bus controller.


module GBCMemoryBus
#(
    parameter string DeviceType = "Xilinx"
)
(
    logic Clk,
    logic ClkEn,
    // Communication to main system.  System can call for boot from ROM, and controller can call
    // for save states and save RAM.
    IRetroComm.Target Comm,

    // RAM for memory map
    IRetroMemoryPort.Initiator SystemRAM, // Gameboy system RAM
    IRetroMemoryPort.Initiator VideoRAM, // VRAM module

    // Cartridge controller
    IRetroMemoryPort.Initiator Cartridge,
    // System bus it exposes
    IRetroMemoryPort.Target MemoryBus
);

    logic IsCGB;

    logic ['hff00:'hff7f][7:0] IORegisters;
    logic ['hff80:'hfffe][7:0] HRAM;

    // Map SystemRAM
    // Bank 0 at $C000 to $CFFF
    // Banks 1-7 at $D000 to $DFFF
    // Banks are 4KiB, so the address for $D000-$DFFF is 12 bits plus the bank number at the top.
    // Bank select 0 puts bank 1 at $D000.
    // The bank select is $FF70 [2:0]

    // VRAM bank selector
    assign VideoRAM.Address[13] = IORegisters['hff4f][0] & IsCGB;
    assign VideoRAM.Address[12:0] = MemoryBus.Address[12:0];
    
    // WRAM bank selector
    assign SystemRAM.Address[13:12] = (MemoryBus.Address[13:12] == 'b00) ? 'b00 : // Accessing the lower bank
                                      (!IsCGB || IORegisters['hff70] == 'b00) ? 'b01 : // 00 = bank 1, also Bank 1 on CGB
                                      IORegisters['hff70];
    assign SystemRAM.Address[11:0] = MemoryBus.Address[11:0];
    
    // Mapper supplies:
    //   - $0000-$3FFF fixed bank ROM
    //   - $4000-$7FFF bank swap ROM
    //   - $A000-$BFFF 8k cartridge ram space
    
    // TODO: $FE00-$FE9F OAM table
    
    always_comb
    begin
        // Data to send to vrams/wram
        VideoRAM.DToTarget = MemoryBus.DToTarget;
        SystemRAM.DToTarget = MemoryBus.DToTarget;
        
        // GamePakBus.Audio = ?;
        if (MemoryBus.Address[15:13] == 3'b100)
        begin
            // Map VideoRAM to $8000 to $9FFF
            // $FF4F [0] selects which bank
            // 1000 0000 0000 0000
            // 1001 1111 1111 1111
            VideoRAM.Access = MemoryBus.Access;
            VideoRAM.Write = MemoryBus.Write;

            // Gameboy talks to the VRAM now
            MemoryBus.DToInitiator = VideoRAM.DToInitiator;
            MemoryBus.Ready = VideoRAM.Ready;
            MemoryBus.DataReady = VideoRAM.DataReady;
        end else
        begin
            // VRAM ignore address/data
            VideoRAM.Access = '0;
            VideoRAM.Write = '0;
        end
        
        // $C000-$DFFF and $E000-$FFDF
        if (
            MemoryBus.Address[15:13] == 3'b110 ||
            (MemoryBus.Address[15:13] == 3'b111 && MemoryBus.Address[12:9] != 'b1111) // Echo RAM
           )
        begin
            // System RAM Bank 0:
            // 1100 0000 0000 0000
            // 1100 1111 1111 1111

            // System RAM bank 1-7:
            // 1101 0000 0000 0000
            // 1101 1111 1111 1111
           
            SystemRAM.Access = MemoryBus.Access;
            SystemRAM.Write = MemoryBus.Write;
           
            MemoryBus.DToInitiator = SystemRAM.DToInitiator;
            MemoryBus.Ready = SystemRAM.Ready;
            MemoryBus.DataReady = SystemRAM.DataReady;
        end else
        begin
            SystemRAM.Access = '0;
            SystemRAM.Write = '0;
        end
        
        if (MemoryBus.Address[15:14] == 2'b10) // Cartridge
        begin
            Cartridge.Access = MemoryBus.Access;
            Cartridge.Write = MemoryBus.Write;
            MemoryBus.DToInitiator = Cartridge.DToInitiator;
            MemoryBus.Ready = Cartridge.Ready;
            MemoryBus.DataReady = Cartridge.DataReady;
        end
    end
    
    always_ff @(posedge Clk)
    if (ClkEn)
    begin
        // HRAM
        if (MemoryBus.Address & 'hff80 == 'hff80 && MemoryBus.Address[6:0] != 'h7f && MemoryBus.Access)
        begin
            if (MemoryBus.Write)
                HRAM[MemoryBus.Address] = MemoryBus.DToTarget;
            else
                MemoryBus.DToInitiator = HRAM[MemoryBus.Address];
        end
    end

endmodule