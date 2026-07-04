/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Based on the MiSTer Template by Sorgelig.
    BoogieWings core: Umberto Parisi (rmonc79).
*/

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM HPS pilotato direttamente dal game (modulo darius2_ddram dentro audio_top)
assign DDRAM_CLK = clk_sys;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (bit MiSTer pause built-in,
// indipendente dai bottoni in J1).
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle;     // solo joypad (bit 12 built-in MiSTer)
wire clean_pause = status[35]; // overlay off durante pausa (era bit 18, spostato per audio gain)
assign HDMI_FREEZE = 1'b0;  // overlay pause è renderizzato in real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
wire paused_safe;   // da boogwings_top: gata i contatori ce audio (gating frame-aligned)
// Savestate: valori di restore dei contatori ce (da boogwings_top) + pulse di load.
wire [3:0] ce_audio_cnt_load;
wire [4:0] ce_ym_cnt_load;
wire       ce_ym_toggle_load;
wire [6:0] ce_oki0_cnt_load;
wire [5:0] ce_oki1_cnt_load;
wire       ce_cnt_load_wr;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

// LED debug per verifica main loop CPU 68K:
//   LED_USER  = heartbeat (toggle ogni ~0.5 s se cycles incrementa)
//   LED_DISK  = {enable=1, ~vblank_irq_seen} (sticky a HIGH se VBLANK arriva)
// Heartbeat: derivato da bit alto di dbg_cpu_cycles → flicker se CPU avanza,
// ferma se CPU bloccata.
wire        dbg_cpu_active;
wire [23:0] dbg_cpu_pc;
wire [31:0] dbg_cpu_cycles;
wire        dbg_vblank_irq;
wire        dbg_prot_access;

reg vblank_irq_seen;
always @(posedge clk_sys) begin
	if (reset)               vblank_irq_seen <= 1'b0;
	else if (dbg_vblank_irq) vblank_irq_seen <= 1'b1;
end

reg prot_access_seen;
always @(posedge clk_sys) begin
	if (reset)                prot_access_seen <= 1'b0;
	else if (dbg_prot_access) prot_access_seen <= 1'b1;
end

assign LED_DISK  = {1'b1, ~vblank_irq_seen};
assign LED_POWER = {1'b1, ~prot_access_seen};
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
wire signed [9:0] osd_l0_xoff  = {{4{status[43]}}, status[43:38]};
wire signed [9:0] osd_l0_yoff  = {{4{status[49]}}, status[49:44]};
wire signed [9:0] osd_l1_xoff  = {{4{status[55]}}, status[55:50]};
wire signed [9:0] osd_l1_yoff  = {{4{status[61]}}, status[61:56]};
wire signed [9:0] osd_spr_xoff = {{4{status[67]}}, status[67:62]};
wire signed [9:0] osd_spr_yoff = {{4{status[73]}}, status[73:68]};
wire signed [9:0] osd_fg_xoff  = {{4{status[79]}}, status[79:74]};
wire signed [9:0] osd_fg_yoff  = {{4{status[85]}}, status[85:80]};

// ==== Layer enable OSD (esistenti) ====
// status[30] BG0 (chip0 pf1 = text), [31] BG1 (chip0 pf2), [32] sprite,
// [33] FG0 (chip1 pf1), [34] FG1 (chip1 pf2)
// OSD label "On,Off" → bit=0 = ON, bit=1 = OFF
wire layer_bg0_en = ~status[30];
wire layer_bg1_en = ~status[31];
wire layer_spr_en = ~status[32];
wire layer_fg0_en = ~status[33];
wire layer_fg1_en = ~status[34];

// Refresh rate selector (OSD status[22]): 0=nativo 57.8Hz (V_TOTAL=269),
// 1=60Hz (V_TOTAL=258) — accorcia il blanking verticale, ce_pix /14 invariato.
wire mode_60hz = status[22];

// BG0/BG1 toggle HARDCODED (valori HW-corretti, NO OSD).
wire osd_bg0_swap_hl = 1'b0;
wire osd_bg0_brev8   = 1'b1;
wire osd_bg0_nibsw   = 1'b0;
wire osd_bg0_bs_ab   = 1'b1;
wire osd_bg1_swap_hl = 1'b1;
wire osd_bg1_brev8   = 1'b1;
wire osd_bg1_nibsw   = 1'b0;
wire osd_bg1_bs_ab   = 1'b1;
// FG0 + FG1 HARDCODED (default, menu a riposo). NO OSD.
wire osd_fg0_swap_hl = 1'b1;
wire osd_fg0_brev8   = 1'b1;
wire osd_fg0_nibsw   = 1'b0;
wire osd_fg0_bs_ab   = 1'b1;
wire osd_fg1_swap_hl = 1'b1;
wire osd_fg1_brev8   = 1'b1;
wire osd_fg1_nibsw   = 1'b0;
wire osd_fg1_bs_ab   = 1'b1;
wire osd_spr_swap_hl = status[100];
wire osd_spr_brev8   = status[101];
wire osd_spr_nibsw   = status[102];
wire osd_spr_bs_ab   = status[103];
// === EXTRA sprite decode permutations — FISSATE a 0 (collidevano con FG Y offset status[80:84]) ===
wire osd_spr_msb_first    = 1'b0;
wire osd_spr_half_inv     = 1'b0;
wire osd_spr_half_eff_inv = 1'b0;
wire osd_spr_row_inv      = 1'b0;
wire osd_spr_plane_inv    = 1'b0;
// OSD diretto (NO XOR): cosa vedi in OSD = cosa applica RTL.
// Bug pre-fix: XOR con default → OSD "0,1,2,3" applicava in realtà "0,0,0,0"
// → tutti plane leggevano byte 0 → pen=0/0xF = sprite bianchi.
// Hardcoded ai valori HW-corretti (screenshot 2026-05-29): p0=B0,p1=B1,p2=B2,p3=B3
wire [1:0] osd_spr_p0_src = 2'd0;   // B0
wire [1:0] osd_spr_p1_src = 2'd1;   // B1
wire [1:0] osd_spr_p2_src = 2'd2;   // B2
wire [1:0] osd_spr_p3_src = 2'd3;   // B3
// Filtro chip sprite (debug): FISSATO 00 (collideva con osd_bg1_pal_base status[113:112]).
wire [1:0] osd_spr_chip_filter = 2'b00;
// w-mode: scambia posizione 1°/2° blocco (sx_anchor vs sx_anchor+offset)
wire osd_spr_w_swap_pos = status[118];
// w-mode: applica offset al PRIMO blocco invece che al secondo (per debug X assoluta)
wire osd_spr_w_offset_first = status[119];
// w-mode: scambia code primo/secondo blocco w
wire osd_spr_w_code_swap = status[120];
// w-mode: offset X secondo blocco signed (4-bit, step 16 = -128..+112 px). Default 0 = MAME -16.
wire signed [3:0] osd_spr_w_offset = status[127:124];
// BG1 p4 (plane 4) permutazioni runtime — path separato da osd_bg1_*.
// Lavorano sul byte mbd-02 prima del bit indexing in sc2_pen_p4.
// Default convalidati HW (2026-05-25): byte_pos=[7:0], brev8=ON, bit_shift=OFF.
// OSD invert (1'b1 ^ status[..]) per brev8 → default ON, l'OSD può ancora togglare per A/B test.
wire [1:0] osd_bg1_p4_byte_pos = status[97:96];  // 00=[7:0] 01=[15:8] 10=[23:16] 11=[31:24]
wire osd_bg1_p4_brev8     = 1'b1 ^ status[98];   // DEFAULT ON: bit-reverse byte p4
wire osd_bg1_p4_bit_shift = status[99];          // shift pix_y di 1 bit (test offset)


// ==== GFX Debug permutazioni (osd_gfx_*) RIMOSSE 2026-05-21 ====
/* Vedi git history per ripristinare se servisse di nuovo debug.
// possono di nuovo essere utili per indagare BG0/text che resta rotto.
wire [4:0] osd_tile_decode_mode = status[100:96];
wire       osd_pixel_bit_msb    = status[101];
wire       osd_plane_rev32      = status[102];
wire       osd_nibble_swap      = status[103];
wire       osd_byte_swap_ab     = status[104];
wire       osd_region_lohi_swap = status[105];
wire       osd_xhalf_inv        = status[106];
wire       osd_tile_hi_rev      = status[107];
wire [1:0] osd_vram_swizzle     = status[109:108];
wire [1:0] osd_bg0_pal_base     = status[111:110];
wire [1:0] osd_bg1_pal_base     = status[113:112];
wire [1:0] osd_bg2_pal_base     = status[115:114];
wire [1:0] osd_bg3_pal_base     = status[117:116];
*/

`include "build_id.v"
localparam CONF_STR = {
	"BoogieWings;SS3E000000:200000;",
	"-;",
	"O[93:92],Savestate Slot,1,2,3,4;",
	"R[94],Save state (Alt-F1);",
	"R[95],Restore state (F1);",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[21:19],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"P1O[22],Refresh Rate,Original 57.8Hz,60Hz;",
	"P1O[91:86],Analog VGA H-Shift,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63;",
	"P1O[25:23],Analog VGA V-Shift,0,1,2,3,4,5,6,7;",
	"-;",
	"O[35],Clean Pause,Off,On;",
	"-;",
	"O[30],Layer BG0,On,Off;",
	"O[31],Layer BG1,On,Off;",
	"O[32],Sprite,On,Off;",
	"O[33],Layer FG0,On,Off;",
	"O[34],Layer FG1,On,Off;",
	"-;",
	/* Layer Offsets: menu debug tuning offset layer — nascosto dall'OSD (bit status restano validi).
	"P2,Layer Offsets;",
	"P2O[43:38],BG0 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[49:44],BG0 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[55:50],BG1 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[61:56],BG1 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[79:74],FG X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[85:80],FG Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	*/
	"P3,Audio Mixer;",
	"P3O[10:7],FM (YM2151) gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[14:11],OKI0 (voci/SFX) gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[18:15],OKI1 (batteria) gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"-;",
	// Tile Perm menu rimosso dall'OSD (valori hardcoded HW-corretti). 2026-05-29.
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
// ioctl raw da hps_io → wrapper deco56_ioctl_decrypt → ioctl_* (decrittato).
// I consumatori (bridge/game) usano ioctl_* (output wrapper). Tile DECO56
// decrittate+rimappate in download; resto pass-through (2 ck latenza uniforme).
wire        ioctl_download_raw;
wire [15:0] ioctl_index_raw;
wire        ioctl_wr_raw;
wire [26:0] ioctl_addr_raw;
wire [15:0] ioctl_dout_raw;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait_sdram;
wire        ioctl_wait_audio;
// deco56/de102 sono COMBINATORI puri (remap inline, no buffer): hps_io fa il
// pacing naturale via ioctl_wait_sdram del bridge. Nessun wait extra.
wire        ioctl_wait = ioctl_wait_sdram | ioctl_wait_audio;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download_raw),
	.ioctl_index(ioctl_index_raw),
	.ioctl_wr(ioctl_wr_raw),
	.ioctl_addr(ioctl_addr_raw),
	.ioctl_dout(ioctl_dout_raw),
	.ioctl_wait(ioctl_wait)
);

// === Savestate UI: trigger save/load da tasti (Alt+F1-F4 / F1-F4), gamepad, OSD ===
wire        ss_save, ss_load;
wire [1:0]  ss_slot;
// Bit gamepad: uso SELECT (joy[13]) come "SS modifier" + direzioni; OSD via status R[124/125].
wire [15:0] joy_all = joy0 | joy1;
savestate_ui #(.INFO_TIMEOUT_BITS(25)) u_ss_ui (
	.clk         (clk_sys),
	.ps2_key     (ps2_key),
	.allow_ss    (1'b1),
	.joySS       (joy_all[13]),   // Select
	.joyRight    (joy_all[0]),
	.joyLeft     (joy_all[1]),
	.joyDown     (joy_all[2]),
	.joyUp       (joy_all[3]),
	.joyStart    (joy_all[12]),
	.joyRewind   (1'b0),
	.rewindEnable(1'b0),
	.status_slot (status[93:92]),
	.autoincslot (1'b0),
	.OSD_saveload(status[95:94]),  // R[94]=save, R[95]=restore
	.ss_save     (ss_save),
	.ss_load     (ss_load),
	.ss_info_req (),
	.ss_info     (),
	.statusUpdate(),
	.selected_slot(ss_slot)
);

// Cascata: hps_io(raw) → de102 (main 68K) → deco56 (tile) → ioctl_* (al bridge).
wire [26:0] ioctl_addr_m;
wire [15:0] ioctl_dout_m;
wire        ioctl_wr_m;
wire [15:0] ioctl_index_m;
wire        ioctl_download_m;

de102_ioctl_decrypt u_de102_dl (
	.clk               (clk_sys),
	.ioctl_addr_in     (ioctl_addr_raw),
	.ioctl_dout_in     (ioctl_dout_raw),
	.ioctl_wr_in       (ioctl_wr_raw),
	.ioctl_index_in    (ioctl_index_raw),
	.ioctl_download_in (ioctl_download_raw),
	.ioctl_addr_out    (ioctl_addr_m),
	.ioctl_dout_out    (ioctl_dout_m),
	.ioctl_wr_out      (ioctl_wr_m),
	.ioctl_index_out   (ioctl_index_m),
	.ioctl_download_out(ioctl_download_m)
);

deco56_ioctl_decrypt u_deco56_dl (
	.clk               (clk_sys),
	.ioctl_addr_in     (ioctl_addr_m),
	.ioctl_dout_in     (ioctl_dout_m),
	.ioctl_wr_in       (ioctl_wr_m),
	.ioctl_index_in    (ioctl_index_m),
	.ioctl_download_in (ioctl_download_m),
	.ioctl_addr_out    (ioctl_addr),
	.ioctl_dout_out    (ioctl_dout),
	.ioctl_wr_out      (ioctl_wr),
	.ioctl_index_out   (ioctl_index),
	.ioctl_download_out(ioctl_download)
);

// --- BoogieWings INPUT mapping (MAME boogwing.cpp:561-633 INPUT_PORTS_START) ---
// MiSTer joy bit layout (MiSTer convention):
//   [0]=Right, [1]=Left, [2]=Down, [3]=Up
//   [4]=A (FIRE/BTN1), [5]=B (BOMB/BTN2), [6]=X (SPECIAL/BTN3)
//   [10]=Start, [11]=Coin
//
// INPUTS port (MAME "INPUTS", 16-bit, tutto active LOW):
//   bit 0: P1 UP    bit 1: P1 DOWN  bit 2: P1 LEFT   bit 3: P1 RIGHT
//   bit 4: P1 BTN1  bit 5: P1 BTN2  bit 6: P1 BTN3   bit 7: P1 START
//   bit 8..15 idem P2
wire [15:0] inputs_port = {
	/* bit 15 */ ~joy1[10],   // P2 START
	/* bit 14 */ ~joy1[6],    // P2 BTN3
	/* bit 13 */ ~joy1[5],    // P2 BTN2
	/* bit 12 */ ~joy1[4],    // P2 BTN1
	/* bit 11 */ ~joy1[0],    // P2 RIGHT
	/* bit 10 */ ~joy1[1],    // P2 LEFT
	/* bit 9  */ ~joy1[2],    // P2 DOWN
	/* bit 8  */ ~joy1[3],    // P2 UP
	/* bit 7  */ ~joy0[10],   // P1 START
	/* bit 6  */ ~joy0[6],    // P1 BTN3
	/* bit 5  */ ~joy0[5],    // P1 BTN2
	/* bit 4  */ ~joy0[4],    // P1 BTN1
	/* bit 3  */ ~joy0[0],    // P1 RIGHT
	/* bit 2  */ ~joy0[1],    // P1 LEFT
	/* bit 1  */ ~joy0[2],    // P1 DOWN
	/* bit 0  */ ~joy0[3]     // P1 UP
};

// SYSTEM port (MAME "SYSTEM", 16-bit):
//   bit 0: COIN1     (active LOW)
//   bit 1: COIN2     (active LOW)
//   bit 2: SERVICE1  (active LOW)
//   bit 3: VBLANK    (active HIGH — da screen device)
//   bit 4..15: unused (idle HIGH)
wire [15:0] system_port = {
	12'hFFF,                  // bit 15..4 unused
	VBlank,                   // bit 3 VBLANK (active HIGH MAME → 1 quando in vblank)
	1'b1,                     // bit 2 SERVICE1 idle (no service button mapped yet)
	~joy1[11],                // bit 1 COIN2
	~joy0[11]                 // bit 0 COIN1
};

// DSW port — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dsw_port = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dsw_port <= ioctl_dout;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: tiene reset alto per ~2^17 cicli (~1.4ms a 96MHz) dopo che
// la causa cade, per dare tempo a SDRAM/clear FSM/PLL di stabilizzarsi.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // parte carico al power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // ricarica finche' c'e' causa
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
wire reset = (reset_hold_cnt != 17'd0);
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM (jtframe_sdram64, 4 banchi paralleli)  //
//
// Mapping banchi fisici:
//   ba0 = FG0  (chip1.pf1, BG2 alpha)  — fetch parallelo
//   ba1 = FG1  (chip1.pf2, BG2 base)   — fetch parallelo
//   ba2 = Main CPU 68K (op + data view)
//   ba3 = riservato/free
//
// Download via prog_*: il bridge seleziona prog_ba in base a ioctl_addr.
// BURSTLEN=64 (4 word per fetch), CAS=2, MISTER mode.
///////////////////////////////////////////////////////////////////////

localparam SDRAM_AW = 22;

// Per-bank request signals (driven by bridge)
wire [SDRAM_AW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [3:0]          ba_rd, ba_wr;
wire [15:0]         ba0_din, ba1_din, ba2_din, ba3_din;
wire [1:0]          ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [3:0]          ba_ack, ba_rdy, ba_dst, ba_dok;
wire [15:0]         sdram_dout_jt;

// Program (download) interface
wire                prog_en;
wire [SDRAM_AW-1:0] prog_addr;
wire [1:0]          prog_ba;
wire                prog_rd, prog_wr;
wire [15:0]         prog_din;
wire [1:0]          prog_dsn;
wire                prog_ack, prog_rdy, prog_dst, prog_dok;

// Refresh trigger: 1 pulse al cycle di HBlank rising edge basta — refresh module accumula debt.
reg vblank_d, hblank_d;
always @(posedge clk_sys) begin vblank_d <= VBlank; hblank_d <= HBlank; end
wire rfsh_pulse = (HBlank & ~hblank_d) | (VBlank & ~vblank_d);

// init signal (sdram_init / ready): jtframe driva `init` come output che resta alto durante init.
// Per compatibilita' col bridge che usa sdram_ready, deriviamo ready = ~init.
wire sdram_init_w;
wire sdram_ready = ~sdram_init_w;

jtframe_sdram64 #(
	.AW           ( SDRAM_AW ),
	.HF           ( 1        ),     // 96 MHz operation
	.SHIFTED      ( 0        ),
	.BA0_LEN      ( 16       ),     // single-word burst (1 word per fetch)
	.BA1_LEN      ( 16       ),
	.BA2_LEN      ( 16       ),
	.BA3_LEN      ( 16       ),
	.PROG_LEN     ( 16       ),     // program writes 1 word
	.MISTER       ( 1        ),
	.BA1_WEN      ( 0        ),
	.BA2_WEN      ( 0        ),
	.BA3_WEN      ( 0        ),
	.BA0_AUTOPRECH( 0        ),
	.BA1_AUTOPRECH( 0        ),
	.BA2_AUTOPRECH( 0        ),
	.BA3_AUTOPRECH( 0        )
) u_sdram_jt (
	.rst        ( ~pll_locked ),
	.clk        ( clk_sys     ),
	.init       ( sdram_init_w ),

	.ba0_addr   ( ba0_addr ),
	.ba1_addr   ( ba1_addr ),
	.ba2_addr   ( ba2_addr ),
	.ba3_addr   ( ba3_addr ),

	.rd         ( ba_rd    ),
	.wr         ( ba_wr    ),
	.ba0_din    ( ba0_din  ),
	.ba0_dsn    ( ba0_dsn  ),
	.ba1_din    ( ba1_din  ),
	.ba1_dsn    ( ba1_dsn  ),
	.ba2_din    ( ba2_din  ),
	.ba2_dsn    ( ba2_dsn  ),
	.ba3_din    ( ba3_din  ),
	.ba3_dsn    ( ba3_dsn  ),

	.rdy        ( ba_rdy ),
	.ack        ( ba_ack ),
	.dst        ( ba_dst ),
	.dok        ( ba_dok ),

	// Program (ROM-load) interface
	.prog_en    ( prog_en   ),
	.prog_addr  ( prog_addr ),
	.prog_ba    ( prog_ba   ),
	.prog_rd    ( prog_rd   ),
	.prog_wr    ( prog_wr   ),
	.prog_din   ( prog_din  ),
	.prog_dsn   ( prog_dsn  ),
	.prog_rdy   ( prog_rdy  ),
	.prog_dst   ( prog_dst  ),
	.prog_dok   ( prog_dok  ),
	.prog_ack   ( prog_ack  ),

	// SDRAM pins
	.sdram_dq   ( SDRAM_DQ   ),
	.sdram_a    ( SDRAM_A    ),
	.sdram_dqml ( SDRAM_DQML ),
	.sdram_dqmh ( SDRAM_DQMH ),
	.sdram_nwe  ( SDRAM_nWE  ),
	.sdram_ncas ( SDRAM_nCAS ),
	.sdram_nras ( SDRAM_nRAS ),
	.sdram_ncs  ( SDRAM_nCS  ),
	.sdram_ba   ( SDRAM_BA   ),
	.sdram_cke  ( SDRAM_CKE  ),

	// Shared read data bus
	.dout       ( sdram_dout_jt ),
	.rfsh       ( rfsh_pulse    )
);

// SDRAM_CLK driven via altddio_out (180° shift) — pattern identico a Sorgelig.
// La PLL attuale ha 1 solo outclk; il phase shift hardware del DDIO sostituisce
// l'outclk_1 dedicato.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sys),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Game ↔ bridge wiring (level protocol). BoogieWings non ha sub-68K → sub stubs tied 0.
wire [23:0] game_tile_addr, game_main_addr;
wire        game_tile_req, game_main_req;
wire [2:0]  game_tile_region_id;
wire [31:0] game_tile_data;
wire        game_tile_valid;
// Tile ROM port B (chip1 BG2): port 3 SDRAM dedicata.
wire [23:0] game_tile2_addr;
wire        game_tile2_req;
wire [2:0]  game_tile2_region_id;
wire [31:0] game_tile2_data;
wire        game_tile2_valid;
wire [15:0] game_main_data;
wire        game_main_ready;

// Main ROM instruction cache. In BYPASS_DECRYPT con dual-view fetch
// (op_view + data_view in SDRAM separate) il rom_cache singolo non
// può discriminare op/data → bypass diretto al bridge.
wire [23:0] bridge_main_addr;
wire        bridge_main_req;
wire [15:0] bridge_main_data;
wire        bridge_main_ready;
wire        game_main_is_opcode;
wire [1:0]  dbg_cache_state;

`ifdef BYPASS_DECRYPT
// Cache bypass: la CPU parla direttamente col bridge.
assign bridge_main_addr = game_main_addr;
assign bridge_main_req  = game_main_req;
assign game_main_data   = bridge_main_data;
assign game_main_ready  = bridge_main_ready;
assign dbg_cache_state  = 2'd0;
`else
rom_cache #(.CACHE_BITS(8)) u_main_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_main_addr), .cpu_req(game_main_req),
	.cpu_data(game_main_data), .cpu_ready(game_main_ready),
	.sdram_addr(bridge_main_addr), .sdram_req(bridge_main_req),
	.sdram_data(bridge_main_data), .sdram_ready(bridge_main_ready),
	.dbg_state(dbg_cache_state)
);
`endif

// =========================================================================
// Bridge — adattato a jtframe_sdram64 (4 banchi paralleli reali).
// Mapping:
//   FG0 (chip1.pf1)  → ba0 (interfaccia tile_fg0_*)
//   FG1 (chip1.pf2)  → ba1 (interfaccia tile_fg1_*)
//   Main 68K op+data → ba2 (interfaccia main_*)
//   Download         → prog_* (prog_ba selezionato per range ioctl)
// =========================================================================
// FG0 (chip1.pf1) e FG1 (chip1.pf2) cablati DIRETTI dal top al bridge — no arbiter.
wire [23:0] game_fg0_addr_w;
wire [2:0]  game_fg0_rid_w;
wire        game_fg0_req_w;
wire [31:0] game_fg0_data_w;
wire        game_fg0_valid_w;
wire [23:0] game_fg1_addr_w;
wire [2:0]  game_fg1_rid_w;
wire        game_fg1_req_w;
wire [31:0] game_fg1_data_w;
wire        game_fg1_valid_w;

// BG1 (chip0.pf2, 5bpp) — ba3 SDRAM con canale p4 dedicato
wire [23:0] game_bg1_addr_w;
wire        game_bg1_req_w;
wire [31:0] game_bg1_data_w;
wire        game_bg1_valid_w;
wire        game_bg1_p4_req_w;
wire  [7:0] game_bg1_p4_data_w;
wire        game_bg1_p4_valid_w;

// tilerom2_* (vecchio path arbiter) tied off — non più usato lato top
assign game_tile2_data  = 32'd0;
assign game_tile2_valid = 1'b0;

// NOTE: lasciamo le porte `tile_*` (chip0) idle — chip0 è su DDR3, niente SDRAM.

sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_sdram),

	// FG0 (chip1.pf1) — ba0
	.fg0_byte_addr  (game_fg0_addr_w),
	.fg0_region_id  (game_fg0_rid_w),
	.fg0_req        (game_fg0_req_w),
	.fg0_data       (game_fg0_data_w),
	.fg0_valid      (game_fg0_valid_w),

	// FG1 (chip1.pf2) — ba1
	.fg1_byte_addr  (game_fg1_addr_w),
	.fg1_region_id  (game_fg1_rid_w),
	.fg1_req        (game_fg1_req_w),
	.fg1_data       (game_fg1_data_w),
	.fg1_valid      (game_fg1_valid_w),

	// Main CPU 68K (op + data view) — ba2
	.main_byte_addr (bridge_main_addr),
	.main_is_opcode (game_main_is_opcode),
	.main_req       (bridge_main_req),
	.main_data      (bridge_main_data),
	.main_ready     (bridge_main_ready),

	// BG1 (chip0.pf2, 5bpp) — ba3
	.bg1_byte_addr  (game_bg1_addr_w),
	.bg1_req        (game_bg1_req_w),
	.bg1_p4_req     (game_bg1_p4_req_w),
	.bg1_data       (game_bg1_data_w),
	.bg1_valid      (game_bg1_valid_w),
	.bg1_p4_data    (game_bg1_p4_data_w),
	.bg1_p4_valid   (game_bg1_p4_valid_w),

	// jtframe_sdram64 per-bank interface (4 paralleli)
	.ba0_addr (ba0_addr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
	.ba1_addr (ba1_addr), .ba1_din(ba1_din), .ba1_dsn(ba1_dsn),
	.ba2_addr (ba2_addr), .ba2_din(ba2_din), .ba2_dsn(ba2_dsn),
	.ba3_addr (ba3_addr), .ba3_din(ba3_din), .ba3_dsn(ba3_dsn),
	.ba_rd    (ba_rd),
	.ba_wr    (ba_wr),
	.ba_ack   (ba_ack),
	.ba_rdy   (ba_rdy),
	.ba_dst   (ba_dst),
	.ba_dok   (ba_dok),
	.sdram_dout (sdram_dout_jt),

	// Program (download) interface
	.prog_en   (prog_en),
	.prog_addr (prog_addr),
	.prog_ba   (prog_ba),
	.prog_rd   (prog_rd),
	.prog_wr   (prog_wr),
	.prog_din  (prog_din),
	.prog_dsn  (prog_dsn),
	.prog_ack  (prog_ack),
	.prog_rdy  (prog_rdy),
	.prog_dst  (prog_dst),
	.prog_dok  (prog_dok),

	.dbg_main_pending   (dbg_main_pending),
	.dbg_download_active(dbg_download_active),
	.osd_region_lohi_swap(1'b0)
);

// Debug signals (nuovo bridge non esporta più dbg_peek)
wire        dbg_main_pending;
wire        dbg_download_active;

///////////////////////   GAME   ///////////////////////////////

// ce_pix: 96 MHz / 14 = 6.857 MHz, divisore INTERO (UNIFORME, no jitter).
// Refresh 57.8Hz ottenuto riducendo V_TOTAL (vcnt wrap), NON con accumulatore.
reg [3:0] ce_pix_cnt;
reg       ce_pix_r;
always @(posedge clk_sys) begin
	if (video_reset) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b0;
	end else if (ce_pix_cnt == 4'd13) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b1;
	end else begin
		ce_pix_cnt <= ce_pix_cnt + 4'd1;
		ce_pix_r   <= 1'b0;
	end
end
wire ce_pix = ce_pix_r;

// ce_audio: 96 MHz / 12 = 8 MHz (H6280 target = SOUND_XTAL/4 ≈ 8.055 MHz)
// NOTA: usa `reset` non `video_reset` per evitare glitch pitch quando pll_locked oscilla
reg [3:0] ce_audio_cnt;
reg       ce_audio_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_audio_cnt <= 4'd0;
		ce_audio_r   <= 1'b0;
	end else begin
		ce_audio_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_audio_cnt <= ce_audio_cnt_load;   // restore fase (trasparente: a SS spento load_wr=0)
		end else if (~paused_safe) begin
			if (ce_audio_cnt == 4'd11) begin
				ce_audio_cnt <= 4'd0;
				ce_audio_r   <= 1'b1;
			end else begin
				ce_audio_cnt <= ce_audio_cnt + 4'd1;
			end
		end
	end
end
wire ce_audio = ce_audio_r;

// ce_ym: 96 MHz / 27 ≈ 3.555 MHz (YM2151 target = SOUND_XTAL/9 ≈ 3.580 MHz)
// ce_ym_p1: half rate (= cen_p1 jt51)
reg [4:0] ce_ym_cnt;
reg       ce_ym_r, ce_ym_p1_r;
reg       ce_ym_toggle;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_ym_cnt    <= 5'd0;
		ce_ym_r      <= 1'b0;
		ce_ym_p1_r   <= 1'b0;
		ce_ym_toggle <= 1'b0;
	end else begin
		ce_ym_r    <= 1'b0;
		ce_ym_p1_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_ym_cnt    <= ce_ym_cnt_load;       // restore fase + toggle (half-rate jt51 cen_p1)
			ce_ym_toggle <= ce_ym_toggle_load;
		end else if (~paused_safe) begin
			if (ce_ym_cnt == 5'd26) begin
				ce_ym_cnt    <= 5'd0;
				ce_ym_r      <= 1'b1;
				ce_ym_p1_r   <= ce_ym_toggle;     // pulse 1/2 della volta di ce_ym
				ce_ym_toggle <= ~ce_ym_toggle;
			end else begin
				ce_ym_cnt <= ce_ym_cnt + 5'd1;
			end
		end
	end
end
wire ce_ym    = ce_ym_r;
wire ce_ym_p1 = ce_ym_p1_r;

// ce_oki0: 96 MHz / 95 ≈ 1.0105 MHz (OKI #0 target 1.0069 MHz, errore +0.36%)
reg [6:0] ce_oki0_cnt;
reg       ce_oki0_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_oki0_cnt <= 7'd0;
		ce_oki0_r   <= 1'b0;
	end else begin
		ce_oki0_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_oki0_cnt <= ce_oki0_cnt_load;     // restore fase
		end else if (~paused_safe) begin
			if (ce_oki0_cnt == 7'd94) begin
				ce_oki0_cnt <= 7'd0;
				ce_oki0_r   <= 1'b1;
			end else begin
				ce_oki0_cnt <= ce_oki0_cnt + 7'd1;
			end
		end
	end
end
wire ce_oki0 = ce_oki0_r;

// ce_oki1: 96 MHz / 48 = 2.000 MHz (OKI #1 target 2.0138 MHz, errore -0.69%)
reg [5:0] ce_oki1_cnt;
reg       ce_oki1_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_oki1_cnt <= 6'd0;
		ce_oki1_r   <= 1'b0;
	end else begin
		ce_oki1_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_oki1_cnt <= ce_oki1_cnt_load;     // restore fase
		end else if (~paused_safe) begin
			if (ce_oki1_cnt == 6'd47) begin
				ce_oki1_cnt <= 6'd0;
				ce_oki1_r   <= 1'b1;
			end else begin
				ce_oki1_cnt <= ce_oki1_cnt + 6'd1;
			end
		end
	end
end
wire ce_oki1 = ce_oki1_r;

// OSD audio gain decoder: 4 bit → gain 4.4 fixed point
// 0=Default 1=Mute 2=MAME 3=25% 4=50% 5=75% 6=100% 7=125% 8=150% 9=200%
// 10=250% 11=300% 12=400% 13=500% 14=700% 15=1000%
// % indicato è scaling rispetto al Default (= valore base per ogni chip).
function [11:0] osd_mul12;
	input [3:0] sel;
	case (sel)
		4'd0:  osd_mul12 = 12'd256;   // Default (placeholder, gestito sotto)
		4'd1:  osd_mul12 = 12'd0;     // Mute
		4'd2:  osd_mul12 = 12'd0;     // MAME (placeholder, gestito sotto)
		4'd3:  osd_mul12 = 12'd64;    // 25%  (= ×0.25)
		4'd4:  osd_mul12 = 12'd128;   // 50%
		4'd5:  osd_mul12 = 12'd192;   // 75%
		4'd6:  osd_mul12 = 12'd256;   // 100%
		4'd7:  osd_mul12 = 12'd320;   // 125%
		4'd8:  osd_mul12 = 12'd384;   // 150%
		4'd9:  osd_mul12 = 12'd512;   // 200%
		4'd10: osd_mul12 = 12'd640;   // 250%
		4'd11: osd_mul12 = 12'd768;   // 300%
		4'd12: osd_mul12 = 12'd1024;  // 400%
		4'd13: osd_mul12 = 12'd1280;  // 500%
		4'd14: osd_mul12 = 12'd1792;  // 700%
		4'd15: osd_mul12 = 12'd2560;  // 1000%
	endcase
endfunction
// Default HW-tested (= valori RTL applicati con foto utente OSD 200%/300%/400%):
//   FM=0x08 (0.5), OKI0=0xFF (15.94, =sat max), OKI1=0x80 (8.0)
// MAME esatti: FM=0x05 (0.32), OKI0=0x09 (0.56), OKI1=0x02 (0.12)
function [7:0] osd_gain;
	input [3:0] sel;
	input [7:0] def_g;
	input [7:0] mame_g;
	reg [19:0] scaled;   // def_g (8-bit) × mul12 (12-bit) → 20-bit
	begin
		case (sel)
			4'd0: osd_gain = def_g;
			4'd1: osd_gain = 8'h00;
			4'd2: osd_gain = mame_g;
			default: begin
				scaled = def_g * osd_mul12(sel);
				// >>8 = riportare scale (mul12 100% = 256). Satura a 8-bit.
				osd_gain = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
			end
		endcase
	end
endfunction
// OSD sel passati direttamente al chip audio (Default/MAME hardcoded dentro).
wire [3:0] osd_sel_fm   = status[10:7];
wire [3:0] osd_sel_oki0 = status[14:11];
wire [3:0] osd_sel_oki1 = status[18:15];

wire [9:0]  render_x;
wire [8:0]  render_y;

// BoogieWings top scheletro (Data East 1992)
//   M68K main + H6280 sound + 2× DECO16IC + 2× DECO_SPRITE + DECO_ACE +
//   DECO104 + YM2151 + 2× OKIM6295
wire [23:0] game_rgb;

boogwings_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),

	// Savestate trigger (da savestate_ui)
	.ss_save(ss_save),
	.ss_load(ss_load),
	.ss_slot(ss_slot),

	.inputs_port(inputs_port),
	.system_port(system_port),
	.dsw_port(dsw_port),

	// SDRAM ROM (via bridge)
	.main_rom_addr(game_main_addr),
	.main_rom_is_opcode(game_main_is_opcode),
	.main_rom_req(game_main_req),
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),
	.tilerom_addr(game_tile_addr),
	.tilerom_region_id(game_tile_region_id),
	.tilerom_req(game_tile_req),
	.tilerom_data(game_tile_data),
	.tilerom_valid(game_tile_valid),
	.tilerom2_addr(game_tile2_addr),
	.tilerom2_region_id(game_tile2_region_id),
	.tilerom2_req(game_tile2_req),
	.tilerom2_data(game_tile2_data),
	.tilerom2_valid(game_tile2_valid),

	// FG0/FG1 diretti — bypass arbiter, ognuno su porta SDRAM dedicata
	.tilerom_fg0_addr      (game_fg0_addr_w),
	.tilerom_fg0_region_id (game_fg0_rid_w),
	.tilerom_fg0_req       (game_fg0_req_w),
	.tilerom_fg0_data      (game_fg0_data_w),
	.tilerom_fg0_valid     (game_fg0_valid_w),
	.tilerom_fg1_addr      (game_fg1_addr_w),
	.tilerom_fg1_region_id (game_fg1_rid_w),
	.tilerom_fg1_req       (game_fg1_req_w),
	.tilerom_fg1_data      (game_fg1_data_w),
	.tilerom_fg1_valid     (game_fg1_valid_w),

	// BG1 chip0.pf2 5bpp → ba3 SDRAM, canale p4 dedicato (no tile_perm)
	.tilerom_bg1_addr      (game_bg1_addr_w),
	.tilerom_bg1_req       (game_bg1_req_w),
	.tilerom_bg1_data      (game_bg1_data_w),
	.tilerom_bg1_valid     (game_bg1_valid_w),
	.tilerom_bg1_p4_req    (game_bg1_p4_req_w),
	.tilerom_bg1_p4_data   (game_bg1_p4_data_w),
	.tilerom_bg1_p4_valid  (game_bg1_p4_valid_w),

	// ioctl download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_audio),

	// Video
	.render_x(render_x),
	.render_y({1'b0, render_y}),  // boogwings_top render_y è 10-bit
	.hblank_in(HBlank),
	.vblank_in(VBlank),
	.ce_pix(ce_pix),
	.ce_audio(ce_audio),
	.ce_ym(ce_ym),
	.ce_ym_p1(ce_ym_p1),
	.ce_oki0(ce_oki0),
	.ce_oki1(ce_oki1),
	// Savestate fase contatori ce: passa i valori (save) + ricevi i load (restore)
	.ce_audio_cnt_in(ce_audio_cnt),
	.ce_ym_cnt_in(ce_ym_cnt),
	.ce_ym_toggle_in(ce_ym_toggle),
	.ce_oki0_cnt_in(ce_oki0_cnt),
	.ce_oki1_cnt_in(ce_oki1_cnt),
	.ce_audio_cnt_load(ce_audio_cnt_load),
	.ce_ym_cnt_load(ce_ym_cnt_load),
	.ce_ym_toggle_load(ce_ym_toggle_load),
	.ce_oki0_cnt_load(ce_oki0_cnt_load),
	.ce_oki1_cnt_load(ce_oki1_cnt_load),
	.ce_cnt_load_wr(ce_cnt_load_wr),
	.osd_sel_fm  (osd_sel_fm),
	.osd_sel_oki0(osd_sel_oki0),
	.osd_sel_oki1(osd_sel_oki1),
	.rgb_out(game_rgb),

	// Layer enable OSD
	.layer_bg0_en(layer_bg0_en),
	.layer_bg1_en(layer_bg1_en),
	.layer_spr_en(layer_spr_en),
	.layer_fg0_en(layer_fg0_en),
	.layer_fg1_en(layer_fg1_en),

	// Tile permutation toggles (16 = 4 perm × 4 layer + sprite)
	.osd_bg0_swap_hl(osd_bg0_swap_hl),
	.osd_bg0_brev8  (osd_bg0_brev8),
	.osd_bg0_nibsw  (osd_bg0_nibsw),
	.osd_bg0_bs_ab  (osd_bg0_bs_ab),
	.osd_bg1_swap_hl(osd_bg1_swap_hl),
	.osd_bg1_brev8  (osd_bg1_brev8),
	.osd_bg1_nibsw  (osd_bg1_nibsw),
	.osd_bg1_bs_ab  (osd_bg1_bs_ab),
	.osd_fg0_swap_hl(osd_fg0_swap_hl),
	.osd_fg0_brev8  (osd_fg0_brev8),
	.osd_fg0_nibsw  (osd_fg0_nibsw),
	.osd_fg0_bs_ab  (osd_fg0_bs_ab),
	.osd_fg1_swap_hl(osd_fg1_swap_hl),
	.osd_fg1_brev8  (osd_fg1_brev8),
	.osd_fg1_nibsw  (osd_fg1_nibsw),
	.osd_fg1_bs_ab  (osd_fg1_bs_ab),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_chip_filter (osd_spr_chip_filter),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),

	// BG1 p4 (plane 4 mbd-02) permutation toggles
	.osd_bg1_p4_byte_pos (osd_bg1_p4_byte_pos),
	.osd_bg1_p4_brev8    (osd_bg1_p4_brev8),
	.osd_bg1_p4_bit_shift(osd_bg1_p4_bit_shift),

	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r),
	.paused_safe(paused_safe),

	// DDRAM HPS pins
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);

// Debug Z80 active (controlla LED_USER) — stubbed to 0 finché H6280 non c'è
wire        dbg_z80_active     = 1'b0;
// dbg_syt_z80_act è usato anche da LED_DISK (riga 158)
wire        dbg_syt_z80_act    = 1'b0;

///////////////////////   VIDEO   ///////////////////////////////

// BoogieWings video timing: 320×240 60Hz (boogwing.cpp:731: htot=442, hact=320, vtot=274, vact=240)
// Pixel clock: 96/14 = 6.857 MHz (divisore intero).
wire HBlank, VBlank, HSync, VSync;
wire [7:0] video_r, video_g, video_b;

// V_TOTAL: 269 (57.67Hz nativo) o 258 (60Hz). ce_pix /14 uniforme.
// Porch VERTICALI ricalcolati su V_TOTAL (pattern Raiden): area attiva FISSA
// (vcnt 8..247, 240 righe), VSync subito dopo con front porch fisso, BACK PORCH
// assorbe la differenza di V_TOTAL -> modeline sempre valida -> niente desync.
wire [9:0] V_TOTAL = mode_60hz ? 10'd258 : 10'd269;
wire [9:0] V_LAST  = V_TOTAL - 10'd1;
reg [9:0] hcnt, vcnt;
always @(posedge clk_sys) begin
	if (video_reset) begin
		hcnt <= 10'd0;
		vcnt <= 10'd0;
	end else if (ce_pix) begin
		if (hcnt == 10'd441) begin
			hcnt <= 10'd0;
			vcnt <= (vcnt == V_LAST) ? 10'd0 : vcnt + 10'd1;
		end else hcnt <= hcnt + 10'd1;
	end
end
assign render_x = hcnt;
assign render_y = vcnt[8:0] + 9'd1;   // tutta l'immagine su di 1px (nord)
assign HBlank = ~(hcnt < 10'd320);
assign VBlank = ~((vcnt >= 10'd8) && (vcnt < 10'd248));
assign HSync  = (hcnt >= 10'd340) && (hcnt < 10'd372);
// VSync: 2 righe DOPO fine attivo (vcnt 248), front porch = 2 righe, durata 3 righe.
// Posizione FISSA rispetto a fine-attivo (250..252), il back porch (253..V_LAST)
// assorbe la differenza di V_TOTAL -> sempre >= 5 righe a V_TOTAL 258, valido.
assign VSync  = (vcnt >= 10'd250) && (vcnt < 10'd253);

// RGB output: collego direttamente da boogwings_top.rgb_out (game_rgb è dichiarato sopra dell'istanza)
assign video_r = game_rgb[23:16];
assign video_g = game_rgb[15:8];
assign video_b = game_rgb[7:0];

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;

// ── Analog VGA H/V-Shift (solo uscita analogica, NON tocca HDMI) ─────────────
// Ritarda VGA_HS / VGA_VS rispetto al video: sposta SOLO il VGA analogico
// (l'HDMI scaler usa HSync/VSync propri, non ritardati). HSync/VSync interni
// restano invariati -> core e HDMI inalterati.
// H-Shift: ritardo in CE_PIX (1 step = 1 pixel), status[91:86] = 64 valori.
// V-Shift: ritardo in RIGHE (1 step = 1 riga = H_TOTAL ce_pix), status[25:23] = 8 valori.
//   (lo scostamento da correggere e' piccolo: bastano pochi step. Shift grande = errore.)
// Bit isolati: nessuna collisione con aspect[122:121]/scale[21:19] (bug BloodBros 121/122).
// Aumentando il valore l'immagine si sposta a destra (H) / in basso (V) sul CRT.

// H-Shift: shift register su HSync, granularita' 1 ce_pix.
reg [5:0]  osd_vga_hshift_d;
always @(posedge clk_sys) if (ce_pix) osd_vga_hshift_d <= status[91:86];
reg [62:0] hsync_shreg;
always @(posedge clk_sys) if (ce_pix) hsync_shreg <= {hsync_shreg[61:0], HSync};
reg vga_hs_reg;
always @(posedge clk_sys) if (ce_pix) vga_hs_reg <= (osd_vga_hshift_d == 6'd0) ? HSync : hsync_shreg[osd_vga_hshift_d - 6'd1];
assign VGA_HS = vga_hs_reg;

// V-Shift: ritarda VSync di N RIGHE. Lo VSync ritardato si genera campionando il
// VSync interno con un offset di righe: shift register di VSync clockato 1 volta
// per RIGA (su hcnt==441 & ce_pix), profondita' 7 righe.
wire line_tick = ce_pix && (hcnt == 10'd441);
reg [2:0] osd_vga_vshift_d;
always @(posedge clk_sys) if (line_tick) osd_vga_vshift_d <= status[25:23];
reg [6:0] vsync_line_shreg;
always @(posedge clk_sys) if (line_tick) vsync_line_shreg <= {vsync_line_shreg[5:0], VSync};
reg vga_vs_reg;
always @(posedge clk_sys) if (line_tick) vga_vs_reg <= (osd_vga_vshift_d == 3'd0) ? VSync : vsync_line_shreg[osd_vga_vshift_d - 3'd1];
assign VGA_VS = vga_vs_reg;

// MAME warning overlay: "DON'T BREAK YOUR WOOFER!" per ~3s su edge status[36]
reg vsync_d;
always @(posedge clk_sys) vsync_d <= VSync;
wire vblank_tick = VSync & ~vsync_d;  // 1 colpo per frame

wire mame_warn_on;
mame_warning_overlay u_mame_warn (
	.clk             (clk_sys),
	.reset           (video_reset),
	.tick            (vblank_tick),
	.mame_psg_active (status[36]),
	.render_x        (render_x),
	.render_y        (render_y),
	.text_on         (mame_warn_on)
);

wire [7:0] mame_r = mame_warn_on ? 8'hFF : video_r;
wire [7:0] mame_g = mame_warn_on ? 8'hFF : video_g;
wire [7:0] mame_b = mame_warn_on ? 8'h00 : video_b;

// VRAM debug overlay RIMOSSO 2026-05-21.
wire [7:0] vdbg_r = mame_r;
wire [7:0] vdbg_g = mame_g;
wire [7:0] vdbg_b = mame_b;

// Pause overlay: dim + logo + testo supporter durante pausa.
// Clean Pause (status[35]): se ON, overlay bypass (passthrough raw). Il modulo
// gata internamente overlay_on = pause & ~clean.
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (paused_safe),
	.clean     (clean_pause),
	.vblank    (VBlank),
	.render_x  (render_x),
	.render_y  (render_y),
	.rgb_r_in  (vdbg_r),
	.rgb_g_in  (vdbg_g),
	.rgb_b_in  (vdbg_b),
	.rgb_r_out (VGA_R),
	.rgb_g_out (VGA_G),
	.rgb_b_out (VGA_B)
);

// Aspect ratio: Original BoogieWings = 4:3 (single monitor), Full Screen = 0:0
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd3 : 12'd0;

// Integer scaling (Scale menu: Normal / V-Integer / Narrower HV-Integer)
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[21:19])   // bit alti liberi (4-6 erano vicini ai bit riservati). 0=Normal 1=V-Int 2=Narrower 3=Wider 4=HV-Integer
);

// LED_USER lampeggia se Z80 audio fa M1 fetch (boot OK).
// Se resta spento → Z80 non boota (ROM non in DDRAM o WAIT_n eterno).
assign LED_USER = dbg_z80_active;

// ============================================================
// JTAG Debug Probes (readable via quartus_stp / System Console)
// ============================================================
// JTAG boot trace removed to save M10K for 64KB work RAM

endmodule
