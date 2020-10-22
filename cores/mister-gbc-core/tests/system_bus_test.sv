
module TestSystemBus();

timeunit 1ns;
timeprecision 1ns;

logic clk = '0;
always #5 clk=~clk; 

logic reset = '1;
logic [2:0] setup = '0;

logic [15:0] setup_addr [0:1] = {'hff4f, 'hff70};

logic [6:0] counter = '0;
logic [8:0] dmacounter = '0;
logic [2:0] delay = '0;
logic [1:0] bus = '0;
logic pause;

ISysCon SysCon();

assign SysCon.CLK = clk;
assign SysCon.RST = reset;

IWishbone i_SystemBus();
IWishbone #(.AddressWidth(14), .TGAWidth(2)) i_VRAM();
IWishbone #(.AddressWidth(15)) i_WRAM();
IWishbone i_Cartridge();

WishboneBRAM
#(
    .AddressWidth(15),
    .DataWidth(8),
    .DeviceType("Xilinx")
) GBSystemRAM
(
    .SysCon(SysCon),
    .Initiator(i_WRAM)
);

    // ROM
    IWishbone
    #(
        .AddressWidth(23),
        .DataWidth(8) 
    ) ILoadImage();

    // CRAM
    IWishbone
    #(
        .AddressWidth(17),
        .DataWidth(8) 
    ) ICartridgeRAM();
    
    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    IRTC();
    
    IWishbone
    #(
        .AddressWidth(16),
        .DataWidth(8)
    )
    IMapper();

    //(* dont_touch = "true" *)
    GBCMapper Mapper
    (
        .SysCon(SysCon),
        .LoadImage(ILoadImage.Initiator),
        .CartridgeRAM(ICartridgeRAM.Initiator),
        .RTC(IRTC.Initiator),
        .MemoryBus(IMapper.Target)
    );

assign i_SystemBus.ForceStall = 0;
assign i_VRAM.ForceStall = 0;
assign i_WRAM.ForceStall = 0;
assign i_Cartridge.ForceStall = 0;

assign i_Cartridge.CYC = ILoadImage.CYC | ICartridgeRAM.CYC;
assign i_Cartridge.STB = ILoadImage.STB | ICartridgeRAM.STB;
assign i_Cartridge.DAT_ToTarget = ILoadImage.STB ? ILoadImage.DAT_ToTarget : ICartridgeRAM.DAT_ToTarget;
assign i_Cartridge.ADDR = ILoadImage.STB ? ILoadImage.ADDR : ICartridgeRAM.ADDR;
assign i_Cartridge.WE = ILoadImage.STB ? ILoadImage.WE : ICartridgeRAM.WE;

assign ILoadImage.ACK = i_Cartridge.ACK;
assign ICartridgeRAM.ACK = i_Cartridge.ACK;
assign ILoadImage.DAT_ToInitiator = i_Cartridge.DAT_ToInitiator;
assign ICartridgeRAM.DAT_ToInitiator = i_Cartridge.DAT_ToInitiator;
assign ILoadImage.STALL = i_Cartridge.STALL;
assign ICartridgeRAM.STALL = i_Cartridge.STALL;


