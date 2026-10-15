# Repository gates. Run `make lint` before every commit (the pre-commit hook
# does, after `git config core.hooksPath scripts/hooks`) and `make check`
# before pushing or closing a ticket.
#
#   make lint          seconds: by-products, stale paths, line length (no tools needed)
#   make check         minutes: firmware reproducibility, xsim regression, Vivado synthesis
#   make -j2 check     same, regression and synthesis in parallel
#   make check-moves BASE=<rev>   every file moved since <rev> is a 100 % rename
#
# check needs riscv64-unknown-elf-gcc on PATH and Vivado's settings64.sh sourced.

VIVADO ?= vivado
BUILD   = build

.PHONY: lint check check-fw check-sim check-synth check-moves

lint:
	scripts/lint.sh

check: check-sim check-synth

# The firmware check deletes and regenerates rtl/firmware.hex, so the gates
# that read the image wait for it.
check-fw:
	$(MAKE) --no-print-directory -C fw check

check-sim: check-fw
	sim/run_regression.sh

check-synth: check-fw
	$(VIVADO) -mode batch -nojournal -nolog -source vivado/build.tcl -tclargs $(BUILD)/vivado synth

check-moves:
	scripts/lint.sh --moves $(BASE)
