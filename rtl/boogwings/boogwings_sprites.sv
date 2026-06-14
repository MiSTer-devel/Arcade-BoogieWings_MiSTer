// SPDX-License-Identifier: GPL-3.0-or-later
//
// boogwings_sprites — DECO_SPRITE (DECO52) engine BoogieWings, SCANLINE-BASED.
//
// MAME equivalente: m_sprite_bitmap full-frame 320×256 + draw_sprites_common.
// HW vincolo M10K (41 disponibili, 160 richiesti per double-buffer full-frame) →
// architettura SCANLINE-BASED double-buffer (front/back).
//
// Pattern:
//   - 2 linebuf 512×12-bit per chip (front + back) = 4 M10K totali per 2 chip
//   - hbl_rise di linea N → scan 256 sprite per linea N+1
//   - Per ogni sprite, check intersezione scanline N+1 con bounding box
//     (ypos..ypos+16*(multi+1)-1). Se sì, fetch ROM per la row corretta e
//     draw 16 col nel linebuf back (x = sx..sx+15).
//   - Render area attiva: pxl* = linebuf_front[render_x]
//   - Swap front/back a fine scanline (lb_sel toggle).
//
// Output identico al MAME m_sprite_bitmap se scan ordinata correttamente.
// Race ELIMINATA per costruzione (scan scrive back, render legge front).
//
// MAME standard format (offs +0/+1/+2):
//   +0: efFbSssyyyyyyyyy  e=priority, f=flipy, F=flipx, b=flash, S=w, ss=h
//   +1: tttttttttttttttt  tile code
//   +2: ppcccccxxxxxxxxx  pp=priority, ccccc=color (5b), x=xpos
//
// Pen extraction (validato col tool sprite_viewer):
//   pen[3]=byte[3], pen[2]=byte[2], pen[1]=byte[1], pen[0]=byte[0]

module boogwings_sprites (
	input  wire        clk,
	input  wire        reset,

	// VRAM read port chip0/chip1
	output reg  [9:0]  sram0_addr,
	input  wire [15:0] sram0_data,
	output reg  [9:0]  sram1_addr,
	input  wire [15:0] sram1_data,

	// ROM read port chip0/chip1 (toggle protocol)
	output reg  [23:0] rom0_addr,
	output reg         rom0_req,
	input  wire [31:0] rom0_data,
	input  wire        rom0_valid,
	output reg  [23:0] rom1_addr,
	output reg         rom1_req,
	input  wire [31:0] rom1_data,
	input  wire        rom1_valid,

	// Video timing
	input  wire  [9:0] render_x,
	input  wire  [9:0] render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        flip_screen,

	// OSD toggles (decode permutations sprite_viewer-validated)
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,

	// === EXTRA spr permutation OSD (per BG sprite decoder debug) ===
	input  wire        osd_spr_msb_first,    // bit_x: 1=MSB first (7-pix), 0=LSB first (pix)
	input  wire        osd_spr_half_inv,     // scambia half logical (sx/dx)
	input  wire        osd_spr_half_eff_inv, // scambia half EFFETTIVO al fetch ROM
	input  wire        osd_spr_row_inv,      // 15 - row_in_tile (flip Y dentro tile)
	input  wire        osd_spr_plane_inv,    // bit-reverse del nibble pen (= reverse plane order)
	input  wire [1:0]  osd_spr_p0_src,       // da quale byte del fetch 32-bit pesca plane 0 (LSB nibble)
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire        osd_spr_w_swap_pos,          // w-mode: scambia posizione 1°/2° blocco
	input  wire        osd_spr_w_offset_first,      // w-mode: applica offset al 1° blocco (debug X assoluta)
	input  wire        osd_spr_w_code_swap,         // w-mode: swap code primo/secondo
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: offset X signed (step 16)

	// Pixel output (12-bit = {color[7:0], pen[3:0]})
	output wire [11:0] pxl0,
	output wire [11:0] pxl1
);

