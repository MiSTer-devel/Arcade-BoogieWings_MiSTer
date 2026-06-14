// pause_overlay.sv — overlay pausa standalone.
//   - pause=0: passa video invariato (combinatoriale puro, no shift sul path).
//   - pause=1: dim video (>>1) + logo 48x48 al centro pannello centrale.
//
// Decoupled: legge solo pause + render_x/y + video RGB. Niente touch del
// triple_screen_test, niente registri sul path video, niente HS/VS shift.
//
// BRAM 2304x2 (1 M10K) con read-ahead 1 ck su render_x+1 per allineare q
// al pixel video corrente.

module pause_overlay (
	input  wire        clk,
	input  wire        pause,

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	input  wire [7:0]  rgb_r_in,
	input  wire [7:0]  rgb_g_in,
	input  wire [7:0]  rgb_b_in,

	output wire [7:0]  rgb_r_out,
	output wire [7:0]  rgb_g_out,
	output wire [7:0]  rgb_b_out
);

// =====================================================================
// Logo placement: 48x48 centro pannello centrale.
// Schermo 864x224, centro = (432, 112). Top-left logo = (408, 88).
// =====================================================================
localparam [9:0] LOGO_X    = 10'd408;
localparam [8:0] LOGO_Y    = 9'd88;
localparam [9:0] LOGO_XEND = LOGO_X + 10'd48;
localparam [8:0] LOGO_YEND = LOGO_Y + 9'd48;

// Read-ahead: per il pixel corrente serve l'address sul ck precedente.
wire [9:0] x_ahead = render_x + 10'd1;
wire [9:0] dx10    = x_ahead - LOGO_X;
wire [9:0] dy10    = {1'b0, render_y} - {1'b0, LOGO_Y};

wire in_logo_ahead = pause &&
	(x_ahead   >= LOGO_X) && (x_ahead   < LOGO_XEND) &&
	(render_y  >= LOGO_Y) && (render_y  < LOGO_YEND);

wire [5:0] dx = dx10[5:0];
wire [5:0] dy = dy10[5:0];
// addr = dy*48 + dx = (dy<<5) + (dy<<4) + dx, max=47*48+47=2303
wire [11:0] logo_addr = {1'b0, dy, 5'd0} + {2'b0, dy, 4'd0} + {6'd0, dx};

// =====================================================================
// Logo BRAM 2304x2 init da logo/logo.mem
// =====================================================================
reg [1:0] logo_rom [0:2303] /* synthesis ramstyle = "M10K" */;
initial $readmemb("logo/logo.mem", logo_rom);
reg [1:0] logo_pix;
reg       in_logo_now;
always @(posedge clk) begin
	logo_pix    <= logo_rom[logo_addr];
	in_logo_now <= in_logo_ahead;
end

// Palette logo: pal0=nero (trasparente), pal1=magenta, pal2=cyan, pal3=bianco
reg [7:0] lr, lg, lb;
always @(*) case (logo_pix)
	2'd0: {lr, lg, lb} = 24'h000000;
	2'd1: {lr, lg, lb} = 24'hFF00FF;
	2'd2: {lr, lg, lb} = 24'h00E6E4;
	2'd3: {lr, lg, lb} = 24'hFFFFFF;
endcase

wire logo_opaque = (logo_pix != 2'd0);

// =====================================================================
// Output mux combinatoriale puro (no shift sul path video!)
// =====================================================================
wire [7:0] dim_r = {1'b0, rgb_r_in[7:1]};
wire [7:0] dim_g = {1'b0, rgb_g_in[7:1]};
wire [7:0] dim_b = {1'b0, rgb_b_in[7:1]};

assign rgb_r_out = !pause             ? rgb_r_in :
                   in_logo_now & logo_opaque ? lr :
                                          dim_r;
assign rgb_g_out = !pause             ? rgb_g_in :
                   in_logo_now & logo_opaque ? lg :
                                          dim_g;
assign rgb_b_out = !pause             ? rgb_b_in :
                   in_logo_now & logo_opaque ? lb :
                                          dim_b;

endmodule
