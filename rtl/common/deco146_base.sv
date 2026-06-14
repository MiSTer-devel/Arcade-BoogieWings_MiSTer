//
// deco146_base.sv
// Data East 146/104 protection chip — porting RTL.
//
// Riferimento C++: reference/mame/deco146.cpp (read_data, read_protport,
// write_protport, reorder).
//
// Read latency: 2 ck (registered table BRAM + registered final output).
// Per 68K: jtframe_68kdtack_cen wait1 interno + bus_busy 1 ck = 2 ck totali.
//

module deco146_base #(
    parameter [7:0]  XOR_PORT  = 8'h2c,
    parameter [7:0]  MASK_PORT = 8'h36,
    parameter [7:0]  SOUND_PORT= 8'h64,
    parameter [7:0]  BANK_SWAP_READ_ADDR = 8'h78,
    parameter [15:0] MAGIC_READ_ADDR_XOR = 16'h44a,
    parameter        MAGIC_XOR_ENABLED = 1'b0,
    parameter [1:0]  ADDR_SCRAMBLE = 2'd0,   // 0=none, 1=reversed, 2=interleave
    parameter        TABLE_OFFSET_HEX  = "deco146_offset.hex",
    parameter        TABLE_MAPPING_HEX = "deco146_mapping.hex",
    parameter        TABLE_FLAGS_HEX   = "deco146_flags.hex"
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] cpu_addr,
    input  wire        cpu_cs,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_dsn,
    output reg  [15:0] cpu_rdata,

    input  wire [15:0] port_a,
    input  wire [15:0] port_b,
    input  wire [15:0] port_c,

    output reg   [7:0] soundlatch_data,
    output reg         soundlatch_irq,
    input  wire        soundlatch_rd,
    output wire  [7:0] soundlatch_dout
);

// ============================================================
// Address scramble
// ============================================================
wire [10:0] addr_w = cpu_addr[11:1];
reg [10:0] addr_scrambled;
always @(*) begin
    case (ADDR_SCRAMBLE)
        2'd1: begin // reversed (boogwing)
            addr_scrambled = {addr_w[10],
                              addr_w[0], addr_w[1], addr_w[2], addr_w[3], addr_w[4],
                              addr_w[5], addr_w[6], addr_w[7], addr_w[8], addr_w[9]};
        end
        2'd2: begin // interleave
            addr_scrambled = {addr_w[10],
                              addr_w[8], addr_w[9], addr_w[6], addr_w[7],
                              addr_w[4], addr_w[5], addr_w[2], addr_w[3],
                              addr_w[0], addr_w[1]};
        end
        default: addr_scrambled = addr_w;
    endcase
end

