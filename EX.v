`include "lib/defines.vh"
module EX(
    input wire clk,
    input wire rst,
    // input wire flush,
    input wire [`StallBus-1:0] stall,

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,

    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,

    output wire [`EX_TO_RF_WD-1:0] ex_to_rf_bus,

    output wire data_sram_en,
    output wire [3:0] data_sram_wen,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata
);

    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r;

    always @ (posedge clk) begin
        if (rst) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        // else if (flush) begin
        //     id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        // end
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`NoStop) begin
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end

    wire [31:0] ex_pc, inst;
    wire [11:0] alu_op;
    wire [2:0] sel_alu_src1;
    wire [3:0] sel_alu_src2;
    wire data_ram_en;
    wire data_ram_wen;
    wire [3:0] data_ram_sel;
    wire rf_we;
    wire [4:0] rf_waddr;
    wire sel_rf_res;
    wire [31:0] rf_rdata1, rf_rdata2;
    reg is_in_delayslot;
    wire [31:0] hi_i, lo_i;
    wire [7:0] hilo_op;
    wire [7:0] mem_op;

    assign {
        mem_op,         // 235:228
        hilo_op,        // 227:220
        hi_i, lo_i,     // 219:156
        ex_pc,          // 155:124
        inst,           // 123:92
        alu_op,         // 91:80 
        sel_alu_src1,   // 79:77
        sel_alu_src2,   // 76:73
        data_ram_en,    // 72
        data_ram_wen,   // 71
        rf_we,          // 70
        rf_waddr,       // 69:65
        sel_rf_res,     // 64
        rf_rdata1,      // 63:32
        rf_rdata2       // 31:0
    } = id_to_ex_bus_r;

// alu
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]};
    assign imm_zero_extend = {16'b0, inst[15:0]};
    assign sa_zero_extend = {27'b0,inst[10:6]};

    wire [31:0] alu_src1, alu_src2;
    wire [31:0] alu_result, ex_result;

    assign alu_src1 = sel_alu_src1[1] ? ex_pc :
                      sel_alu_src1[2] ? sa_zero_extend : rf_rdata1;

    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend :
                      sel_alu_src2[2] ? 32'd8 :
                      sel_alu_src2[3] ? imm_zero_extend : rf_rdata2;
    
    alu u_alu(
    	.alu_control (alu_op ),
        .alu_src1    (alu_src1    ),
        .alu_src2    (alu_src2    ),
        .alu_result  (alu_result  )
    );

// mul & div
    wire inst_mfhi, inst_mflo, inst_mthi, inst_mtlo,
         inst_mult, inst_multu, inst_div, inst_divu;
    
    wire hi_we, lo_we;
    wire [31:0] hi_o, lo_o;
    wire [`HILO_WD-1:0] hilo_bus;

    wire sign_flag;
    wire [31:0] div_result, mod_result;
    wire [63:0] mult_result, multu_result;

    wire [31:0] md_src1, md_src2;

    assign {
        inst_mfhi, inst_mflo, inst_mthi, inst_mtlo,
        inst_mult, inst_multu, inst_div, inst_divu
    } = hilo_op;

    assign sign_flag = rf_rdata1[31]^rf_rdata2[31];
    assign md_src1 = inst_div | inst_mult ? (rf_rdata1[31] ? {1'b0,~rf_rdata1[30:0]}+1'b1 : rf_rdata1)
                   : inst_divu | inst_multu ? rf_rdata1
                   : 32'b1;
    assign md_src2 = inst_div | inst_mult ? (rf_rdata2[31] ? {1'b0,~rf_rdata2[30:0]}+1'b1 : rf_rdata2)
                   : inst_divu | inst_multu ? rf_rdata2
                   : 32'b1;

    assign div_result = md_src1 / md_src2;
    assign mod_result = md_src1 % md_src2;
    assign multu_result = md_src1 * md_src2;
    assign mult_result = sign_flag ? {sign_flag,~multu_result[62:0]}+1'b1 : {sign_flag,multu_result[62:0]};

    assign hi_we = inst_div | inst_divu | inst_mult | inst_multu | inst_mthi;
    assign lo_we = inst_div | inst_divu | inst_mult | inst_multu | inst_mtlo;

    assign hi_o = inst_mthi ? rf_rdata1 :
                  inst_div ? (rf_rdata1[31] ? {rf_rdata1[31],~mod_result[30:0]}+1'b1 : {rf_rdata1[31],mod_result[30:0]}) :
                  inst_divu ? mod_result :
                  inst_mult ? mult_result[63:32] :
                  inst_multu ? multu_result[63:32] :
                  32'b0;
    assign lo_o = inst_mtlo ? rf_rdata1 :
                  inst_div ? (sign_flag ? {sign_flag,~div_result[30:0]}+1'b1 : {sign_flag,div_result[30:0]}):
                  inst_divu ? div_result :
                  inst_mult ? mult_result[31:0] :
                  inst_multu ? multu_result[31:0] :
                  32'b0;

    assign hilo_bus = {
        hi_we, hi_o,
        lo_we, lo_o
    };

// load & store  
    wire inst_lb,   inst_lbu,   inst_lh,    inst_lhu,   inst_lw;
    wire inst_sb,   inst_sh,    inst_sw;

    wire [3:0] byte_sel;

    assign {
        inst_lb, inst_lbu, inst_lh, inst_lhu, 
        inst_lw, inst_sb, inst_sh, inst_sw
    } = mem_op;

    decoder_2_4 u_decoder_2_4(
    	.in  (ex_result[1:0]),
        .out (byte_sel      )
    );

    assign data_ram_sel = inst_sb | inst_lb | inst_lbu ? byte_sel :
                          inst_sh | inst_lh | inst_lhu ? {{2{byte_sel[2]}},{2{byte_sel[0]}}} :
                          inst_sw | inst_lw ? 4'b1111 : 4'b0000;

    assign data_sram_en     = data_ram_en;
    assign data_sram_wen    = {4{data_ram_wen}}&data_ram_sel;
    assign data_sram_addr   = ex_result;
    assign data_sram_wdata  = inst_sb ? {4{rf_rdata2[7:0]}} :
                              inst_sh ? {2{rf_rdata2[15:0]}} :
                            /*inst_sw*/ rf_rdata2;


// output

    assign ex_result = inst_mflo ? lo_i 
                     : inst_mfhi ? hi_i
                     : alu_result;

    assign ex_to_mem_bus = {
        mem_op,         // 150:143
        hilo_bus,       // 142:77
        ex_pc,          // 76:45
        data_ram_en,    // 44
        data_ram_wen,   // 43
        data_ram_sel,   // 42:39
        sel_rf_res,     // 38
        rf_we,          // 37
        rf_waddr,       // 36:32
        ex_result       // 31:0
    };

    assign ex_to_rf_bus = {
        hilo_bus,
        rf_we,
        rf_waddr,
        ex_result
    };
    
    
    
endmodule