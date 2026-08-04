# Makefile — dezogif_ng
#
# `make` with no target lists every target that has a `#` comment on the line
# immediately above it. Target names print in bold red.

.DEFAULT_GOAL := help
.PHONY: help all main unit-tests mf-rom mf-rom-wifi mf-rom-sum mfselect test test-mfselect \
        test-esp test-dzrp test-dzrp-stub test-hardware bump check-reproducible \
        check-reproducible-wifi clean

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

# Build number for the ROM identity block (issue #4), read from version.yaml
# rather than kept here, so `make bump` has one file to rewrite and the number
# survives in git as a reviewable one-line diff.
#
# Rendered as four uppercase hex digits and emitted into the magic string, e.g.
# DeZoGiFnG_UART_0001. Unlike BUILD_TIME this does NOT change on every build,
# which is the whole point: check-reproducible still passes, and a rebuild of
# the same source gives the same identity.
VERSION_FILE   = version.yaml
BUILD_NUMBER  ?= $(shell awk '/^build_number:/ { print $$2 }' $(VERSION_FILE))
BUILD_NUMBER_HEX = $(shell printf '%04X' $(BUILD_NUMBER))


# ---------------------------------------------------------------------------
# Transport variant — M1's assembly-time switch.
#
#   make                     UART mode, upstream's joy-port serial link
#   make TRANSPORT=wifi ...  WiFi mode, DZRP over TCP through the ESP-01
#
# One mode per ROM, by design (MEMORY.md 2026-08-03): a runtime switch would put
# a branch in the hot path of every transport call and buy nothing a rebuild
# does not.
#
# THE TWO VARIANTS HAVE DIFFERENT OUTPUT NAMES ON PURPOSE. Sharing one path
# would mean `make TRANSPORT=wifi` leaves a WiFi ROM at the name every other
# target reads, and the next `make test` would find nothing newer than its
# output, do nothing, and test the wrong ROM without saying so.
#
# The UART names are unsuffixed, so the serial build's paths — and therefore
# its bytes — are exactly what they were before the switch existed.
# ---------------------------------------------------------------------------

TRANSPORT ?= uart

ifeq ($(TRANSPORT),uart)
  VARIANT_SUFFIX =
  VARIANT_FLAGS  =
else ifeq ($(TRANSPORT),wifi)
  VARIANT_SUFFIX = -wifi
  VARIANT_FLAGS  = -DTRANSPORT_WIFI
else
  $(error TRANSPORT must be 'uart' or 'wifi', not '$(TRANSPORT)')
endif


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

MAIN_BIN    = $(OUT)/main$(VARIANT_SUFFIX).bin
MF_NMI_BIN  = $(OUT)/mf_nmi$(VARIANT_SUFFIX).bin
ROM         = $(OUT)/enNextMf$(VARIANT_SUFFIX).rom
UT_BIN      = $(OUT)/ut.nex
TRIGGER_BIN = $(OUT)/nmi_trigger.bin
COPPER_BIN  = $(OUT)/copper_nmi.bin
ESP_BIN     = $(OUT)/esp_server.bin

# mfselect's deployables: the utility, and a checksum for each ROM it can
# install. The .sum files are build products on purpose — a checksum computed on
# the Next from an already-corrupt file would just bless the corruption.
#
# mfselect offers BOTH variants (issue #5), so it cannot use $(ROM)/$(TRANSPORT):
# those name whichever variant *this* invocation selected, and mfselect needs
# both regardless of how it was invoked. Hence the spelled-out pairs below, and
# the recursive builds in the `mfselect` recipe.
#
# The .sum basenames match the names the files take on the card, so a user
# copying them cannot pair a ROM with the wrong checksum. 8.3-safe, which is
# why they are not `enNextMf-wifi.sum` (MEMORY.md rejected 8.3-unsafe names for
# this directory once already).
MFSELECT_NEX = $(OUT)/mfselect.nex
ROM_UART     = $(OUT)/enNextMf.rom
ROM_WIFI     = $(OUT)/enNextMf-wifi.rom
SUM_UART     = $(OUT)/dezouart.sum
SUM_WIFI     = $(OUT)/dezowifi.sum

# The pair for whichever variant this invocation selected. Equal to SUM_UART
# with TRANSPORT=uart and to SUM_WIFI with TRANSPORT=wifi, so one rule text
# builds both — once per recursive invocation.
ROM_SUM      = $(OUT)/dezo$(TRANSPORT).sum

