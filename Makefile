# Makefile — dezogif_ng
#
# `make` with no target lists every target that has a `#` comment on the line
# immediately above it. Target names print in bold red.

.DEFAULT_GOAL := help
.PHONY: help all main unit-tests ut-headless mf-rom mf-rom-wifi mf-rom-sum mfselect test \
        test-unit test-mfselect \
        test-esp test-dzrp test-dzrp-stub test-ip-boundary test-tx-patience \
        test-hardware bump check-reproducible \
        check-reproducible-wifi clean

# Show this help
help:
	@# The column width is DERIVED from the longest target name, not a constant.
	@# It used to be a hardcoded %-20s, and `check-reproducible-wifi` is 22
	@# characters, so that one row overflowed and pushed its description out of
	@# line. Widening the constant would only move the problem to whoever adds
	@# the next longer name, so this collects the rows first and formats them in
	@# END, once the width is known.
	@if [ -t 1 ] && [ -z "$$NO_COLOR" ]; then c='\033[1;31m'; r='\033[0m'; else c=; r=; fi; \
	awk -v c="$$c" -v r="$$r" 'BEGIN { FS = ":"; n = 0; w = 0 } \
		/^# / { desc = substr($$0, 3); next } \
		/^[a-zA-Z0-9][a-zA-Z0-9_.-]*:($$|[^=])/ { \
			if (desc != "") { \
				name[n] = $$1; text[n] = desc; \
				if (length($$1) > w) w = length($$1); \
				n++; desc = "" \
			} \
			next \
		} \
		{ desc = "" } \
		END { for (i = 0; i < n; i++) \
			printf "  %s%-*s%s %s\n", c, w, name[i], r, text[i] }' $(MAKEFILE_LIST)


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

# IP_MAX — a bench seam, and the only way the address parser's boundary can be
# reached. jnext's emulated module always answers AT+CIFSR with 192.168.1.50
# (12 characters) and there is no option to change it, so a bound of 15 is
# never touched by any run. Lowering the bound moves the boundary onto jnext's
# own answer instead. See test/run-ip-boundary.sh.
#
# IT GETS ITS OWN OUTPUT NAME, for the same reason the two transports do: a
# probe ROM left at the name a shipped one is read from is a wrong-file bug
# that make cannot see, because nothing here depends on the flag's value.
IP_MAX ?=

