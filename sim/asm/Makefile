# Assemble the sample program with the Verilog assembler (needs iverilog).
#   make            -> program.hex
#   make DEFS=-DBENCH   slow_bit=0 so the program runs at full speed in simulation
DEFS ?=
program.hex: program_asm.v riscv_assembly.v
	iverilog $(DEFS) -o program_asm.out program_asm.v
	vvp program_asm.out
clean:
	rm -f program.hex program_asm.out
.PHONY: clean
