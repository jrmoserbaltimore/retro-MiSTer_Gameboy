// vim: sw=4 ts=4 et
// GBC Cartridge Controller
//
// This is a full CPU memory bus controller.

module GBCCartridgeController
#(
    parameter string DeviceType = "Xilinx"
)
(
    logic Clk,
    logic ClkEn,
    // Communication to main system.  System can call for boot from ROM, 
    IRetroComm.Target Comm,
    // Pass these to the mapper module, which will use the  
    IRetroMemoryPort.Initiator LoadImage,
    RetroBRAM.Initiator ROMCache,

    // RAM for memory map
    RetroBRAM.Initiator SystemRAM, // Gameboy system RAM
    RetroBRAM.Initiator VideoRAM,

    // Physical cartridge
    IGBCGamePak.Controller GamePak,
    
    // Expose to GBC core
    IRetroMemoryPort.Target MemoryBus,
    IGBCGamePakBus.Controller GamePakBus
);

    logic UseCartridge = '0;
    logic IsCGB = '0;

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
        if (UseCartridge)
        begin
            // The module on the other end of the GamePak bus acts as the cartridge controller
            GamePak.Write = MemoryBus.Write;
            GamePak.Read = MemoryBus.Access;
            GamePak.CS = GamePakBus.CS;
            GamePak.Address = MemoryBus.Address;
            GamePak.DataOut = MemoryBus.Dout;
            GamePak.Reset = GamePakBus.Reset;
            
            MemoryBus.Din = GamePak.Din;
            MemoryBus.Ready = '1;
            MemoryBus.DataReady = '1;
            
            GamePakBus.Audio = GamePak.Audio;
        end
        else
        begin
            // Do nothing with the gamepak
            GamePak.Clk = '0;
            GamePak.Write = '0;
            GamePak.Read = '0;
            GamePak.CS = '0;
            GamePak.Address = '0;
            GamePak.DataOut = '0;
            GamePak.Reset = '0;
            
            VideoRAM.Dout = MemoryBus.Din;
            SystemRAM.Dout = MemoryBus.Din;
            
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
                MemoryBus.Dout = VideoRAM.Din;
                MemoryBus.Ready = VideoRAM.Ready;
                MemoryBus.DataReady = VideoRAM.DataReady;
            end
            else
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
               
               MemoryBus.Dout = SystemRAM.Din;
               MemoryBus.Ready = SystemRAM.Ready;
               MemoryBus.DataReady = SystemRAM.DataReady;
            end
            else
            begin
                SystemRAM.Access = '0;
                SystemRAM.Write = '0;
            end
        end
    end
    
    always_ff @(posedge Clk)
    if (ClkEn && !UseCartridge)
    begin
        // HRAM
        if (MemoryBus.Address >= 'hff80 && MemoryBus.Address <= 'hfffe && MemoryBus.Access)
        begin
            if (MemoryBus.Write)
                HRAM[MemoryBus.Address] = MemoryBus.Din;
            else
                MemoryBus.Dout = HRAM[MemoryBus.Address];
        end
    end

endmodule