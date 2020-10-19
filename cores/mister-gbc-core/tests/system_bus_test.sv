
module TestSystemBus();

timeunit 1ns;
timeprecision 1ns;

logic clk = '0;
always #5 clk=~clk; 

logic reset = '1;
logic [2:0] setup = '0;

logic [15:0] setup_addr [0:1] = {'hff4f, 'hff70};

logic [6:0] counter = '0;
logic [2:0] delay = '0;
logic [1:0] bus = '0;
logic pause;

IWishbone i_SystemBus();
IWishbone #(.AddressWidth(14)) i_VRAM();
IWishbone #(.AddressWidth(15)) i_WRAM();
IWishbone i_Cartridge();

assign i_SystemBus.CLK = clk;
assign i_VRAM.CLK = clk;
assign i_WRAM.CLK = clk;
assign i_Cartridge.CLK = clk;

assign i_SystemBus.RST = reset;
assign i_VRAM.RST = reset;
assign i_WRAM.RST = reset;
assign i_Cartridge.RST = reset;

assign i_SystemBus.ForceStall = 0;
assign i_VRAM.ForceStall = 0;
assign i_WRAM.ForceStall = 0;
assign i_Cartridge.ForceStall = 0;

GBCMemoryBus SystemBus
(
    .SysCon(i_SystemBus.SysCon),
    .SystemRAM(i_WRAM.Initiator),
    .VideoRAM(i_VRAM.Initiator),
    .Cartridge(i_Cartridge.Initiator),
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
        end else if (!pause && bus == '0)
        begin
            i_SystemBus.SendData({8'hff,1'b1,counter},{1'b0,counter});
            counter <= counter+1;
            if (counter == 'h7f)
                bus <= bus + 1;
        end else if (bus == 2'b01) // Cartridge
        begin
            i_SystemBus.RequestData('h1000);
            pause <= '1;
            bus <= '0; // return to HRAM test
        end else if (pause) i_SystemBus.ADDR <= 'hff00;
    end
    
    if (i_Cartridge.RequestReady() || delay != '0)
    begin
        i_Cartridge.Stall();
        delay <= delay+1;
        if (delay == '1)
        begin
            i_Cartridge.Unstall();
            i_Cartridge.SendResponse(8'hff);
        end
    end
end

endmodule