ROM_SIZE = 8192

# The output paths are handed to the assembler rather than hardcoded in the
# sources, so the build directory is named in exactly one place.
ASMFLAGS = --inc=$(SRC) --lstlab --fullpath \
           -DMAIN_BIN=\"$(MAIN_BIN)\" -DMF_NMI_BIN=\"$(MF_NMI_BIN)\" \
           -DBUILD_TIME=$(BUILD_TIME) \
           -DBUILD_NUMBER_HEX=\"$(BUILD_NUMBER_HEX)\" \
           $(VARIANT_FLAGS)


# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

# Build the ROM, the main program and the unit tests
all: main unit-tests mf-rom

# Build the debugger program (build/main.bin + build/mf_nmi.bin)
main: $(MAIN_BIN) $(MF_NMI_BIN)

# Assemble the Z80 unit tests (build/ut.nex)
unit-tests: $(UT_BIN)

# Build the deployable Multiface ROM (build/enNextMf.rom; TRANSPORT=wifi for the other)
mf-rom: $(ROM)

# Build the WiFi-mode ROM (build/enNextMf-wifi.rom) — shorthand for TRANSPORT=wifi
mf-rom-wifi:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom

# Build the ROM for the selected TRANSPORT plus its checksum sidecar
mf-rom-sum: $(ROM) $(ROM_SUM)

# Both variants, in one step and whatever TRANSPORT this invocation carries:
# mfselect installs either, so shipping it with only the variant that happened
# to be selected is how a user ends up with a menu entry pointing at a file that
# is not on the card. The recursion is what lets one target produce two ROMs
# that the rest of this Makefile deliberately keeps apart.
#
# BUILD_TIME is captured once and handed to both sub-makes, so the pair that
# ships together carries the same stamp. Without that the two `date +%s` calls
# can straddle a second and produce two ROMs a user would reasonably read as
# coming from different builds.
#
# The bare '#' below ends this block for the help scanner, which takes the LAST
# '# ' line before a target as its description — so the one-liner goes last.
#

# Build the mfselect switcher and EVERYTHING it deploys: both ROMs + both .sums
mfselect: $(MFSELECT_NEX)
	@t=$(BUILD_TIME); \
	 $(MAKE) --no-print-directory TRANSPORT=uart BUILD_TIME=$$t mf-rom-sum; \
	 $(MAKE) --no-print-directory TRANSPORT=wifi BUILD_TIME=$$t mf-rom-sum

