//=============================================================================
// This module implements the instruction execute state logic.
//
//  Copyright (C) 2014  Goran Devic
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//=============================================================================
module execute
(
    //----------------------------------------------------------
    // Control signals generated by the instruction execution
    //----------------------------------------------------------
    `include "exec_module.vh"

    output logic nextM,                 // Last M cycle of any instruction
    output logic setM1,                 // Last T clock of any instruction
    output logic fFetch,                // Function: opcode fetch cycle ("M1")
    output logic fMRead,                // Function: memory read cycle
    output logic fMWrite,               // Function: memory write cycle
    output logic fIORead,               // Function: IO Read cycle
    output logic fIOWrite,              // Function: IO Write cycle

    //----------------------------------------------------------
    // Inputs from the instruction decode PLA
    //----------------------------------------------------------
    input wire [104:0] pla,             // Statically decoded instructions

    //----------------------------------------------------------
    // Inputs from various blocks
    //----------------------------------------------------------
    input wire fpga_reset,              // Internal fpga test mode
    input wire nreset,                  // Internal reset signal
    input wire clk,                     // Internal clock signal
    input wire in_intr,                 // Servicing maskable interrupt
    input wire in_nmi,                  // Servicing non-maskable interrupt
    input wire in_halt,                 // Currently in HALT mode
    input wire im1,                     // Interrupt Mode 1
    input wire im2,                     // Interrupt Mode 2
    input wire use_ixiy,                // Special decode signal
    input wire flags_cond_true,         // Flags condition is true
    input wire repeat_en,               // Enable repeat of a block instruction
    input wire flags_zf,                // ZF to test a condition
    input wire flags_nf,                // NF to test for subtraction
    input wire flags_sf,                // SF to test for 8-bit sign of a value
    input wire flags_cf,                // CF to set HF for CCF

    //----------------------------------------------------------
    // Machine and clock cycles
    //----------------------------------------------------------
    input wire M1,                      // Machine cycle #1
    input wire M2,                      // Machine cycle #2
    input wire M3,                      // Machine cycle #3
    input wire M4,                      // Machine cycle #4
    input wire M5,                      // Machine cycle #5
    input wire M6,                      // Machine cycle #6
    input wire T1,                      // T-cycle #1
    input wire T2,                      // T-cycle #2
    input wire T3,                      // T-cycle #3
    input wire T4,                      // T-cycle #4
    input wire T5,                      // T-cycle #5
    input wire T6                       // T-cycle #6
);

// Detects unknown instructions by signalling the known ones
logic validPLA;                         // Valid PLA asserts this wire
// Activates a state machine to compute WZ=IX+d; takes 5T cycles
logic ixy_d;                            // Compute WX=IX+d
// Signals the setting of IX/IY and CB/ED prefix flags; inhibits clearing them
logic setIXIY;                          // Set IX/IY flag at the next T cycle
logic setCBED;                          // Set CB or ED flag at the next T cycle
// Holds asserted by non-repeating versions of block instructions (LDI/CPI,...)
logic nonRep;                           // Non-repeating block instruction
// Suspends incrementing PC through address latch unless in HALT or interrupt mode
logic pc_inc;                           // Normally defaults to 1

//----------------------------------------------------------
// Define various shortcuts to field naming
//----------------------------------------------------------
`define GP_REG_BC       2'h0
`define GP_REG_DE       2'h1
`define GP_REG_HL       2'h2
`define GP_REG_AF       2'h3

`define PFSEL_P         2'h0
`define PFSEL_V         2'h1
`define PFSEL_IFF2      2'h2
`define PFSEL_REP       2'h3

//----------------------------------------------------------
// Make available different sections of the opcode byte
//----------------------------------------------------------
wire op5;
wire op4;
wire op3;
wire op2;
wire op1;
wire op0;
assign op5 = pla[104];
assign op4 = pla[103];
assign op3 = pla[102];
assign op2 = pla[101];
assign op1 = pla[100];
assign op0 = pla[99];

wire [1:0] op54;
wire [1:0] op21;

assign op54 = { pla[104], pla[103] };
assign op21 = { pla[101], pla[100] };

//-----------------------------------------------------------
// 8-bit register selections needs to swizzle mux for A and F
//-----------------------------------------------------------
wire rsel3;
wire rsel0;
assign rsel3 = op3 ^ (op4 & op5);
assign rsel0 = op0 ^ (op1 & op2);

always_comb
begin
    //-------------------------------------------------------------------------
    // Default assignment of all control outputs to 0 to prevent generating
    // latches.
    //-------------------------------------------------------------------------
    `include "exec_zero.vh"

    // Reset internal control wires
    validPLA = 0;                       // Every valid PLA entry will set it
    nextM  = 0;                         // Set to advance to the next M cycle
    setM1  = 0;                         // Set on a last M/T cycle of an instruction

    // Reset global machine cycle functions
    fFetch = M1;                        // Fetch is simply always M1
    fMRead = 0; fMWrite = 0; fIORead = 0; fIOWrite = 0;
    ixy_d  = 0;
    setIXIY = 0;
    setCBED = 0;
    nonRep = 0;
    pc_inc = 1;

    //-------------------------------------------------------------------------
    // State-based signal assignment
    //-------------------------------------------------------------------------
    `include "exec_matrix.vh"

    // List more specific combinational signal assignments after the include
    //-------------------------------------------------------------------------
    // Reset control
    //-------------------------------------------------------------------------
    if (!nreset) begin
        // Clear the address latch, PC and IR registers
        ctl_inc_zero = 1;               // Force 0 to the output of incrementer
        ctl_inc_cy = 0;                 // Don't increment, pass-through
        ctl_al_we = 1;                  // Write 0 to the address latch
        setM1 = 1;                      // Arm to start executing at M1/T1
        nextM = 1;                      // Arm to start executing at M1/T1

        // Clear instruction opcode register
        ctl_bus_zero_oe = 1;            // Output 0 on the data bus section 0
        ctl_ir_we = 1;                  // And write it into the instruction register
    end

    //-------------------------------------------------------------------------
    // At M1/T4 advance an instruction if it did not trigger any PLA entry
    //-------------------------------------------------------------------------
    if (M1 && T4 && !validPLA) begin
        nextM = 1;                      // Complete the default M1 cycle
        setM1 = 1;                      // Set next M1 cycle
    end

    //-------------------------------------------------------------------------
    // The last cycle of an instruction is also the first cycle of the next one
    //-------------------------------------------------------------------------
    if (setM1) begin
        ctl_reg_sel_pc=1; ctl_reg_sys_hilo=2'b11;   // Select 16-bit PC
        ctl_al_we=1;                    // Write the PC into the address latch
    end
end

endmodule
