//
// PCILeech FPGA.
//
// Top module for the Enigma X1 Artix-7 board.
//
// (c) Ulf Frisk, 2019-2024
// Author: Ulf Frisk, pcileech@frizk.net
//


`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_enigma_x1_top #(
    parameter       PARAM_DEVICE_ID = 9,
    parameter       PARAM_VERSION_NUMBER_MAJOR = 4,
    parameter       PARAM_VERSION_NUMBER_MINOR = 14,
    parameter       PARAM_CUSTOM_VALUE = 32'hffffffff
) (
    // SYS
    input           clk,
    input           ft601_clk,
    
    // SYSTEM LEDs and BUTTONs
    output          user_ld1_n,
    output          user_ld2_n,
    input           user_sw1_n,
    input           user_sw2_n,
    
    // PCI-E FABRIC
    output  [0:0]   pcie_tx_p,
    output  [0:0]   pcie_tx_n,
    input   [0:0]   pcie_rx_p,
    input   [0:0]   pcie_rx_n,
    input           pcie_clk_p,
    input           pcie_clk_n,
    input           pcie_present,
    input           pcie_perst_n,
    output reg      pcie_wake_n = 1'b1,
    
    // TO/FROM FT601 PADS
    output          ft601_rst_n,
    
    inout   [31:0]  ft601_data,
    output  [3:0]   ft601_be,
    input           ft601_rxf_n,
    input           ft601_txe_n,
    output          ft601_wr_n,
    output          ft601_siwu_n,
    output          ft601_rd_n,
    output          ft601_oe_n
    );
    
    // SYS
    wire            rst;
    
    // FIFO CTL <--> COM CTL
    wire [63:0]     com_dout;
    wire            com_dout_valid;
    wire [255:0]    com_din;
    wire            com_din_wr_en;
    wire            com_din_ready;
    wire            led_com;
    wire            led_pcie;
    
    // FIFO CTL <--> COM CTL
    IfComToFifo     dcom_fifo();
	
    // FIFO CTL <--> PCIe
    IfPCIeFifoCfg   dcfg();
    IfPCIeFifoTlp   dtlp();
    IfPCIeFifoCore  dpcie();
    IfShadow2Fifo   dshadow2fifo();
	
    // ----------------------------------------------------
    // TickCount64 CLK
    // ----------------------------------------------------

    time tickcount64 = 0;
    time tickcount64_reload = 0;
    always @ ( posedge clk ) begin
        tickcount64         <= user_sw2_n ? (tickcount64 + 1) : 0;
        tickcount64_reload  <= user_sw2_n ? 0 : (tickcount64_reload + 1);
    end

    assign rst = ~user_sw2_n || ((tickcount64 < 64) ? 1'b1 : 1'b0);
    assign ft601_rst_n = ~rst;
    wire led_pwronblink = ~user_sw1_n ^ (tickcount64[24] & (tickcount64[63:27] == 0));
    
    OBUF led_ld1_obuf(.O(user_ld1_n), .I(~led_pcie));
    OBUF led_ld2_obuf(.O(user_ld2_n), .I(~led_com));
    
    // ----------------------------------------------------
    // BUFFERED COMMUNICATION DEVICE (FT601)
    // ----------------------------------------------------
    
    pcileech_com i_pcileech_com (
        // SYS
        .clk                ( clk                   ),
        .clk_com            ( ft601_clk             ),
        .rst                ( rst                   ),
        .led_state_txdata   ( led_com               ),  // ->
        .led_state_invert   ( led_pwronblink        ),  // <-
        // FIFO CTL <--> COM CTL
        .dfifo              ( dcom_fifo.mp_com      ),
        // TO/FROM FT601 PADS
        .ft601_data         ( ft601_data            ),  // <> [31:0]
        .ft601_be           ( ft601_be              ),  // -> [3:0]
        .ft601_txe_n        ( ft601_txe_n           ),  // <-
        .ft601_rxf_n        ( ft601_rxf_n           ),  // <-
        .ft601_siwu_n       ( ft601_siwu_n          ),  // ->
        .ft601_wr_n         ( ft601_wr_n            ),  // ->
        .ft601_rd_n         ( ft601_rd_n            ),  // ->
        .ft601_oe_n         ( ft601_oe_n            )   // ->
    );
    
    // ----------------------------------------------------
    // FIFO CTL
    // ----------------------------------------------------
    
    pcileech_fifo #(
        .PARAM_DEVICE_ID            ( PARAM_DEVICE_ID               ),
        .PARAM_VERSION_NUMBER_MAJOR ( PARAM_VERSION_NUMBER_MAJOR    ),
        .PARAM_VERSION_NUMBER_MINOR ( PARAM_VERSION_NUMBER_MINOR    ),
        .PARAM_CUSTOM_VALUE         ( PARAM_CUSTOM_VALUE            )
    ) i_pcileech_fifo (
        .clk                ( clk                   ),
        .rst                ( rst                   ),
        .rst_cfg_reload     ( (tickcount64_reload > 500000000) ? 1'b1 : 1'b0 ),     // config reload after 5s button press
        .pcie_present       ( pcie_present          ),
        .pcie_perst_n       ( pcie_perst_n          ),
        // FIFO CTL <--> COM CTL
        .dcom               ( dcom_fifo.mp_fifo     ),
        // FIFO CTL <--> PCIe
        .dcfg               ( dcfg.mp_fifo          ),
        .dtlp               ( dtlp.mp_fifo          ),
        .dpcie              ( dpcie.mp_fifo         ),
        .dshadow2fifo       ( dshadow2fifo.fifo     )
    );
    
    // ----------------------------------------------------
    // IOMMU/VT-d Support for Intel Audio Controller
    // ----------------------------------------------------
    
    wire [63:0] dma_addr_translated;
    wire        dma_addr_valid;
    wire        iommu_enabled = 1'b1; // Always assume VT-d is enabled
    wire [15:0] domain_id = 16'h0001; // Audio domain
    
    intel_audio_iommu_support i_iommu_support(
        .clk                ( clk                   ),
        .rst                ( rst                   ),
        // DMA Request Interface
        .dma_addr_in        ( 64'h0                 ), // Will be connected to actual DMA
        .dma_size           ( 32'h1000              ), // 4KB typical audio buffer
        .dma_req_valid      ( 1'b0                  ), // Will be connected
        .dma_addr_out       ( dma_addr_translated   ),
        .dma_addr_valid     ( dma_addr_valid        ),
        // IOMMU Status
        .iommu_enabled      ( iommu_enabled         ),
        .domain_id          ( domain_id             ),
        // ATS Interface
        .ats_request_addr   ( 64'h0                 ),
        .ats_request_valid  ( 1'b0                  ),
        .ats_response_addr  (                       ),
        .ats_response_valid (                       ),
        // PRI Interface
        .pri_page_addr      (                       ),
        .pri_request_id     (                       ),
        .pri_request_valid  (                       ),
        .pri_response_ready ( 1'b1                  )
    );
    
    // ----------------------------------------------------
    // Intel 13th Generation Security Compatibility
    // ----------------------------------------------------
    
    wire [31:0] security_response;
    wire        security_valid;
    wire        cet_compatible;
    wire        tdx_attestation_valid;
    wire        mpx_compatible;
    wire        stack_protection_valid;
    
    intel_13gen_security_compat i_13gen_security(
        .clk                        ( clk                       ),
        .rst                        ( rst                       ),
        // PCIe Security Interface
        .pcie_security_request      ( 32'h80861E20              ), // Intel Audio signature
        .pcie_security_response     ( security_response         ),
        .security_valid             ( security_valid            ),
        // CET Support
        .cet_enabled                ( 1'b1                      ), // Assume CET enabled on 13th gen
        .cet_shadow_stack_ptr       (                           ),
        .cet_compatible             ( cet_compatible            ),
        // TDX Support
        .tdx_enabled                ( 1'b1                      ), // Assume TDX enabled on 13th gen
        .td_uuid                    ( 64'h80861E20DEADBEEF      ),
        .tdx_attestation_valid      ( tdx_attestation_valid     ),
        // MPX Support
        .mpx_enabled                ( 1'b1                      ), // Assume MPX enabled
        .mpx_bounds_table_ptr       (                           ),
        .mpx_compatible             ( mpx_compatible            ),
        // Stack Protection
        .stack_protection_enabled   ( 1'b1                      ), // Hardware stack protection
        .stack_canary_value         (                           ),
        .stack_protection_valid     ( stack_protection_valid   )
    );
    
    // ----------------------------------------------------
    // Adaptive Anti-Detection System (최종 보안 계층)
    // ----------------------------------------------------
    
    wire [2:0]  threat_level;
    wire [3:0]  stealth_mode;
    wire [31:0] behavior_mutation;
    wire        emergency_mode;
    wire [15:0] audio_response_delay;
    wire [7:0]  register_access_pattern;
    wire [31:0] interrupt_timing_mask;
    wire        dma_throttle_enable;
    
    adaptive_anti_detection i_adaptive_security(
        .clk                        ( clk                       ),
        .rst                        ( rst                       ),
        // Threat Detection Interface
        .system_activity_pattern    ( tickcount64[31:0]         ), // Use tickcount as activity indicator
        .memory_scan_frequency      ( tickcount64[47:32]        ), // Monitor memory access patterns
        .pcie_probe_count           ( tickcount64[39:32]        ), // PCIe access monitoring
        .anticheat_signature_detected( 1'b0                     ), // Will be connected to detection logic
        // Adaptive Response Interface
        .threat_level               ( threat_level              ),
        .stealth_mode               ( stealth_mode              ),
        .behavior_mutation          ( behavior_mutation         ),
        .emergency_mode             ( emergency_mode            ),
        // Audio Controller Behavior Modification
        .audio_response_delay       ( audio_response_delay      ),
        .register_access_pattern    ( register_access_pattern   ),
        .interrupt_timing_mask      ( interrupt_timing_mask     ),
        .dma_throttle_enable        ( dma_throttle_enable       )
    );
    
    // ----------------------------------------------------
    // PCIe
    // ----------------------------------------------------
    pcileech_pcie_a7 i_pcileech_pcie_a7(
        .clk_sys            ( clk                   ),
        .rst                ( rst                   ),
        // PCIe fabric
        .pcie_tx_p          ( pcie_tx_p             ),
        .pcie_tx_n          ( pcie_tx_n             ),
        .pcie_rx_p          ( pcie_rx_p             ),
        .pcie_rx_n          ( pcie_rx_n             ),
        .pcie_clk_p         ( pcie_clk_p            ),
        .pcie_clk_n         ( pcie_clk_n            ),
        .pcie_perst_n       ( pcie_perst_n          ),
        // State and Activity LEDs
        .led_state          ( led_pcie              ),
        // FIFO CTL <--> PCIe
        .dfifo_cfg          ( dcfg.mp_pcie          ),
        .dfifo_tlp          ( dtlp.mp_pcie          ),
        .dfifo_pcie         ( dpcie.mp_pcie         ),
        .dshadow2fifo       ( dshadow2fifo.shadow   )
    );

endmodule