// flipscreen sprite — MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7))
// → SEMPRE invertito rispetto a flip_screen input (= tilemap flip).
// Default boogwing (DSW flip=Off, flip_screen=0): flipscreen_spr=1 → identity coord.
wire flipscreen_spr = ~flip_screen;

// ============================================================
// HBlank edge detect — trigger scan per scanline successiva
// ============================================================
reg hblank_d;
always @(posedge clk) hblank_d <= hblank_in;
wire hbl_rise = hblank_in & ~hblank_d;

// Go-latch: cattura hbl_rise anche se FSM è in mezzo a uno sprite.
// Senza latch, l'edge viene perso → scanline NON scansionata → render legge
// buffer vecchio → tile sprite "instabili" anche in pausa (= edge perso casualmente
// in funzione di quanto la scanline precedente era satura di sprite).
// Pattern copiato da deco16ic_jt pf*_go_latch.
reg       go_latch;
reg [9:0] latched_render_y;

// Frame parity per il FLASH sprite (MAME decospr.cpp:227: flag y_word[12], lo sprite
// e' nascosto sui frame DISPARI -> if(!(flash && (frame_number & 1))) draw). Toggle a
// ogni vblank rise = frame_number[0].
reg       vblank_in_d;
reg       frame_odd;
always @(posedge clk) begin
	if (reset) begin
		vblank_in_d <= 1'b0;
		frame_odd   <= 1'b0;
	end else begin
		vblank_in_d <= vblank_in;
		if (vblank_in & ~vblank_in_d) frame_odd <= ~frame_odd;  // 1 toggle per frame
	end
end

