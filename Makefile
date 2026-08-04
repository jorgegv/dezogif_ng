# Makefile — dezogif_ng
#
# `make` with no target lists every target that has a `#` comment on the line
# immediately above it. Target names print in bold red.

.DEFAULT_GOAL := help
.PHONY: help all main unit-tests mf-rom mfselect test test-mfselect test-esp test-dzrp check-reproducible clean

# Show this help
help:
	@if [ -t 1 ] && [ -z "$$NO_COLOR" ]; then c='\033[1;31m'; r='\033[0m'; else c=; r=; fi; \
	awk -v c="$$c" -v r="$$r" 'BEGIN { FS = ":" } \
		/^# / { desc = substr($$0, 3); next } \
		/^[a-zA-Z0-9][a-zA-Z0-9_.-]*:($$|[^=])/ { \
			if (desc != "") { printf "  %s%-20s%s %s\n", c, $$1, r, desc; desc = "" } \
			next \
		} \
		{ desc = "" }' $(MAKEFILE_LIST)


# ---------------------------------------------------------------------------
# Tools. Override any of these on the command line.
#
# sjasmplus is normally on PATH via ~/bin/direnv-spectrum.sh; the fallback is
# the checkout it lives in, so a build works even without direnv loaded.
# ---------------------------------------------------------------------------

SJASMPLUS ?= $(shell command -v sjasmplus 2>/dev/null || echo $(HOME)/src/spectrum/sjasmplus/sjasmplus)
JNEXT     ?= $(HOME)/src/spectrum/jnext/build/gui-release/jnext
SD_IMAGE  ?= $(HOME)/.jnext/sdcard/cspect-next-1gb-fixed.img

# z88dk, for mfselect only. The stub itself is sjasmplus and must stay that way
# (DeZog cannot do banking with z88dk — see MEMORY.md); mfselect is a
# standalone NextZXOS utility DeZog never sees, so that constraint does not
# reach it.
ZCC       ?= zcc
ZCCFLAGS   = +zxn -subtype=nex -clib=sdcc_iy -SO3 -compiler=sdcc -create-app

# Stamped into the ROM (constants.asm: BUILD_TIME16). Pin it to compare two
# builds byte for byte — see `make check-reproducible`.
BUILD_TIME ?= $(shell date +%s)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

PROJ = dezogif
SRC  = src
OUT  = build
TEST = test

TOOLS = tools

MAIN_ASM    = $(SRC)/main.asm
UT_ASM      = $(SRC)/unit_tests/unit_tests.asm
TRIGGER_ASM = $(TEST)/nmi_trigger.asm
COPPER_ASM  = $(TEST)/copper_nmi.asm
ESP_ASM     = $(TEST)/esp_server.asm
MFSELECT_C  = $(TOOLS)/mfselect/mfselect.c
ROMSUM      = $(TOOLS)/romsum.py