logic [7:0] OAM [0:'h9f];
logic [7:0] Cartridge [0:'hff];
GBCMemoryBus SystemBus
(
    .SysCon(SysCon),
    .SystemRAM(i_WRAM.Initiator),
    .VideoRAM(i_VRAM.Initiator),
    .VideoStatus(3'b000),
    .Cartridge(IMapper.Initiator),
    .MemoryBus(i_SystemBus.Target)
);
always_ff @(posedge clk)
begin
    reset <= '0;
    i_SystemBus.Prepare();
    i_Cartridge.PrepareResponse();
    i_WRAM.PrepareResponse();
    i_VRAM.PrepareResponse();
    
    if (reset)
    begin
        i_SystemBus.Open();
        i_VRAM.Open();
        i_WRAM.Open();
        i_Cartridge.Open();
        i_VRAM.Unstall();
        i_WRAM.Unstall();
        i_Cartridge.Unstall();
        i_SystemBus.SendData('hff70,'h0);
    end
    
    pause <= '0;
    if (!i_SystemBus.Stalled())
    begin
        if (setup < 2)
        begin
            i_SystemBus.SendData(setup_addr[setup],'h0);
            setup <= setup+1;
            pause <= '1;
        end else if (!pause && bus == '0) // HRAM
        begin
            i_SystemBus.SendData({8'hff,1'b1,counter},{1'b0,counter});
            counter <= counter+1;
            if (counter == 'h7f)
                bus <= bus + 1;
        end else if (bus == 2'b01) // Cartridge RAM at $c0xx
        begin
            i_SystemBus.SendData({8'ha0,1'b0,counter},{1'b0,counter});
            counter <= counter+1;
            if (counter == 'h7f)
            begin
                bus <= 2'b10; // move to VRAM
                counter <= 'h00;
            end
        end else if (bus == 2'b10) // VRAM
        begin
            if (!dmacounter)
                counter <= counter + 1;
            else
                dmacounter <= dmacounter - 1;

            if (counter < 'h40) // VRAM access, regular, write
                i_SystemBus.SendData('h8000|counter, 8'h00|counter);
            else if (counter < 'h4b && counter != 'h46) // Registers, except 'h46
                i_SystemBus.SendData('hff00|counter, 8'h00|counter);
            else if (counter < 'h68) // OAM
                i_SystemBus.SendData('hfe00|counter, 8'h00|counter);
            else if (counter <= 'h6c) // GBC registers
                i_SystemBus.SendData('hff00|counter, 8'h00|counter);
            else if (counter == 'h6d) // OAM DMA test:  Cartridge to VRAM)
            begin
                i_SystemBus.SendData('hff46, 'h20);
                dmacounter <= 160;
            end else if (counter == 'h6e) // Wait for OAMDMA
                i_SystemBus.SendData('hff80, dmacounter);
            else if (counter == 'h6f) // VRAM to VRAM DMA
            begin
                i_SystemBus.SendData('hff46, 'h80);
                dmacounter <= 160;
            end else if (counter == 'h70) // Wait for OAMDMA
                i_SystemBus.SendData('hff81, dmacounter);
            else
            begin
                counter <= 'h00;
                pause <= '0;
                bus <= 2'b11; // return to HRAM test
            end
        end else if (bus == 2'b11) // WRAM
        begin
            i_SystemBus.SendData({8'hc0,1'b0,counter},{1'b0,counter});
            counter <= counter+1;
            if (counter == 'h7f)
            begin
                bus <= 2'b00; // move to VRAM
                counter <= 'h00;
            end
        end else if (pause) i_SystemBus.ADDR <= 'hff00;
    end
    
    delay <= delay - |delay;
    if (i_Cartridge.RequestReady())
    begin
        i_Cartridge.Stall();
        if (!delay) delay <= 1; // cartridge to BRAM to cartridge.
        if (delay || 1)
        begin
            i_Cartridge.Unstall();
            i_Cartridge.SendResponse(Cartridge[i_Cartridge.ADDR[7:0]]);
            if (i_Cartridge.WE) Cartridge[i_Cartridge.ADDR[7:0]] <= i_Cartridge.GetRequest(); 
        end
    end

    // Video address spaces:
    //  - TGA = 2'b00:  VRAM
    //  - TGA = 2'b01:  OAM
    //  - TGA = 2'b10:  Registers
    // Video modes:
    //  - TGC = 1'b0:  Regular
    //  - TGC = 1'b1:  OAM DMA (if address space is VRAM, copy from VRAM rather than input to OAM)
    if (i_VRAM.RequestReady())
    begin
        i_VRAM.Stall();
        if (!delay) delay <= 1;
        if (delay || 1)
        begin
            i_VRAM.Unstall();
            case (i_VRAM.TGA)
            2'b00: i_VRAM.SendResponse(i_VRAM.TGC ? 8'ha0 : 8'haa);
            2'b01:
                begin
                    if (i_VRAM.WE)
                        OAM[i_VRAM.ADDR[7:0]] <= i_VRAM.GetRequest();
                        i_VRAM.SendResponse(i_VRAM.TGC ? 8'hd0 : OAM[i_VRAM.ADDR[7:0]]);
                end
            2'b10: i_VRAM.SendResponse(8'h99);
            default: i_VRAM.SendResponse(8'h97);
            endcase
        end
    end
end

endmodule