wire [10:0] magic_xor_w = {1'b0, MAGIC_READ_ADDR_XOR[10:1]};
// MAME deco146.cpp: magic xor è applicato SOLO in read_protport (linea 1217-1218),
// NON in write_protport. Quindi serve un addr separato per la write path.
wire [10:0] addr_for_lookup = MAGIC_XOR_ENABLED ? (addr_scrambled ^ magic_xor_w) : addr_scrambled;
wire [10:0] addr_for_write  = addr_scrambled;

// ============================================================
// Lookup tables (BRAM, .hex initialized)
// ============================================================
(* ramstyle = "M10K" *) reg [15:0] tbl_offset  [0:1023];
(* ramstyle = "M10K" *) reg [79:0] tbl_mapping [0:1023];
(* ramstyle = "M10K" *) reg [1:0]  tbl_flags   [0:1023];
initial begin
    $readmemh(TABLE_OFFSET_HEX,  tbl_offset);
    $readmemh(TABLE_MAPPING_HEX, tbl_mapping);
    $readmemh(TABLE_FLAGS_HEX,   tbl_flags);
end

// ============================================================
// RAMBANK 2 x 128 word
// ============================================================
(* ramstyle = "MLAB" *) reg [15:0] rambank0 [0:127];
(* ramstyle = "MLAB" *) reg [15:0] rambank1 [0:127];
integer init_i;
initial begin
    for (init_i = 0; init_i < 128; init_i = init_i + 1) begin
        rambank0[init_i] = 16'hFFFF;
        rambank1[init_i] = 16'hFFFF;
    end
end
reg current_rambank;
reg [15:0] xor_reg;
reg [15:0] nand_reg;

reg [10:0] latch_addr;
reg [15:0] latch_data;
reg        latch_flag;

// ============================================================
// Pipeline read: 1 ck registered (BRAM read + source select + reorder + xor/nand)
// ============================================================
// Stage 0 (combinatorial): addr_for_lookup
// Stage 1 (clocked):       read BRAM, read rambank, sample ports
// Stage 2 (combinatorial): reorder + xor/nand + latch_hit mux
// Stage 3 (clocked):       cpu_rdata

reg [15:0] s1_offset;
reg [79:0] s1_mapping;
reg [1:0]  s1_flags;
reg [15:0] s1_rb0, s1_rb1;
reg [15:0] s1_pa, s1_pb, s1_pc;
reg        s1_latch_hit;
reg [15:0] s1_latch_val;
reg        s1_cb_bank;

wire latch_hit_w = cpu_cs && cpu_rd && (addr_for_lookup == latch_addr) && latch_flag;

always @(posedge clk) begin
    s1_offset    <= tbl_offset[addr_for_lookup[9:0]];
    s1_mapping   <= tbl_mapping[addr_for_lookup[9:0]];
    s1_flags     <= tbl_flags[addr_for_lookup[9:0]];
    s1_rb0       <= rambank0[tbl_offset[addr_for_lookup[9:0]][7:1]];
    s1_rb1       <= rambank1[tbl_offset[addr_for_lookup[9:0]][7:1]];
    s1_pa        <= port_a;
    s1_pb        <= port_b;
    s1_pc        <= port_c;
    s1_latch_hit <= latch_hit_w;
    s1_latch_val <= latch_data;
    s1_cb_bank   <= current_rambank;
end

// Stage 2 (combinatorial)
function [15:0] reorder_fn(input [15:0] src, input [79:0] map);
    integer i;
    reg [4:0] dest;
    begin
        reorder_fn = 16'd0;
        for (i = 0; i < 16; i = i + 1) begin
            dest = map[i*5 +: 5];
            if (src[i] && (dest[4] == 1'b0))
                reorder_fn[dest[3:0]] = 1'b1;
        end
    end
endfunction

reg [15:0] src_sel;
always @(*) begin
    case (s1_offset)
        16'h8000: src_sel = s1_pa;
        16'h8001: src_sel = s1_pb;
        16'h8002: src_sel = s1_pc;
        default:  src_sel = s1_cb_bank ? s1_rb1 : s1_rb0;
    endcase
end

reg [15:0] reord;
always @(*) reord = reorder_fn(src_sel, s1_mapping);

reg [15:0] final_data;
always @(*) begin
    final_data = reord;
    if (s1_flags[0]) final_data = final_data ^ xor_reg;
    if (s1_flags[1]) final_data = final_data & ~nand_reg;
end

// Stage 3: register final output (1 ck total latency)
always @(posedge clk) begin
    if (s1_latch_hit) cpu_rdata <= s1_latch_val;
    else              cpu_rdata <= final_data;
end

// ============================================================
// Bankswitch on read: trigger ck dopo lookup
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        current_rambank <= 1'b0;
    end else begin
        // s1_offset[15]=0 (= rambank) e [7:0] == BANK_SWAP_READ_ADDR
        if (cpu_cs && cpu_rd && !s1_latch_hit
            && s1_offset[15] == 1'b0 && s1_offset[7:0] == BANK_SWAP_READ_ADDR)
            current_rambank <= ~current_rambank;
    end
end

// ============================================================
// Write protport
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        xor_reg  <= 16'h0000;
        nand_reg <= 16'h0000;
        soundlatch_data <= 8'h00;
        soundlatch_irq  <= 1'b0;
        latch_addr <= 11'h7FF;
        latch_data <= 16'h0000;
        latch_flag <= 1'b0;
    end else begin
        soundlatch_irq <= 1'b0;

        if (cpu_cs && cpu_wr) begin
            latch_addr <= addr_for_write;
            latch_data <= cpu_wdata;
            latch_flag <= 1'b1;

            if (current_rambank)
                rambank1[addr_for_write[7:1]] <= cpu_wdata;
            else
                rambank0[addr_for_write[7:1]] <= cpu_wdata;

            // Special port writes (byte addr = addr_for_write << 1)
            if ((addr_for_write[7:0] << 1) == {1'b0, XOR_PORT})
                xor_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, MASK_PORT})
                nand_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, SOUND_PORT}) begin
                soundlatch_data <= cpu_wdata[7:0];
                soundlatch_irq  <= 1'b1;
            end
        end

        // Clear latch flag dopo una read non-latched
        if (cpu_cs && cpu_rd && !latch_hit_w) begin
            latch_flag <= 1'b0;
        end

        if (soundlatch_rd) begin
            soundlatch_irq <= 1'b0;
        end
    end
end

assign soundlatch_dout = soundlatch_data;

endmodule