ASM_FILES    = $(wildcard $(SRC)/*.asm) $(wildcard $(SRC)/zx/*.inc)
UT_ASM_FILES = $(wildcard $(SRC)/unit_tests/*.asm) $(wildcard $(SRC)/unit_tests/*.inc) $(ASM_FILES)

MAIN_BIN    = $(OUT)/main.bin
MF_NMI_BIN  = $(OUT)/mf_nmi.bin
ROM         = $(OUT)/enNextMf.rom
UT_BIN      = $(OUT)/ut.nex
TRIGGER_BIN = $(OUT)/nmi_trigger.bin
COPPER_BIN  = $(OUT)/copper_nmi.bin
ESP_BIN     = $(OUT)/esp_server.bin

# mfselect's deployables: the utility, and the checksum of the ROM it installs.
# The .sum is a build product on purpose — a checksum computed on the Next from
# an already-corrupt file would just bless the corruption.
MFSELECT_NEX = $(OUT)/mfselect.nex
DEZOGIF_SUM  = $(OUT)/dezogif.sum

ROM_SIZE = 8192

# The output paths are handed to the assembler rather than hardcoded in the
# sources, so the build directory is named in exactly one place.
ASMFLAGS = --inc=$(SRC) --lstlab --fullpath \
           -DMAIN_BIN=\"$(MAIN_BIN)\" -DMF_NMI_BIN=\"$(MF_NMI_BIN)\" \
           -DBUILD_TIME=$(BUILD_TIME)


# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

# Build the ROM, the main program and the unit tests
all: main unit-tests mf-rom

# Build the debugger program (build/main.bin + build/mf_nmi.bin)
main: $(MAIN_BIN) $(MF_NMI_BIN)

# Assemble the Z80 unit tests (build/ut.nex)
unit-tests: $(UT_BIN)

# Build the deployable Multiface ROM (build/enNextMf.rom)
mf-rom: $(ROM)

# Build the mfselect ROM switcher (build/mfselect.nex + build/dezogif.sum)
mfselect: $(MFSELECT_NEX) $(DEZOGIF_SUM)

# Run the local headless test suite in jnext (no VS Code, no hardware)
test: $(ROM) $(TRIGGER_BIN) $(COPPER_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ROM="$(ROM)" \
	 TRIGGER_BIN="$(TRIGGER_BIN)" COPPER_BIN="$(COPPER_BIN)" $(TEST)/run-headless.sh

# Run the mfselect headless bench (3 jnext runs; not part of `make test`)
test-mfselect: $(MFSELECT_NEX) $(DEZOGIF_SUM) $(ROM)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" NEX="$(MFSELECT_NEX)" \
	 ROM="$(ROM)" SUM="$(DEZOGIF_SUM)" ROMSUM="$(ROMSUM)" $(TEST)/run-mfselect.sh

# Run the ESP-01 server bench (M0(b): 1 jnext run + a TCP client; not part of `make test`)
test-esp: $(ESP_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ESP_BIN="$(ESP_BIN)" \
	 $(TEST)/run-esp.sh

# Run the DZRP conformance suite against a remote (REMOTE=tcp:<host>:<port>)
test-dzrp:
	@test -n "$(REMOTE)" || { \
	  echo "usage: make test-dzrp REMOTE=tcp:<host>:<port>   (or serial:<dev>:<baud>)"; \
	  echo "  to validate the suite itself, point it at CSpect + its DeZog plugin"; \
	  exit 2; }
	python3 $(TEST)/dzrp/conformance.py --remote "$(REMOTE)" $(DZRP_ARGS)

# Check the ROM builds byte-identically twice with BUILD_TIME pinned
check-reproducible:
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	$(MAKE) --no-print-directory clean >/dev/null; \
	$(MAKE) --no-print-directory BUILD_TIME=1700000000 mf-rom >/dev/null; \
	cp $(ROM) $$tmp/a.rom; \
	$(MAKE) --no-print-directory clean >/dev/null; \
	$(MAKE) --no-print-directory BUILD_TIME=1700000000 mf-rom >/dev/null; \
	cp $(ROM) $$tmp/b.rom; \
	if cmp -s $$tmp/a.rom $$tmp/b.rom; then \
	  echo "PASS  reproducible: two pinned builds are byte-identical"; \
	else \
	  echo "FAIL  reproducible: two pinned builds differ"; exit 1; \
	fi

# Remove every build artefact
clean:
	rm -rf $(OUT)


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

# One assembler run produces both files, so this is a grouped target (&:).
# Without the grouping make would run the recipe once per output.
$(MAIN_BIN) $(MF_NMI_BIN) &: $(ASM_FILES) Makefile | $(OUT)
	$(SJASMPLUS) $(ASMFLAGS) --sld=$(OUT)/$(PROJ).sld --lst=$(OUT)/$(PROJ).list $(MAIN_ASM)

$(UT_BIN): $(UT_ASM_FILES) Makefile | $(OUT)
	$(SJASMPLUS) $(ASMFLAGS) -DBIN_FILE=\"$(UT_BIN)\" --sld=$(OUT)/ut.sld --lst=$(OUT)/ut.list $(UT_ASM)

$(TRIGGER_BIN): $(TRIGGER_ASM) Makefile | $(OUT)
	$(SJASMPLUS) -DNMI_TRIGGER_BIN=\"$@\" $(TRIGGER_ASM)

$(COPPER_BIN): $(COPPER_ASM) Makefile | $(OUT)
	$(SJASMPLUS) -DCOPPER_NMI_BIN=\"$@\" $(COPPER_ASM)

$(ESP_BIN): $(ESP_ASM) Makefile | $(OUT)
	$(SJASMPLUS) -DESP_SERVER_BIN=\"$@\" $(ESP_ASM)

# The deployable ROM is the NMI entry code followed by the debugger image.
# tbblue.fw loads exactly ROM_SIZE bytes, so a wrong size is a build error
# and not something to discover on hardware.
$(ROM): $(MF_NMI_BIN) $(MAIN_BIN)
	cat $(MF_NMI_BIN) $(MAIN_BIN) > $@
	@size=$$(stat -c%s $@); \
	if [ "$$size" -ne $(ROM_SIZE) ]; then \
	  echo "ERROR: $@ is $$size bytes, expected $(ROM_SIZE)" >&2; rm -f $@; exit 1; \
	fi

# zcc writes mfselect.nex plus its intermediates next to the -o basename, so
# pointing that at $(OUT) keeps the source tree clean.
$(MFSELECT_NEX): $(MFSELECT_C) Makefile | $(OUT)
	$(ZCC) $(ZCCFLAGS) $(MFSELECT_C) -o $(OUT)/mfselect

$(DEZOGIF_SUM): $(ROM) $(ROMSUM) | $(OUT)
	python3 $(ROMSUM) $(ROM) > $@

$(OUT):
	mkdir -p $@