ifneq ($(IP_MAX),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-ipmax$(IP_MAX)
  VARIANT_FLAGS  += -DESP_IP_MAX=$(IP_MAX)
endif

# RX_WAIT / TX_PASSES — the second bench seam, and the only way the SEND
# timeout path can be reached, for the same reason IP_MAX exists: jnext answers
# an AT+CIPSEND at once, so the budget that a real ESP-01 overran is never
# approached here. Shrinking one pass (RX_WAIT) down to the emulator's own
# reply latency puts the boundary back inside reach, and TX_PASSES=1 restores
# the single-budget behaviour that hardware broke, as the control.
# See test/run-tx-patience.sh.
#
# Same naming rule as IP_MAX: each probe ROM gets its own output name, so no
# probe can be left where a shipped ROM is read from.
RX_WAIT   ?=
TX_PASSES ?=

ifneq ($(RX_WAIT),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-rxwait$(RX_WAIT)
  VARIANT_FLAGS  += -DESP_RX_WAIT=$(RX_WAIT)
endif

ifneq ($(TX_PASSES),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-txp$(TX_PASSES)
  VARIANT_FLAGS  += -DESP_TX_PASSES=$(TX_PASSES)
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
UT_HL_ASM   = $(SRC)/unit_tests/headless/ut_headless.asm
TRIGGER_ASM = $(TEST)/nmi_trigger.asm
COPPER_ASM  = $(TEST)/copper_nmi.asm
ESP_ASM     = $(TEST)/esp_server.asm
MFSELECT_C  = $(TOOLS)/mfselect/mfselect.c
ROMSUM      = $(TOOLS)/romsum.py
UT_GEN      = $(TOOLS)/ut-headless-gen.py

ASM_FILES    = $(wildcard $(SRC)/*.asm) $(wildcard $(SRC)/zx/*.inc)
UT_ASM_FILES = $(wildcard $(SRC)/unit_tests/*.asm) $(wildcard $(SRC)/unit_tests/*.inc) $(ASM_FILES)
UT_HL_FILES  = $(wildcard $(SRC)/unit_tests/headless/*) $(UT_ASM_FILES) $(UT_GEN)

# The number of test cases under src/unit_tests/, and how many of them cannot
# run outside DeZog. PINNED HERE AND AGAIN IN test/run-unit-tests.sh, on
# purpose: the generator fails the BUILD if the sources disagree with these,
# and the bench fails the RUN if what executed disagrees. A suite that quietly
# shrinks and still reports "all passed" is a failure this project has already
# had twice (ERRORS.md), and one pin can only catch half of it.
#
# The 36 excluded cases need ports invented by DeZog's zsim customCode plugin
# (src/simulation/uart.js) and cannot run in any emulator — see doc/UNIT-TESTS.md.
UT_EXPECTED_TESTS   = 64
UT_EXPECTED_SKIPPED = 36

MAIN_BIN    = $(OUT)/main$(VARIANT_SUFFIX).bin
MF_NMI_BIN  = $(OUT)/mf_nmi$(VARIANT_SUFFIX).bin
ROM         = $(OUT)/enNextMf$(VARIANT_SUFFIX).rom
UT_BIN      = $(OUT)/ut.nex
UT_HL_BIN   = $(OUT)/ut-headless.nex
UT_HL_GEN   = $(OUT)/ut_headless/ut_table.asm
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

# What gets copied to the card, under the names the card needs.
#
# The ROMs cannot simply be BUILT under these names: `enNextMf.rom` is the name
# the Next's firmware loads at boot, and it is what the by-hand deployment path
# and `make test` both install, while `dezouart.rom` is the name mfselect looks
# for beside itself in /mfselect/. The same bytes wear a different name
# depending on which of the two jobs they are doing.
#
# So the deploy directory exists to stop that being the USER's problem. It used
# to be: the README listed five files of which two had to be renamed in flight,
# which is precisely the step at which somebody pairs dezowifi.sum with the
# UART ROM and gets a refusal they have to debug. Copy the directory, do not
# transcribe a table.
#
# The names here are not this Makefile's invention and must not drift from
# their source: they are the WIFI_ROM/WIFI_SUM/UART_ROM/UART_SUM #defines in
# tools/mfselect/mfselect.c, which is the program that opens them.
DEPLOY       = $(OUT)/deploy

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

# `all` means ALL, and it did not used to. It built the program, the unit tests
# and ONE ROM — the variant of whichever TRANSPORT the invocation carried —
# while the WiFi ROM, both checksum sidecars and mfselect itself were somewhere
# else entirely. A target named `all` that produces a fraction of the
# deliverables is a trap for anyone who reasonably expects to find everything in
# build/ afterwards.
#
# It now depends on `mfselect`, which is the target that builds BOTH ROMs, both
# .sums and the deploy directory. `mfselect` is deliberately kept rather than
# folded in here: it is the narrow "just the switcher and what it installs"
# build, and `test-mfselect` depends on it, so folding it away would make that
# bench rebuild the Z80 unit tests for nothing.
#
# `ut-headless` is here for the same reason `unit-tests` is: both are unit-test
# images, neither is a deliverable, and building one of the pair is exactly the
# fraction-of-everything trap the paragraph above is about.
#
# Build everything: the program, both unit-test images, mfselect, BOTH ROMs and their .sums
all: main unit-tests ut-headless mfselect

# Build the debugger program (build/main.bin + build/mf_nmi.bin)
main: $(MAIN_BIN) $(MF_NMI_BIN)

# ASSEMBLES ut.nex AND RUNS NOTHING, which the old description ("Assemble the
# Z80 unit tests") was accurate about and still managed to obscure. The tests
# inside it are DeZog-driven — they need "unitTests": true plus zsim in VS Code
# to execute — so nothing in test/ or tools/ so much as references ut.nex.
# Making them runnable headless is issue #3.
#
# ASSEMBLE the DeZog-driven Z80 unit tests (build/ut.nex) — running THESE needs VS Code
unit-tests: $(UT_BIN)

# Assemble the headless unit-test image (build/ut-headless.nex) — `make test-unit` runs it
ut-headless: $(UT_HL_BIN)

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
	@mkdir -p $(DEPLOY)
	@# Named individually rather than `rm -rf $(DEPLOY)`: a recursive delete of
	@# a path built from variables is one typo away from deleting something
	@# else, and there is nothing here it buys.
	@rm -f $(DEPLOY)/mfselect.nex $(DEPLOY)/dezowifi.rom $(DEPLOY)/dezowifi.sum \
	       $(DEPLOY)/dezouart.rom $(DEPLOY)/dezouart.sum
	@cp -f $(MFSELECT_NEX) $(DEPLOY)/mfselect.nex
	@cp -f $(ROM_WIFI)     $(DEPLOY)/dezowifi.rom
	@cp -f $(SUM_WIFI)     $(DEPLOY)/dezowifi.sum
	@cp -f $(ROM_UART)     $(DEPLOY)/dezouart.rom
	@cp -f $(SUM_UART)     $(DEPLOY)/dezouart.sum
	@echo
	@echo "$(DEPLOY)/ is ready — copy its CONTENTS into /mfselect/ on the card:"
	@echo
	@ls -1 $(DEPLOY) | sed 's|^|    /mfselect/|'
	@echo
	@echo "  Nothing to rename. Each .rom and its .sum come from this one build,"
	@echo "  which is what makes them a coherent set."

# NOT the Z80 unit tests, and calling this "the test suite" invited exactly that
# reading. This boots a Next in jnext with our ROM installed as the Multiface
# ROM, fires NMIs at it and judges SCREENSHOTS. The unit tests under
# src/unit_tests/ are a separate body of code that `make unit-tests` assembles
# and nothing here executes.
#
# Boot a Next in jnext and judge screenshots — 6 checks, no VS Code, no hardware
test: $(ROM) $(TRIGGER_BIN) $(COPPER_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ROM="$(ROM)" \
	 TRIGGER_BIN="$(TRIGGER_BIN)" COPPER_BIN="$(COPPER_BIN)" $(TEST)/run-headless.sh

# The Z80 unit tests, at last runnable without VS Code (issue #3). Kept OUT of
# `make test` deliberately, and not for the usual reason — this one has no
# external dependency and binds no port, so it could join. It stays separate
# because `make test` is the screenshot bench and says so at length: every
# other bench in this Makefile is its own target, and folding these in would
# blur the one distinction that Makefile comment exists to draw.
#
# 28 of the 64 cases run. The other 36 need ports invented by DeZog's zsim
# customCode plugin and are reported as UT-SKIP rather than hidden — see
# doc/UNIT-TESTS.md.
#
# The bare '#' below ends this block for the help scanner, which takes the LAST
# '# ' line before a target as its description.
#

# Run the Z80 unit tests headless in jnext — 5 checks, no VS Code (not part of `make test`)
test-unit: $(UT_HL_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 UT_NEX="$(UT_HL_BIN)" UT_MANIFEST="$(OUT)/ut_headless/ut_manifest.txt" \
	 $(TEST)/run-unit-tests.sh

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

# The address parser's length boundary, which no other bench can reach: jnext
# always answers AT+CIFSR with a 12-character address and there is no option to
# change it, so the shipped bound of 15 is never touched. This moves the BOUND
# instead of the address — same Z80 code, same emulator, one constant different.
# See test/run-ip-boundary.sh for why that is the shape.
#
# The two probe ROMs get their own names via IP_MAX, so neither can be left
# where a shipped ROM is read from.
#
# Run the AT+CIFSR address-length boundary bench (2 jnext runs; not part of `make test`)
test-ip-boundary:
	@$(MAKE) --no-print-directory TRANSPORT=wifi IP_MAX=12 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi IP_MAX=11 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_OK="$(OUT)/enNextMf-wifi-ipmax12.rom" \
	 ROM_TOOLONG="$(OUT)/enNextMf-wifi-ipmax11.rom" $(TEST)/run-ip-boundary.sh

# The budget esp_flush_chunk gives the module to answer an AT+CIPSEND, which no
# ordinary run can reach: jnext answers at once, so the timeout arm is dead code
# in the emulator and was green throughout issue #11's hardware failure. This
# moves the BUDGET instead of the module — same Z80 code, same emulator, two
# constants different — and the third run is the control that makes removing the
# fix a controlled removal rather than a correlation.
# See test/run-tx-patience.sh.
#
# The three probe ROMs get their own names via RX_WAIT/TX_PASSES, so none can be
# left where a shipped ROM is read from.
#
# Run the AT+CIPSEND send-wait budget bench (3 jnext runs; not part of `make test`)
test-tx-patience:
	@$(MAKE) --no-print-directory TRANSPORT=wifi RX_WAIT=1600 TX_PASSES=10 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi RX_WAIT=1600 TX_PASSES=1  mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi TX_PASSES=1 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_FIXED="$(OUT)/enNextMf-wifi-rxwait1600-txp10.rom" \
	 ROM_PREFIX="$(OUT)/enNextMf-wifi-rxwait1600-txp1.rom" \
	 ROM_CONTROL="$(OUT)/enNextMf-wifi-txp1.rom" $(TEST)/run-tx-patience.sh

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
	  echo "  Press the NMI button and read the address off the Next's own screen:"; \
	  echo "  'Connect at <ip>:11000'. wifi2.bas and the router are the second opinions."; \
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

# The headless twin. Two steps, because the assertions have to be turned into
# code before they can be assembled:
#
#   1. the generator rewrites the inline `; ASSERTION <cond>` comments in the
#      upstream test bodies into calls to the macros in ut_headless.inc, and
#      emits the test table. Nothing under src/unit_tests/ is modified — the
#      rewritten copies go to $(OUT)/ut_headless/, so `make unit-tests` and
#      the DeZog path in VS Code are untouched.
#   2. sjasmplus assembles those, with --inc=$(OUT) so the generated files are
#      found.
#
# ASMFLAGS is reused so the headless image is built against the same sources
# and defines as everything else; MAIN_BIN/MF_NMI_BIN in it are inert here
# because this collector has no SAVEBIN.
$(UT_HL_GEN): $(UT_HL_FILES) Makefile | $(OUT)
	python3 $(UT_GEN) --src $(SRC)/unit_tests --out $(OUT)/ut_headless \
	    --expect-tests $(UT_EXPECTED_TESTS) --expect-skipped $(UT_EXPECTED_SKIPPED)

$(UT_HL_BIN): $(UT_HL_GEN) $(UT_HL_FILES) Makefile | $(OUT)
	$(SJASMPLUS) $(ASMFLAGS) --inc=$(OUT) -DBIN_FILE=\"$(UT_HL_BIN)\" \
	    --sld=$(OUT)/ut-headless.sld --lst=$(OUT)/ut-headless.list $(UT_HL_ASM)

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