# Run the local headless test suite in jnext (no VS Code, no hardware)
test: $(ROM) $(TRIGGER_BIN) $(COPPER_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ROM="$(ROM)" \
	 TRIGGER_BIN="$(TRIGGER_BIN)" COPPER_BIN="$(COPPER_BIN)" $(TEST)/run-headless.sh

# Run the mfselect headless bench (6 jnext runs; not part of `make test`)
test-mfselect: mfselect
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" NEX="$(MFSELECT_NEX)" \
	 ROM_UART="$(ROM_UART)" SUM_UART="$(SUM_UART)" \
	 ROM_WIFI="$(ROM_WIFI)" SUM_WIFI="$(SUM_WIFI)" \
	 ROMSUM="$(ROMSUM)" CELLDIFF="$(TEST)/cell-diff.py" $(TEST)/run-mfselect.sh

# Run the ESP-01 server bench (M0(b): 1 jnext run + a TCP client; not part of `make test`)
test-esp: $(ESP_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ESP_BIN="$(ESP_BIN)" \
	 $(TEST)/run-esp.sh

# Run the DZRP conformance suite against OUR OWN WiFi stub in jnext (1 run + a TCP client)
test-dzrp-stub:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM="$(OUT)/enNextMf-wifi.rom" DZRP_ARGS="$(DZRP_ARGS)" $(TEST)/run-dzrp-stub.sh

# Run the DZRP conformance suite against a remote (REMOTE=tcp:<host>:<port>)
test-dzrp:
	@test -n "$(REMOTE)" || { \
	  echo "usage: make test-dzrp REMOTE=tcp:<host>:<port>   (or serial:<dev>:<baud>)"; \
	  echo "  to validate the suite itself, point it at CSpect + its DeZog plugin"; \
	  exit 2; }
	python3 $(TEST)/dzrp/conformance.py --remote "$(REMOTE)" $(DZRP_ARGS)

# The only bench here that needs a ZX Spectrum Next. It is not part of `make
# test` and never can be: `make test` promises no external dependencies, and
# this one depends on a machine, a network, and a person to press the NMI
# button. doc/HARDWARE-TESTING.md carries the procedure and the on-screen
# observations the PC cannot make.
#
# NOTE the description line must be the LAST `# ` line before the target — the
# help rule keeps the last one it sees, so a rationale block goes ABOVE it.
#
# Run the hardware bench against a real Next over WiFi (NEXT_IP=<ip>)
test-hardware:
	@test -n "$(NEXT_IP)" || { \
	  echo "usage: make test-hardware NEXT_IP=<ip>   (the Next's address, port 11000)"; \
	  echo "  the stub does not show its IP yet — the connect-string UI is M1's last item."; \
	  echo "  Get it from wifi2.bas on the Next, or from the router's lease table."; \
	  echo "  Read doc/HARDWARE-TESTING.md first: most of what hardware can tell us is"; \
	  echo "  an observation on the Next's screen, not something a socket can reach."; \
	  exit 2; }
	python3 $(TEST)/hardware-check.py --host "$(NEXT_IP)" $(HW_ARGS)

# Increment the ROM build number in version.yaml (one bump per merge to main)
bump:
	@cur=$$(awk '/^build_number:/ { print $$2 }' $(VERSION_FILE)); \
	case "$$cur" in '' | *[!0-9]*) \
	  echo "ERROR: build_number in $(VERSION_FILE) is not a number: '$$cur'" >&2; exit 1;; \
	esac; \
	next=$$(( cur + 1 )); \
	if [ "$$next" -gt 65535 ]; then \
	  echo "ERROR: build_number $$next exceeds 65535; the magic string has four hex digits" >&2; \
	  exit 1; \
	fi; \
	sed -i "s/^build_number:.*/build_number: $$next/" $(VERSION_FILE); \
	printf 'build_number %s -> %s   (ROM magic becomes DeZoGiFnG_<VARIANT>_%04X)\n' "$$cur" "$$next" "$$next"


# Check the ROM builds byte-identically twice with BUILD_TIME pinned
check-reproducible:
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	$(MAKE) --no-print-directory clean >/dev/null; \
	$(MAKE) --no-print-directory TRANSPORT=$(TRANSPORT) BUILD_TIME=1700000000 mf-rom >/dev/null; \
	cp $(ROM) $$tmp/a.rom; \
	$(MAKE) --no-print-directory clean >/dev/null; \
	$(MAKE) --no-print-directory TRANSPORT=$(TRANSPORT) BUILD_TIME=1700000000 mf-rom >/dev/null; \
	cp $(ROM) $$tmp/b.rom; \
	if cmp -s $$tmp/a.rom $$tmp/b.rom; then \
	  echo "PASS  reproducible ($(TRANSPORT)): two pinned builds are byte-identical"; \
	else \
	  echo "FAIL  reproducible ($(TRANSPORT)): two pinned builds differ"; exit 1; \
	fi

# Same check for the WiFi ROM
check-reproducible-wifi:
	@$(MAKE) --no-print-directory TRANSPORT=wifi check-reproducible

# Remove every build artefact
clean:
	rm -rf $(OUT)


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

# One assembler run produces both files, so this is a grouped target (&:).
# Without the grouping make would run the recipe once per output.
# $(VERSION_FILE) is a prerequisite because the build number is assembled INTO
# the ROM. Without it `make bump` rewrites version.yaml, the next `make` finds
# no .asm newer than its outputs, does nothing, and ships a ROM whose identity
# block still carries the OLD number — silently, which is the failure mode this
# project's rules single out as the worst kind.
$(MAIN_BIN) $(MF_NMI_BIN) &: $(ASM_FILES) $(VERSION_FILE) Makefile | $(OUT)
	$(SJASMPLUS) $(ASMFLAGS) --sld=$(OUT)/$(PROJ)$(VARIANT_SUFFIX).sld \
	    --lst=$(OUT)/$(PROJ)$(VARIANT_SUFFIX).list $(MAIN_ASM)

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

$(ROM_SUM): $(ROM) $(ROMSUM) | $(OUT)
	python3 $(ROMSUM) $(ROM) > $@

$(OUT):
	mkdir -p $@