// ============================================================
// Linebuf 512×12-bit double-buffer per chip
// 2 M10K cad × 2 chip × 2 buf = 8 M10K totali
// ============================================================
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr0_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr0_b [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_b [0:511];

// lb_sel: 0 = render legge _a, scan scrive _b. 1 = inverso.
reg lb_sel;
reg lb_swap_pending;
reg scan_done;   // 1 quando scan corrente è completa, può togglare lb_sel

// Toggle lb_sel su hbl_rise se scan è completa (= back pronto)
always @(posedge clk) begin
	if (reset) begin
		lb_sel <= 1'b0;
		lb_swap_pending <= 1'b0;
	end else begin
		if (hbl_rise) begin
			lb_swap_pending <= 1'b1;
		end else if (scan_done && lb_swap_pending) begin
			lb_sel <= ~lb_sel;
			lb_swap_pending <= 1'b0;
		end
	end
end

// ============================================================
// Renderer read (gating ce_pix)
// ============================================================
// FIX clip-sx 2px: pipeline lookup linebuf SENZA gate ce_pix (= avanza ogni clk
// come fa BG deco16ic_jt). Con gate ce_pix=clk/14, 2 stage diventavano 2 PIXEL
// reali di ritardo rispetto a BG → primi 2 px sprite "cadevano fuori bordo sx".
reg [11:0] lb0_a_rd, lb0_b_rd, lb1_a_rd, lb1_b_rd;
reg        lb_sel_d;
always @(posedge clk) lb0_a_rd <= linebuf_spr0_a[render_x[8:0]];
always @(posedge clk) lb0_b_rd <= linebuf_spr0_b[render_x[8:0]];
always @(posedge clk) lb1_a_rd <= linebuf_spr1_a[render_x[8:0]];
always @(posedge clk) lb1_b_rd <= linebuf_spr1_b[render_x[8:0]];
always @(posedge clk) lb_sel_d <= lb_sel;

reg [11:0] pxl0_r, pxl1_r;
always @(posedge clk) pxl0_r <= (lb_sel_d == 1'b0) ? lb0_a_rd : lb0_b_rd;
always @(posedge clk) pxl1_r <= (lb_sel_d == 1'b0) ? lb1_a_rd : lb1_b_rd;

assign pxl0 = pxl0_r;
assign pxl1 = pxl1_r;

// ============================================================
// Linebuf write port (per chip): scan scrive nel buffer opposto a lb_sel
// ============================================================
reg [8:0]  lb_waddr;
reg [11:0] lb_wdata;
reg        lb_we0, lb_we1;

// Clear linebuf back all'inizio scan (clear_phase = 1)
reg clear_phase;
reg [9:0] clear_idx;

always @(posedge clk) if (lb_we0 && lb_sel == 1'b1) linebuf_spr0_a[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we0 && lb_sel == 1'b0) linebuf_spr0_b[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we1 && lb_sel == 1'b1) linebuf_spr1_a[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we1 && lb_sel == 1'b0) linebuf_spr1_b[lb_waddr] <= lb_wdata;

// ============================================================
// FSM scan: ad ogni hbl_rise, scan 256 sprite per linea N+1
// ============================================================
reg [4:0]  state;
reg [9:0]  scan_off;        // 0..1020 step 4
reg [15:0] data0, data1, data2;
reg [9:0]  scan_y;          // = render_y + 1 (scanline target)
reg signed [9:0] sx_anchor;
reg signed [9:0] sy_signed;
reg [15:0] code_base;
reg [7:0]  color;
reg        flipy, flipx;
reg [2:0]  multi;           // 0/1/3/7 → 1/2/4/8 tile alti
reg        w_mode;
reg        w_iter;
reg [3:0]  tile_idx;        // tile vertical idx (0..multi)
reg [3:0]  row_in_tile;     // row Y within tile (0..15)
reg [3:0]  pix_in_tile;     // pix X within half (0..7)
reg        half;            // 0=cols 0..7, 1=cols 8..15
reg [15:0] code_y;
reg [15:0] code_col_extra;
reg signed [9:0] sx_col;
reg        chip_idx;        // 0=chip0, 1=chip1

localparam [4:0]
	S_IDLE      = 5'd0,
	S_CLEAR     = 5'd1,
	S_W0        = 5'd2,
	S_W1        = 5'd3,
	S_W2        = 5'd4,
	S_W3        = 5'd15,  // BRAM read latency 1ck: stadio extra (pipeline 3-deep)
	S_CHECK     = 5'd5,
	S_FIND_ROW  = 5'd6,   // Calcola se sprite intersezione scanline + tile_idx + row_in_tile
	S_ROM_REQ   = 5'd7,
	S_ROM_WAIT  = 5'd8,
	S_DRAW      = 5'd9,
	S_NEXT_HALF = 5'd10,
	S_NEXT_W    = 5'd11,
	S_NEXT_SPR  = 5'd12,
	S_NEXT_CHIP = 5'd13,
	S_DONE      = 5'd14;

// go_latch always block — cattura hbl_rise anche se FSM non in S_IDLE.
// Senza latch, edge perso quando FSM ancora processando scanline N → scanline N+1
// non scansionata → render legge buffer vecchio = sprite instabili anche in pausa.
always @(posedge clk) begin
	if (reset) begin
		go_latch <= 1'b0;
		latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			go_latch <= 1'b1;
			latched_render_y <= render_y;
		end else if (state == S_IDLE && go_latch) begin
			go_latch <= 1'b0;
		end
	end
end

// MAME decospr.cpp:267-282 + 297-314 — formula completa boogwing con flipscreen=ON:
//
//   STEP 1 (riga 267-282): y = 240 - sign_ext_256(y_sram); x = 304 - sign_ext_320(x_sram)
//   STEP 2 (riga 297-304, flipscreen=ON): y = 240 - y  (doppia inversione = y_sram_signed)
//   STEP 3 (riga 306-314, flipscreen=ON): x = 304 - x  (doppia inversione = x_sram_signed)
//
// → Con flipscreen=ON (default boogwing): y_final = signed(y_sram), x_final = signed(x_sram).
// → Con flipscreen=OFF (DSW flip): y_final = 240 - signed(y_sram), x_final = 304 - signed(x_sram).
//
// MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7)) → default ON (flip[7]=0).
//
// Anche `mult` cambia: flipscreen=ON usa mult=+16 (tile crescono verso il basso),
// flipscreen=OFF usa mult=-16 (tile crescono verso l'alto). fx/fy si invertono.
function signed [9:0] sxy_decode_y(input [8:0] raw);
	// Solo sign-ext signed(y_sram). flip_screen applicato dopo nella FSM.
	begin
		sxy_decode_y = {{1{raw[8]}}, raw};
	end
endfunction

function signed [9:0] sxy_decode_x(input [8:0] raw);
	// Solo "sign-ext" con soglia 320 (MAME decospr.cpp:267-269):
	//   x = x & 0x1ff;            (9-bit 0..511)
	//   if (x >= 320) x -= 512;   (0..319 unsigned, 320..511 → -192..-1)
	// Risultato: signed -192..319 (10-bit signed sufficiente).
	// flip_screen applicato dopo nella FSM (304 - x se OFF, identity se ON).
	begin
		if (raw >= 9'd320)
			sxy_decode_x = $signed({1'b1, raw[8:0]});   // -192..-1
		else
			sxy_decode_x = {1'b0, raw};                  // 0..319
	end
endfunction

wire [15:0] sram_data_cur = chip_idx ? sram1_data : sram0_data;

// ROM permutations (validate via sprite_viewer)
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

wire [31:0] rom_data_cur  = chip_idx ? rom1_data : rom0_data;
wire        rom_valid_cur = chip_idx ? rom1_valid : rom0_valid;

wire [31:0] rom_swap = osd_spr_swap_hl ? {rom_data_cur[15:0], rom_data_cur[31:16]} : rom_data_cur;
wire [31:0] rom_bsab = osd_spr_bs_ab ?
	{rom_swap[23:16], rom_swap[31:24], rom_swap[7:0], rom_swap[15:8]} :
	rom_swap;
wire [31:0] rom_nibsw = osd_spr_nibsw ?
	{rom_bsab[27:24], rom_bsab[31:28], rom_bsab[19:16], rom_bsab[23:20],
	 rom_bsab[11:8],  rom_bsab[15:12], rom_bsab[3:0],   rom_bsab[7:4]} :
	rom_bsab;
wire [31:0] rom_perm = osd_spr_brev8 ?
	{brev8(rom_nibsw[31:24]), brev8(rom_nibsw[23:16]),
	 brev8(rom_nibsw[15:8]),  brev8(rom_nibsw[7:0])} :
	rom_nibsw;

// fx_eff = flipx ^ flipscreen_spr (MAME riga 306-313: flipscreen invertito m_flipallx=0)
wire fx_eff = flipx ^ flipscreen_spr;
// MSB-first vs LSB-first selection runtime (osd_spr_msb_first)
wire [2:0] bit_x_lsb = fx_eff ? pix_in_tile[2:0] : (3'd7 - pix_in_tile[2:0]);
wire [2:0] bit_x_msb = fx_eff ? (3'd7 - pix_in_tile[2:0]) : pix_in_tile[2:0];
wire [2:0] bit_x = osd_spr_msb_first ? bit_x_msb : bit_x_lsb;

// per-plane byte source selection: ogni plane sceglie da quale dei 4 byte del fetch 32-bit pescare.
// default boogwing: p0=byte0, p1=byte1, p2=byte2, p3=byte3 (= [0..7], [8..15], [16..23], [24..31])
function [4:0] byte_base(input [1:0] src);
	case (src)
		2'd0: byte_base = 5'd0;
		2'd1: byte_base = 5'd8;
		2'd2: byte_base = 5'd16;
		2'd3: byte_base = 5'd24;
	endcase
endfunction
wire p0_bit = rom_perm[byte_base(osd_spr_p0_src) + {2'd0, bit_x}];
wire p1_bit = rom_perm[byte_base(osd_spr_p1_src) + {2'd0, bit_x}];
wire p2_bit = rom_perm[byte_base(osd_spr_p2_src) + {2'd0, bit_x}];
wire p3_bit = rom_perm[byte_base(osd_spr_p3_src) + {2'd0, bit_x}];

// MAME planeoffset = {hi+8, hi+0, lo+8, lo+0} → plane 0 = byte 3 (mbd-05 alto),
// plane 1 = byte 2, plane 2 = byte 1, plane 3 = byte 0 (mbd-06 basso).
// FIX BUG #4: default pen = {p3, p2, p1, p0} (= reversed), verificato sim DIFF=0
// per tutti i tile testati (1..1000). Era {p0,p1,p2,p3} = sbagliato.
// OSD plane_inv ora flippa al inverso (= ripristina vecchia logica per regression).
wire [3:0] pen_raw = {p3_bit, p2_bit, p1_bit, p0_bit};
wire [3:0] draw_pen = osd_spr_plane_inv ? {pen_raw[0], pen_raw[1], pen_raw[2], pen_raw[3]} : pen_raw;

// ============================================================
// FSM
// ============================================================
always @(posedge clk) begin
	if (reset) begin
		state      <= S_IDLE;
		scan_off   <= 10'd0;
		lb_we0     <= 1'b0;
		lb_we1     <= 1'b0;
		rom0_req   <= 1'b0;
		rom1_req   <= 1'b0;
		sram0_addr <= 10'd0;
		sram1_addr <= 10'd0;
		chip_idx   <= 1'b0;
		clear_phase <= 1'b0;
		clear_idx  <= 10'd0;
		scan_done  <= 1'b0;
	end else begin
		lb_we0 <= 1'b0;
		lb_we1 <= 1'b0;

		case (state)
			S_IDLE: begin
				if (go_latch) begin
					// Inizio scan per scanline N+1 (latched_render_y catturato a hbl_rise)
					scan_y     <= latched_render_y + 10'd1;
					scan_off   <= 10'd0;
					chip_idx   <= 1'b0;
					clear_phase <= 1'b1;
					clear_idx  <= 10'd0;
					scan_done  <= 1'b0;
					state      <= S_CLEAR;
				end
			end

			S_CLEAR: begin
				// Clear linebuf back (entrambi i chip in parallelo)
				lb_we0   <= 1'b1;
				lb_we1   <= 1'b1;
				lb_waddr <= clear_idx[8:0];
				lb_wdata <= 12'h000;
				if (clear_idx == 10'd511) begin
					clear_phase <= 1'b0;
					state       <= S_W0;
				end else begin
					clear_idx <= clear_idx + 10'd1;
				end
			end

			// BRAM read latency 1 ck. Pipeline corretta:
			//   T0 (S_W0):  addr<=+0
			//   T1 (S_W1):  addr<=+1
			//   T2 (S_W2):  addr<=+2, data0<=sram[+0]
			//   T3 (S_W3):  data1<=sram[+1]
			//   T4 (S_CHECK): data2<=sram[+2], skip-check, decode
			S_W0: begin
				if (chip_idx) sram1_addr <= scan_off + 10'd0;
				else          sram0_addr <= scan_off + 10'd0;
				state <= S_W1;
			end
			S_W1: begin
				if (chip_idx) sram1_addr <= scan_off + 10'd1;
				else          sram0_addr <= scan_off + 10'd1;
				state <= S_W2;
			end
			S_W2: begin
				// data0 arriva qui (= y_word). Fast-skip: se Y fuori bounding box, skippa
				// subito senza leggere data1/data2. Risparmio 4 ck per ogni sprite invisibile.
				data0 <= sram_data_cur;
				if (chip_idx) sram1_addr <= scan_off + 10'd2;
				else          sram0_addr <= scan_off + 10'd2;
				begin : fast_skip
					reg signed [9:0] sy_pre;
					reg [2:0] multi_pre;
					reg [10:0] height;
					reg signed [10:0] dy_pre;
					reg signed [10:0] sy_top;
					sy_pre = sxy_decode_y(sram_data_cur[8:0]);
					case ({sram_data_cur[10], sram_data_cur[9]})
						2'd0: multi_pre = 3'd0;
						2'd1: multi_pre = 3'd1;
						2'd2: multi_pre = 3'd3;
						2'd3: multi_pre = 3'd7;
					endcase
					height = {7'd0, multi_pre, 4'b0} + 11'd16;
					// flipscreen_spr=1 (default boogwing): bounding [sy, sy+height)
					// flipscreen_spr=0: bounding [240-sy-height+1, 240-sy+16) — semplifico con margine ampio
					sy_top = flipscreen_spr ? $signed({sy_pre[9], sy_pre}) : 11'sd0;
					dy_pre = $signed({scan_y[9], scan_y}) - sy_top;
					// FLASH (MAME decospr.cpp:227): y_word[12]=flash. Lo sprite e' nascosto
					// sui frame DISPARI -> if(flash && frame_odd) NON disegnare = lampeggio.
					// Skip se data0=0 (entry vuota) OR flash&frame_odd OR dy fuori range.
					if (sram_data_cur == 16'd0) begin
						state <= S_NEXT_SPR;
					end else if (sram_data_cur[12] && frame_odd) begin
						state <= S_NEXT_SPR;   // flash: sprite spento su frame dispari
					end else if (flipscreen_spr && (dy_pre < 0 || dy_pre >= $signed({1'b0, height}))) begin
						state <= S_NEXT_SPR;
					end else begin
						state <= S_W3;
					end
				end
			end
			S_W3: begin
				data1 <= sram_data_cur;     // = sram[+1]
				state <= S_CHECK;
			end

			S_CHECK: begin
				data2 <= sram_data_cur;     // = sram[+2]
				// Skip-early: entry tutta zero
				if (data0 == 16'd0 && data1 == 16'd0 && sram_data_cur == 16'd0) begin
					state <= S_NEXT_SPR;
				end else begin
					flipy <= data0[14];
					flipx <= data0[13];
					w_mode<= data0[11];
					begin : decode_h
						reg [1:0] hbits;
						hbits = {data0[10], data0[9]};
						case (hbits)
							2'd0: multi <= 3'd0;
							2'd1: multi <= 3'd1;
							2'd2: multi <= 3'd3;
							2'd3: multi <= 3'd7;
						endcase
					end
					color     <= {data0[15], sram_data_cur[15:9]};
					code_base <= data1[15:0];
					w_iter    <= 1'b0;
					begin : decode_xy
						reg signed [9:0] sy_d;
						reg signed [9:0] sx_d;
						reg signed [9:0] anchor_base;
						reg signed [9:0] sx_first;
						sy_d = sxy_decode_y(data0[8:0]);
						sx_d = sxy_decode_x(sram_data_cur[8:0]);
						// flipscreen_spr applicato: se ON, identity (= sy_d, sx_d).
						// Se OFF, doppia inversione MAME (240-y, 304-x).
						// flipscreen_spr = ~flip_screen (MAME boogwing: set_flip_screen(!flip[7]))
						// Default boogwing: flip[7]=0 → flipscreen_spr=1 → identity.
						if (flipscreen_spr) begin
							sy_signed   <= sy_d;
							anchor_base = sx_d;
						end else begin
							sy_signed   <= $signed(10'sd240) - sy_d;
							anchor_base = $signed(10'sd304) - sx_d;
						end
						sx_anchor <= anchor_base;
						// w_swap_pos: 1° blocco in posizione "extra" (= anchor + flipsign*16 + offset)
						// offset_first (no swap): 1° blocco shiftato (= anchor + offset)
						if (osd_spr_w_swap_pos)
							sx_first = anchor_base
							           + (flipscreen_spr ? 10'sd16 : -10'sd16)
							           + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else if (osd_spr_w_offset_first)
							sx_first = anchor_base + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else
							sx_first = anchor_base;
						sx_col    <= sx_first;
					end
					state <= S_FIND_ROW;
				end
			end

			S_FIND_ROW: begin
				// MAME decospr.cpp:297-304:
				//   flipscreen OFF: mult = -16, tile cresce verso l'alto da sy
				//     → bounding box [sy - 16*multi, sy + 16)
				//     → dy_top = scan_y - (sy - 16*multi) = (scan_y - sy) + 16*multi
				//   flipscreen ON:  mult = +16, tile cresce verso il basso da sy
				//     → bounding box [sy, sy + 16*(multi+1))
				//     → dy_top = scan_y - sy
				// fy_eff = flipy ^ flipscreen_spr  (MAME riga 300: if (fy) fy=0; else fy=1)
				//
				// tile_idx = "posizione visiva del tile dentro lo sprite multi" (0=top).
				// = dy_u[6:4] SEMPRE (la flip di fy NON va qui, va sul code in S_ROM_REQ).
				// row_in_tile = riga Y dentro il tile, invertita se fy_eff (= row flip del tile).
				begin : isect_calc
					reg signed [10:0] dy_s;
					reg [10:0] dy_u;
					reg [10:0] height_total;
					reg signed [10:0] offset_top;
					offset_top = flipscreen_spr ? 11'sd0
					                            : $signed({{4{1'b0}}, multi, 4'b0});
					dy_s = ($signed({scan_y[9], scan_y}) - $signed({sy_signed[9], sy_signed}))
					     + offset_top;
					height_total = {7'd0, multi, 4'b0} + 11'd16;  // = 16*(multi+1)
					if (dy_s >= 11'sd0 && dy_s < $signed({1'b0, height_total})) begin
						dy_u = dy_s[10:0];
						tile_idx <= dy_u[6:4];   // 0..multi, NO fy inv
						// fy_eff row inversion
						if (flipy ^ flipscreen_spr)
							row_in_tile <= 4'd15 - dy_u[3:0];
						else
							row_in_tile <= dy_u[3:0];
						half        <= 1'b0;
						pix_in_tile <= 4'd0;
						state       <= S_ROM_REQ;
					end else begin
						// Sprite NON intersezione: skip
						state <= S_NEXT_W;
					end
				end
			end

			S_ROM_REQ: begin
				// FIX BUG #1: code_y, code_col_extra, code_sel calcolati BLOCKING per evitare
				// non-blocking dependency intra-ck (= leggere code_y prima dell'assegnazione
				// non-blocking → valore VECCHIO dello sprite/iter precedente).
				begin : compute_and_fetch
					reg [15:0] base_aligned;
					reg        fy_eff;
					reg [15:0] code_y_new;
					reg [15:0] code_col_extra_new;
					reg        half_use;
					reg [3:0]  row_use;
					reg [15:0] code_sel;

					fy_eff = flipy ^ flipscreen_spr;
					base_aligned = code_base & ~({13'd0, multi});
					code_y_new = fy_eff
					             ? (base_aligned + ({13'd0, multi} - {12'd0, tile_idx}))
					             : (base_aligned + {12'd0, tile_idx});
					code_col_extra_new = code_y_new - {13'd0, multi} - 16'd1;

					code_y         <= code_y_new;
					code_col_extra <= code_col_extra_new;

					// FIX flipx half-swap: quando fx_eff=1 (sprite specchiato), MAME inverte
					// anche l'ordine dei 2 half del tile (oltre al flip pixel-in-byte già
					// fatto da bit_x). Senza questo XOR, lo sprite specchiato mostra il
					// quadrante sx dove dovrebbe esserci il dx (e viceversa).
					half_use = (~half ^ fx_eff) ^ osd_spr_half_eff_inv;
					row_use  = osd_spr_row_inv ? (4'd15 - row_in_tile) : row_in_tile;
					code_sel = (w_iter ^ osd_spr_w_code_swap) ? code_col_extra_new : code_y_new;

					if (chip_idx) begin
						rom1_addr <= {2'd0, code_sel, half_use, row_use, 1'b0};
						rom1_req  <= 1'b1;
					end else begin
						rom0_addr <= {2'd0, code_sel, half_use, row_use, 1'b0};
						rom0_req  <= 1'b1;
					end
				end
				pix_in_tile <= 4'd0;
				state       <= S_ROM_WAIT;
			end

			S_ROM_WAIT: begin
				rom0_req <= 1'b0;
				rom1_req <= 1'b0;
				if (rom_valid_cur) state <= S_DRAW;
			end

			S_DRAW: begin
				// Calcola xpos del pixel corrente nella scanline
				begin : draw_block
					reg signed [10:0] xpos_s;
					reg signed [10:0] sx_ext;
					reg signed [10:0] pix_ext;
					sx_ext  = $signed({sx_col[9], sx_col});
					// half_inv: scambia col 0..7 con col 8..15 sullo schermo
					pix_ext = $signed({7'b0, half ^ osd_spr_half_inv, pix_in_tile[2:0]});
					xpos_s  = sx_ext + pix_ext;

					if (draw_pen != 4'd0
					    && xpos_s >= 11'sd0 && xpos_s < 11'sd320) begin
						lb_waddr <= xpos_s[8:0];
						lb_wdata <= {color, draw_pen};
						if (chip_idx) lb_we1 <= 1'b1;
						else          lb_we0 <= 1'b1;
					end
				end
				if (pix_in_tile == 3'd7) begin
					pix_in_tile <= 4'd0;
					if (~half) begin
						half  <= 1'b1;
						state <= S_ROM_REQ;
					end else begin
						state <= S_NEXT_HALF;
					end
				end else begin
					pix_in_tile <= pix_in_tile + 4'd1;
				end
			end

			S_NEXT_HALF: begin
				// 16 col disegnati per la row corrente del sprite. Vai a w_mode o next sprite.
				half <= 1'b0;
				state <= S_NEXT_W;
			end

			S_NEXT_W: begin
				if (w_mode && !w_iter) begin
					w_iter <= 1'b1;
					// FIX BUG #2: MAME decospr.cpp:351 → 2° blocco a (x+16) per flipscreen_spr=1,
					// (x-16) per flipscreen_spr=0. Era cablato a -16 fisso = INVERTITO per boogwing default.
					// OSD w_swap_pos: scambia 1°/2° blocco. OSD w_offset: offset extra signed.
					if (osd_spr_w_swap_pos)
						sx_col <= sx_anchor;
					else
						sx_col <= sx_anchor
						          + (flipscreen_spr ? 10'sd16 : -10'sd16)
						          + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
					half   <= 1'b0;
					pix_in_tile <= 4'd0;
					state  <= S_ROM_REQ;
				end else begin
					state <= S_NEXT_SPR;
				end
			end

			S_NEXT_SPR: begin
				if (scan_off >= 10'd1020) begin
					state <= S_NEXT_CHIP;
				end else begin
					scan_off <= scan_off + 10'd4;
					state    <= S_W0;
				end
			end

			S_NEXT_CHIP: begin
				if (chip_idx == 1'b0) begin
					chip_idx <= 1'b1;
					scan_off <= 10'd0;
					state    <= S_W0;
				end else begin
					state <= S_DONE;
				end
			end

			S_DONE: begin
				// Scan completa per scanline target. Marca pronto e aspetta prossimo hbl_rise.
				scan_done <= 1'b1;
				state     <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
