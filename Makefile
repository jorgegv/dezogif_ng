# Makefile — dezogif_ng
#
# `make` with no target lists every target that has a `#` comment on the line
# immediately above it. Target names print in bold red.

.DEFAULT_GOAL := help
.PHONY: help all main unit-tests ut-headless mf-rom mf-rom-wifi mf-rom-sum mfselect test \
        test-unit test-mfselect mfinstall test-mfinstall \
        test-esp test-dzrp test-dzrp-stub test-ip-boundary test-tx-patience \
        test-client-status test-no-hang test-screen-agreement \
        test-hardware probe-jnext probe-slots probe-vanished probe-idle-drop \
        read-screen \
        bump bump-major check-reproducible \
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

# z88dk, for the two host-side NextZXOS utilities only. The stub itself is
# sjasmplus and must stay that way (DeZog cannot do banking with z88dk — see
# MEMORY.md); mfselect and mfinstall are standalone NextZXOS utilities DeZog
# never sees, so that constraint does not reach them.
#
# TWO SUBTYPES, and they are not interchangeable. mfselect is a `nex`: it takes
# the whole machine, draws a menu and is launched with .nexload. mfinstall is a
# `dot`: it runs at 0x2000 inside a live BASIC session, takes a command tail,
# and can therefore be called from AUTOEXEC.BAS — which is the entire point of
# issue #21. A dot command is also the only one of the two that CAN do the job:
# see tools/mfinstall/mfwin.asm on why the window has to be relocated.
#
# `-startup=30` on the dot build is NOT cosmetic and NOT copied from a habit.
# It is the startup z88dk's own dot-command examples use, it prints through the
# 48K ROM instead of linking a console driver, and it takes the binary from
# 10238 bytes to 6606 — from over the 8192-byte dot page to inside even the
# ~7 KB ceiling stock esxdos imposes. It also fixes which crt is in play:
# 0x100 + 30 = zxn_crt_286, which is the one whose documented exit convention
# tools/mfinstall/mfinstall.c returns values for.
ZCC       ?= zcc
ZCCFLAGS   = +zxn -subtype=nex -clib=sdcc_iy -SO3 -compiler=sdcc -create-app
ZCCDOTFLAGS = +zxn -subtype=dot -startup=30 -clib=sdcc_iy -SO3 -compiler=sdcc -create-app

# Stamped into the ROM (constants.asm: BUILD_TIME16). Pin it to compare two
# builds byte for byte — see `make check-reproducible`.
BUILD_TIME ?= $(shell date +%s)

# Build number for the ROM identity block (issue #4), read from version.yaml
# rather than kept here, so `make bump` has one file to rewrite and the number
# survives in git as a reviewable one-line diff.
#
# STORED as four uppercase hex digits (issue #20), quoted in version.yaml so
# nothing reads 0014 back as a decimal. Unlike BUILD_TIME this does NOT change
# on every build, which is the whole point: check-reproducible still passes, and
# a rebuild of the same source gives the same identity.
#
# TWO RENDERINGS, ONE SOURCE, and the second is derived from the first one line
# below it so they cannot drift:
#
#   BUILD_NUMBER_HEX     000E    the magic string's field — four BARE digits,
#                                because that block's format is a contract
#                                mfselect parses (issue #4)
#   BUILD_NUMBER_SHOWN   00.0E   what a person reads — on the debugger's banner
#                                and, via the block above, in mfselect
#
# The arithmetic round trip (parse as hex, print as %04X) normalises a
# hand-written or command-line value — `make BUILD_NUMBER=3` still gives 0003 —
# and makes a value that is not a number fail loudly instead of reaching the
# assembler.
VERSION_FILE   = version.yaml
BUILD_NUMBER  ?= $(shell awk '/^build_number:/ { v = $$2; gsub(/"/, "", v); print v }' $(VERSION_FILE))
BUILD_NUMBER_HEX = $(shell printf '%04X' $$(( 0x$(BUILD_NUMBER) )))
BUILD_NUMBER_SHOWN = $(shell printf '%s' '$(BUILD_NUMBER_HEX)' | sed 's/../&./')


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

# WAIT_SECS — the third bench seam, and the only way the BEFORE half of
# transport_wait_rx's bound can be assembled at all. WAIT_SECS=0 builds the loop
# exactly as it was before issue #16, with no bound: the negative control that
# makes the check a check rather than an assertion about nothing. Unlike IP_MAX
# and RX_WAIT this is not needed to REACH the shipped behaviour — 5 seconds is
# short enough for a bench to sit out — so the bench's own N2 runs the shipped
# ROM and only the control is a probe. Both transports honour it.
# See test/run-no-hang.sh.
#
# Same naming rule as IP_MAX and RX_WAIT: each probe ROM gets its own output
# name, so no probe can be left where a shipped ROM is read from.
WAIT_SECS ?=

ifneq ($(WAIT_SECS),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-wait$(WAIT_SECS)
  VARIANT_FLAGS  += -DTRANSPORT_WAIT_RX_SECONDS=$(WAIT_SECS)
endif

# FAULT_LIMIT — the fourth bench seam, and the only way the self-recovery can be
# made to fire inside a run. The shipped value is five CONSECUTIVE transport
# faults, and no bench here can produce five: jnext's module answers everything
# it is asked, so faults only appear one at a time from an injected budget and
# a successful chunk clears the count between them. FAULT_LIMIT=1 makes the
# first one trigger. See test/run-no-hang.sh's N4, and read its scope note
# before believing it says more than it does.
#
# Same naming rule as the others: each probe ROM gets its own output name.
FAULT_LIMIT ?=

ifneq ($(FAULT_LIMIT),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-fl$(FAULT_LIMIT)
  VARIANT_FLAGS  += -DESP_FAULT_LIMIT=$(FAULT_LIMIT)
endif

# LINK_IDS — the fifth bench seam, and the only way the state issue #19 fixed can
# be assembled again. The shipped value sweeps every link id with AT+CIPCLOSE on
# a recovery; LINK_IDS=0 leaves the sweep out, which is esp_recover exactly as it
# was, and is what test/run-slot-recovery.sh's S3 needs to be red against. A
# scratch tree would have shown the same thing once; a seam shows it on every
# run, which is the difference between a claim and a check.
#
# Same naming rule as the others: each probe ROM gets its own output name.
LINK_IDS ?=

ifneq ($(LINK_IDS),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-li$(LINK_IDS)
  VARIANT_FLAGS  += -DESP_LINK_IDS=$(LINK_IDS)
endif

# SERVER_TIMEOUT / CIPSTO_STRICT — the sixth bench seam, and the two things the
# module's own AT+CIPSTO idle timeout needs before it can be checked at all.
#
# The shipped value is 1800 seconds, which is the point of the fix and is also
# why no ordinary run can watch it work: half an hour per check. SERVER_TIMEOUT
# brings it down to something a bench can sit out, so that a client dropped at
# ten seconds shows that the value THIS ROM SENT is the value that governs — the
# same move IP_MAX and RX_WAIT make, one constant instead of the world.
# An out-of-range SERVER_TIMEOUT (above 7200) is refused by the module, which is
# the only way to execute the ERROR arm of esp_command_ok_or_error.
#
# CIPSTO_STRICT=1 assembles that step with esp_command_ok instead, so a refusal
# becomes a bring-up failure — the behaviour the fix exists to avoid, and
# therefore the thing the refusal check has to be shown red against. Same
# justification as LINK_IDS=0: a red nobody can re-run is a story about a
# scratch tree. Nothing ships with it set. See test/run-cipsto.sh.
#
# Same naming rule as the others: each probe ROM gets its own output name.
SERVER_TIMEOUT ?=
CIPSTO_STRICT  ?=

ifneq ($(SERVER_TIMEOUT),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-sto$(SERVER_TIMEOUT)
  VARIANT_FLAGS  += -DESP_SERVER_TIMEOUT=$(SERVER_TIMEOUT)
endif

ifneq ($(CIPSTO_STRICT),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-stostrict$(CIPSTO_STRICT)
  VARIANT_FLAGS  += -DESP_CIPSTO_STRICT=$(CIPSTO_STRICT)
endif

# BAUD_HIGH — the seventh bench seam, and the only one of the family whose
# "off" setting is also a SHIPPABLE ROM rather than only a control.
#
# The link comes up at 115200 and is then negotiated to ESP_BAUD_HIGH, 1000000
# as shipped (issue #25, src/constants.asm for why that number). Three settings
# each reach a state no other can:
#
#   (default)           ESP_BAUDRATE, so the negotiation is assembled OUT. THAT
#                       IS WHAT SHIPS, and src/constants.asm carries the
#                       measurement that decided it
#   BAUD_HIGH=460800    the negotiation happens, and the whole conformance suite
#                       still passes — 15 of 15 with W1-W6
#   BAUD_HIGH=6000000   above the 5000000 jnext's AT engine will parse, so the
#                       module answers ERROR and the arm that declines to switch
#                       is executed rather than reasoned about
#   BAUD_HIGH=1000000   THE CEILING: the symmetric 1 KB loopback overflows the
#                       512-byte Rx FIFO, because the Z80 cannot read, buffer and
#                       re-send a byte in the 280 T-states one lasts at that rate
#
# What NO setting of this can reach is the half-switched link itself: jnext
# paces both directions from the guest's own prescaler and never compares the
# rate it was asked for against the rate it is spoken to, so a stub that moved
# one side and not the other is indistinguishable there from a correct switch.
# That one is hardware's alone. See test/run-baud.sh.
#
# Same naming rule as the others: each probe ROM gets its own output name.
BAUD_HIGH ?=

ifneq ($(BAUD_HIGH),)
  VARIANT_SUFFIX := $(VARIANT_SUFFIX)-baud$(BAUD_HIGH)
  VARIANT_FLAGS  += -DESP_BAUD_HIGH=$(BAUD_HIGH)
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
MFINSTALL_C = $(TOOLS)/mfinstall/mfinstall.c
MFWIN_ASM   = $(TOOLS)/mfinstall/mfwin.asm
# The default config `.mfinstall --auto` reads. Checked in rather than printf'd
# into the deploy directory: it is data a user edits on the card, not a build
# product, and shipping the same bytes the bench parses is what makes "it can be
# read" a measurement instead of a hope. See the mfinstall recipe for the one
# thing about it a build CAN check.
MFINSTALL_YML = $(TOOLS)/mfinstall/mfinstall.yml
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
#
# AND THE DIRECTORY IS THE CARD'S, NOT A FLAT BAG. It mirrors the layout the
# files take on the Next — `dot/` and `mfselect/` — for the same reason the
# names are right: so that following the instruction literally cannot put a file
# somewhere it will not be found. The flat version needed a printed rule to say
# that one of its six files went somewhere else, and a rule beside a listing is
# a rule somebody can read past. Now `cp -r build/deploy/* <card>/` is the whole
# procedure and there is nothing left to get wrong.
DEPLOY       = $(OUT)/deploy
DEPLOY_MFSEL = $(DEPLOY)/mfselect
DEPLOY_DOT   = $(DEPLOY)/dot

# mfinstall (issue #21) — the dot command that installs a ROM through config
# mode instead of by swapping a file on the card.
#
# THREE BUILD PRODUCTS, and the middle one is the interesting part. mfwin.asm is
# assembled by SJASMPLUS at a fixed address (0x5000) because it has to run from
# somewhere that survives DivMMC being turned off, and a C function cannot be
# relocated. It is then turned into a C array so the dot command carries it and
# copies it there itself. `xxd -i` names the array after the FILE, so the binary
# is copied to a file called `mfwin_bin` rather than the symbol being patched
# afterwards.
#
# IT IS THE ONE FILE ON THE CARD THAT DOES NOT GO IN /mfselect/. Dot commands
# are looked up in /dot/ — checked on the reference SD image — while its ROMs
# stay where mfselect already puts them. The deploy listing below labels it.
#
# DIVMMC_OFF — the seam, and the only way the blocked-write path can be reached.
# Same shape and same justification as IP_MAX, RX_WAIT/TX_PASSES, WAIT_SECS,
# FAULT_LIMIT and LINK_IDS above: the state a check must be shown red against
# has to be reachable by a BUILD. `DIVMMC_OFF=0` leaves DivMMC mapped for the
# window, which is the ordinary context a dot command runs in and in which every
# config-mode write to bank 5 is silently discarded.
#
# IT GETS ITS OWN OUTPUT NAMES, all three of them, for the reason IP_MAX does: a
# probe left where a shipped one is read from is a wrong-file bug make cannot
# see, because nothing here depends on the flag's value. The generated header
# keeps its FILENAME — mfinstall.c includes "mfwin_bin.h" — and moves to a
# directory of its own instead, which is what -I selects between.
DIVMMC_OFF ?=

ifeq ($(DIVMMC_OFF),)
  MFWIN_SUFFIX  =
  MFWIN_FLAGS   =
  MFWIN_INCDIR  = $(OUT)
else
  MFWIN_SUFFIX  = -dmoff$(DIVMMC_OFF)
  MFWIN_FLAGS   = -DDIVMMC_OFF=$(DIVMMC_OFF)
  MFWIN_INCDIR  = $(OUT)/mfwin$(MFWIN_SUFFIX)
endif

MFWIN_BIN     = $(OUT)/mfwin$(MFWIN_SUFFIX).bin
MFWIN_H       = $(MFWIN_INCDIR)/mfwin_bin.h
MFINSTALL_DOT = $(OUT)/mfinstall$(MFWIN_SUFFIX)

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
           -DBUILD_NUMBER_SHOWN=\"$(BUILD_NUMBER_SHOWN)\" \
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
# Build everything: the program, both unit-test images, mfselect, mfinstall, BOTH ROMs and their .sums
all: main unit-tests ut-headless mfselect mfinstall

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
	@mkdir -p $(DEPLOY_MFSEL)
	@# Named individually rather than `rm -rf $(DEPLOY)`: a recursive delete of
	@# a path built from variables is one typo away from deleting something
	@# else, and there is nothing here it buys.
	@rm -f $(DEPLOY_MFSEL)/mfselect.nex $(DEPLOY_MFSEL)/dezowifi.rom \
	       $(DEPLOY_MFSEL)/dezowifi.sum $(DEPLOY_MFSEL)/dezouart.rom \
	       $(DEPLOY_MFSEL)/dezouart.sum
	@# The pre-hierarchy names, in the one place they can still do harm: a tree
	@# built before the layout changed has SIX files loose at the top of
	@# build/deploy/, and the listing below would print them as instructions to
	@# copy something to the card's root. Deletable once no such tree exists,
	@# which is not a thing this Makefile can know.
	@#
	@# The sixth is `mfinstall`, and it is swept HERE as well as in that target's
	@# own recipe: `make mfselect` alone is a supported build, and a stale flat
	@# copy left by it would be listed as `/mfinstall` beside the correct
	@# `/dot/mfinstall`. Found by the reviewer, by making the stale tree.
	@rm -f $(DEPLOY)/mfselect.nex $(DEPLOY)/dezowifi.rom $(DEPLOY)/dezowifi.sum \
	       $(DEPLOY)/dezouart.rom $(DEPLOY)/dezouart.sum $(DEPLOY)/mfinstall
	@cp -f $(MFSELECT_NEX) $(DEPLOY_MFSEL)/mfselect.nex
	@cp -f $(ROM_WIFI)     $(DEPLOY_MFSEL)/dezowifi.rom
	@cp -f $(SUM_WIFI)     $(DEPLOY_MFSEL)/dezowifi.sum
	@cp -f $(ROM_UART)     $(DEPLOY_MFSEL)/dezouart.rom
	@cp -f $(SUM_UART)     $(DEPLOY_MFSEL)/dezouart.sum
	@echo
	@echo "$(DEPLOY)/ is ready — copy it onto the card, keeping the layout:"
	@echo
	@$(deploy_listing)
	@echo
	@echo "  i.e.  cp -r $(DEPLOY)/* /path/to/card/"
	@echo
	@echo "  Nothing to rename and nothing to place by hand. Each .rom and its"
	@echo "  .sum come from this one build, which makes them a coherent set."

# The deploy listing, shared by `mfselect` and `mfinstall` because both print it
# and two renderings of one layout is how they start to disagree.
#
# IT NO LONGER DECIDES WHERE ANYTHING GOES, and that is the point of the
# hierarchy. It used to map basename to destination with an awk conditional —
# `mfinstall` to /dot/, everything else to /mfselect/ — which is a second copy
# of a fact the build already knows, in the one line a user follows literally.
# `%P` prints each file's path relative to $(DEPLOY), so the directory answers
# the question and the listing only reads it back.
deploy_listing = find $(DEPLOY) -type f -printf '    /%P\n' | sort

# mfinstall needs BOTH ROMs and both .sums on the card exactly as mfselect does
# — it installs the same files by a different route — so it depends on the
# target that produces them rather than shipping a second, thinner deploy
# directory that could disagree with the first.
#

# Build the .mfinstall dot command (issue #21) and everything it installs
mfinstall: $(MFINSTALL_DOT) mfselect
	@mkdir -p $(DEPLOY_DOT)
	@rm -f $(DEPLOY_DOT)/mfinstall $(DEPLOY)/mfinstall
	@cp -f $(MFINSTALL_DOT) $(DEPLOY_DOT)/mfinstall
	@# THE ONE THING A BUILD CAN CHECK ABOUT THE CONFIG FILE, and it is a real
	@# failure mode rather than a formality: read_config() reads CHUNK-1 = 511
	@# bytes ONCE (tools/mfinstall/mfinstall.c) and scans only those, so an
	@# `install:` line pushed past byte 511 by a longer preamble is a file the
	@# dot command reports as unreadable. Nothing else here bounds it.
	@#
	@# The shipped file is one line and has no preamble to grow, by decision
	@# (user, 2026-08-07) — and `--configure` rewrites it in that same form. The
	@# guard is therefore aimed at a file a USER has edited by hand, which is
	@# the only way a preamble can get in now.
	@test $$(wc -c < $(MFINSTALL_YML)) -le 511 || \
	  { echo "$(MFINSTALL_YML) is over 511 bytes; read_config() would not see all of it"; exit 1; }
	@cp -f $(MFINSTALL_YML) $(DEPLOY_MFSEL)/mfinstall.yml
	@echo
	@echo "$(DEPLOY)/ is ready — copy it onto the card, keeping the layout:"
	@echo
	@$(deploy_listing)
	@echo
	@echo "  i.e.  cp -r $(DEPLOY)/* /path/to/card/"
	@echo
	@echo "  mfinstall.yml is a DEFAULT and says wifi. On the Next:"
	@echo
	@echo "    .mfinstall --load wifi        install now, until power-off"
	@echo "    .mfinstall --configure uart   change what --auto does at boot"
	@echo
	@echo "  An install writes SRAM, never the card, and lasts until power-off."

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

# The .mfinstall bench (issue #21). Deliberately NOT part of `make test`, for
# the reason every other bench here is not: `make test` is the screenshot bench
# and mfinstall is separate tooling, exactly as `test-mfselect` is. It binds no
# port and needs no external dependency; it is out because of what it is, not
# because of what it needs.
#
# The bare '#' below ends this block for the help scanner, which takes the LAST
# '# ' line before a target as its description.
#

# Run the mfinstall headless bench (12 jnext runs, 9 checks; not part of `make test`)
test-mfinstall: mfinstall
	@$(MAKE) --no-print-directory DIVMMC_OFF=0 $(OUT)/mfinstall-dmoff0
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" DOT="$(OUT)/mfinstall" \
	 DOT_DMOFF0="$(OUT)/mfinstall-dmoff0" \
	 CONF_WIFI="$(DEPLOY_MFSEL)/mfinstall.yml" \
	 ROM_UART="$(ROM_UART)" SUM_UART="$(SUM_UART)" \
	 ROM_WIFI="$(ROM_WIFI)" SUM_WIFI="$(SUM_WIFI)" \
	 ROMSUM="$(ROMSUM)" SCREENDIFF="$(TEST)/screen-diff.py" \
	 SCREENTEXT="$(TEST)/screen-text.py" $(TEST)/run-mfinstall.sh

# Run the ESP-01 server bench (M0(b): 1 jnext run + a TCP client; not part of `make test`)
test-esp: $(ESP_BIN)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" ESP_BIN="$(ESP_BIN)" \
	 $(TEST)/run-esp.sh

# Run the DZRP conformance suite against OUR OWN WiFi stub in jnext (1 run + a TCP client)
test-dzrp-stub:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM="$(OUT)/enNextMf-wifi.rom" DZRP_ARGS="$(DZRP_ARGS)" $(TEST)/run-dzrp-stub.sh

# The session line on the Next's own screen (issues #14 and #23): six jnext runs.
# Five are judged by READING row 8 back as text with the ZX ROM font rather than
# by comparing runs — comparing runs cannot tell a correct pair of labels from a
# swapped one, see ERRORS.md and test/run-client-status.sh.
#
# N4 and N5 are the client that VANISHES without CMD_CLOSE, which is what the
# module's `<id>,CLOSED` line is tracked for. They differ in where the stub is
# standing when it arrives, and N5 asserts a clean error area so that the two
# runs cannot silently exercise one code path and claim two.
#
# N6 is the sixth run and the only one judged over the SOCKET: the repaint N5
# exercises writes at 0x4000, which is the screen only while MMU slot 2 says so,
# and CMD_SET_SLOT lets any client move it. It parks a probe in the retargeted
# bank and requires it back untouched.
#
# Run the client-session status line bench (6 jnext runs; not part of `make test`)
test-client-status:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM="$(OUT)/enNextMf-wifi.rom" $(TEST)/run-client-status.sh

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

# Two things that used to be able to stop the debugger dead (issue #16):
# cmd_loop's wait for the next command, which had no bound at all, and an
# AT+CIPSEND that announced a length and then walked away without writing it.
# Neither is reachable by an ordinary run — the first needs a client that goes
# quiet WITHOUT hanging up, the second needs the module to answer later than the
# stub will wait — so N1 moves the bound to zero (the loop as it was) and N3
# moves the send budget under the emulator's own latency.
# See test/run-no-hang.sh, which also says what its evidence does NOT cover.
#
# N2 runs the SHIPPED WiFi ROM, so the two halves of the pair differ by exactly
# one constant. The probe ROMs get their own names via WAIT_SECS/RX_WAIT, so
# none can be left where a shipped ROM is read from.
#
# Run the hang-safety bench (4 jnext runs; not part of `make test`)
test-no-hang: $(ROM_WIFI)
	@$(MAKE) --no-print-directory TRANSPORT=wifi WAIT_SECS=0 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi RX_WAIT=400 TX_PASSES=1 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi RX_WAIT=400 TX_PASSES=1 FAULT_LIMIT=1 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_UNBOUND="$(OUT)/enNextMf-wifi-wait0.rom" \
	 ROM_BOUND="$(ROM_WIFI)" \
	 ROM_SLOWPROMPT="$(OUT)/enNextMf-wifi-rxwait400-txp1.rom" \
	 ROM_RECOVER="$(OUT)/enNextMf-wifi-rxwait400-txp1-fl1.rom" $(TEST)/run-no-hang.sh

# ---------------------------------------------------------------------------
# Do the module's inbound slots come back? — issue #19.
#
# Nothing in the stub had ever closed an established connection, so a peer that
# wedged rather than closing kept its slot for the rest of the power-on session.
# esp_recover now sweeps every link id with AT+CIPCLOSE, and this is what shows
# it: fill the slots, confirm the module stops granting them, inject one fault
# so the recovery runs, and require a FRESH client to be served afterwards.
#
# Both ROMs are FAULT_LIMIT=1, the seam run-no-hang.sh's N4 already uses, since
# five consecutive faults cannot be produced against an emulator that answers
# everything. S3 adds LINK_IDS=0 — esp_recover assembled exactly as it was — so
# S1 and S3 differ in one constant, which is what attributes S1's green to the
# sweep rather than to the recovery it rides in.
#
# It needs jnext >= 0.99.127 (jnext#211's AT+CIPCLOSE=<id>) and binds a host TCP
# port, so it is not part of `make test`. It says NOTHING about a real ESP-01,
# whose ceiling differs from the emulator's by design; see the script's header.
#
# Run the slot-recovery bench (2 jnext runs, 3 checks; not part of `make test`)
test-slot-recovery:
	@$(MAKE) --no-print-directory TRANSPORT=wifi FAULT_LIMIT=1 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi FAULT_LIMIT=1 LINK_IDS=0 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_SWEEP="$(OUT)/enNextMf-wifi-fl1.rom" \
	 ROM_NOSWEEP="$(OUT)/enNextMf-wifi-fl1-li0.rom" $(TEST)/run-slot-recovery.sh

# ---------------------------------------------------------------------------
# The module's own idle timeout — issue #24.
#
# `AT+CIPSTO` is the ESP's TCP-server idle timeout, and its firmware default of
# 180 seconds hangs up on a DeZog session while its user reads code: measured on
# a real Next at 182.5 s and 181.8 s, and confirmed with the real client, which
# simply ended the session with the stub perfectly healthy. The stub now sets it
# to 1800 on every bring-up and READS the answer, since a module too old for the
# command answers ERROR and that is not a reason to refuse to debug.
#
# The shipped value cannot be watched to work — half an hour per run — so
# SERVER_TIMEOUT moves it to something a bench can sit out, and K1/K2 differ in
# that one constant. An out-of-range value is the only way to execute the ERROR
# arm, and CIPSTO_STRICT=1 assembles that step with esp_command_ok so the
# refusal becomes a bring-up failure: the controlled removal K3 needs.
#
# It needs jnext >= 0.99.141 (jnext#240's AT+CIPSTO) and binds a host TCP port,
# so it is not part of `make test`. It says NOTHING about a real ESP-01: jnext
# models this command FROM the hardware measurement above, so a green run shows
# the stub sends it and reads the answer, not that a module obeys.
#
# Run the AT+CIPSTO idle-timeout bench (4 jnext runs, 4 checks; not part of `make test`)
test-cipsto:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi SERVER_TIMEOUT=10 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi SERVER_TIMEOUT=7201 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi SERVER_TIMEOUT=7201 CIPSTO_STRICT=1 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_SHORT="$(OUT)/enNextMf-wifi-sto10.rom" \
	 ROM_SHIPPED="$(ROM_WIFI)" \
	 ROM_REFUSED="$(OUT)/enNextMf-wifi-sto7201.rom" \
	 ROM_STRICT="$(OUT)/enNextMf-wifi-sto7201-stostrict1.rom" $(TEST)/run-cipsto.sh

# ---------------------------------------------------------------------------
# The link negotiated up from 115200 — issue #25.
#
# The stub greets the module at 115200, asks it to move to ESP_BAUD_HIGH
# (1000000 as shipped), moves its own prescaler to match, and comes back down if
# the module refuses or the link does not survive. BAUD_HIGH is the seam: the
# shipped rate, a rate the module refuses, and the rate that assembles the whole
# negotiation out.
#
# THE DISCRIMINATING ASSERTION IS jnext's UART LOG, not behaviour. The emulated
# module never compares the rate it was asked for against the rate it is spoken
# to, so a stub that told the module and forgot its own side serves exactly as
# well here as one that did it properly. jnext logs every prescaler the guest
# programs, which is a direct reading of the half that would otherwise be
# invisible.
#
# It binds a host TCP port, so it is not part of `make test`. IT SAYS NOTHING
# ABOUT THE RATE: whether a real ESP-01 takes 1000000, and at what error, is
# `make test-hardware` and nothing else. It never reaches the bring-up probe
# either — jnext's module answers at the first rate asked, every time.
#
# Run the baud-negotiation bench (5 jnext runs, 5 checks; not part of `make test`)
test-baud:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi BAUD_HIGH=460800 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi BAUD_HIGH=6000000 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi BAUD_HIGH=1000000 mf-rom
	@$(MAKE) --no-print-directory TRANSPORT=wifi BAUD_HIGH=460800 FAULT_LIMIT=1 mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM_HIGH="$(OUT)/enNextMf-wifi-baud460800.rom" \
	 ROM_REFUSED="$(OUT)/enNextMf-wifi-baud6000000.rom" \
	 ROM_OFF="$(ROM_WIFI)" \
	 ROM_RECOVER="$(OUT)/enNextMf-wifi-fl1-baud460800.rom" \
	 ROM_CEILING="$(OUT)/enNextMf-wifi-baud1000000.rom" $(TEST)/run-baud.sh

# ---------------------------------------------------------------------------
# The DZRP screen reader (test/dzrp/screen.py) and its validation.
#
# The reader turns doc/HARDWARE-TESTING.md's S1-S4 — observations that needed a
# human with a camera — into numbers, by fetching the stub's own display file
# with CMD_READ_MEM 0x4000,6912. It has to be trusted on hardware, where there
# is nothing to check it against; `test-screen-agreement` is where it is
# earned, because under jnext there are TWO independent views of the same
# screen (the emulator's PNG and the DZRP read) and they must agree.
#
# G2 runs with a real error painted on the screen, because a reader checked
# only against a blank error area has been checked against the case where every
# wrong answer agrees with the right one on zero.
#
# Not part of `make test`: it binds a host TCP port.
# ---------------------------------------------------------------------------

# Validate the DZRP screen reader against jnext's own picture (2 jnext runs)
test-screen-agreement: $(ROM_WIFI)
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM="$(ROM_WIFI)" $(TEST)/run-screen-agreement.sh

# Read and print the stub's own screen over DZRP (NEXT_IP=<ip>)
read-screen:
	@test -n "$(NEXT_IP)" || { \
	  echo "usage: make read-screen NEXT_IP=<ip>   (the Next's address, port 11000)"; \
	  echo "  Prints the stub's screen: the error area, the connect block and the"; \
	  echo "  session line — doc/HARDWARE-TESTING.md's S1-S4, without a camera."; \
	  echo "  It sends NO CMD_INIT, so it does not clear the error it is reading."; \
	  echo "  It CANNOT see the border; that is still a human's job."; \
	  exit 2; }
	python3 $(TEST)/dzrp/screen-client.py --host "$(NEXT_IP)" $(SCREEN_ARGS)

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

# ---------------------------------------------------------------------------
# ESP-module probes. INSTRUMENTS, NOT GATES.
#
# `make test` is a gate: it says whether the thing still works. These targets
# are not, and must never be folded into one. They MEASURE — how many clients
# the module will hold, what a peer that vanishes without a FIN or a RST costs,
# and how long the module leaves an idle connection alone — because issue #15
# has never been reproduced deliberately and the first job is to make a positive
# reproduction possible. They print numbers, not verdicts: a probe that said
# PASS would be asserting a conclusion nobody has.
#
# Probe C is the odd one of the three and is here for the family rather than for
# #15: its subject is the module's own idle timeout (`AT+CIPSTO`), which BOUNDS
# #19's slot leak at about three minutes and which issue #24 lengthened on
# purpose. It is also the only way to show, from the PC, that the value the
# SHIPPED ROM sends is the value a real module then obeys — `make test-cipsto`
# shows the stub sends it, against a jnext modelled on our own measurement.
#
# The hypothesis A and B test is that #15 IS #19. #15's `RX Timeout`, frozen border
# and hung client are explained by the CRLF swallow band fixed in 000E; its
# POWER CYCLE and its degrading TCP accept latency (83 ms -> 389 ms -> timeout)
# are not, and both sit on the module's side of the UART where the Z80 cannot
# reach. #19 says nothing ever frees an inbound slot and a power cycle is the
# only thing that does.
#
# `probe-jnext` FIRST, ALWAYS. A probe that never worked reports a negative
# result indistinguishable from a real one, and this project has already been
# handed one of those (ERRORS.md, the hardware sweep whose harness misread a
# DZRP response length). It checks probes A and B find jnext's OWN documented
# ceiling before either is pointed at a machine whose ceiling is the unknown.
#
# IT DOES NOT COVER PROBE C, and cannot as things stand: whether jnext models
# `AT+CIPSTO` at all is unknown, so the emulator has no known answer for C to be
# checked against. What stands in for it is in-band — C's own R0 and its closing
# screen read, which say the probe was working at both ends of its wait — plus
# `test/idle-drop-fake-peer.py`, against which its branch wordings are exercised
# in seconds rather than minutes.
#
# See doc/HARDWARE-TESTING.md.
# ---------------------------------------------------------------------------

# Validate probes A and B against jnext before trusting them on hardware
probe-jnext:
	@$(MAKE) --no-print-directory TRANSPORT=wifi mf-rom
	@JNEXT="$(JNEXT)" SD_IMAGE="$(SD_IMAGE)" OUT="$(OUT)" \
	 ROM="$(ROM_WIFI)" $(TEST)/run-probes-jnext.sh

# Probe A: how many clients the module holds, and if a close gives one back (NEXT_IP=<ip>)
probe-slots:
	@test -n "$(NEXT_IP)" || { \
	  echo "usage: make probe-slots NEXT_IP=<ip>   (the Next's address, port 11000)"; \
	  echo "  Run 'make probe-jnext' FIRST: it checks the probe can find a ceiling"; \
	  echo "  it already knows, which is the only thing that makes a hardware number"; \
	  echo "  worth reading. Read doc/HARDWARE-TESTING.md, and watch the SCREEN."; \
	  exit 2; }
	python3 $(TEST)/slot-ceiling-probe.py --host "$(NEXT_IP)" $(PROBE_ARGS)

# Probe B needs root, so `sudo` is on the SCRIPT rather than on `make`: the
# build system has no business running as root, and the script is the thing
# whose header states every firewall rule it adds. It refuses to run without
# root and offers --dry-run, so a user can audit it before typing a password.
#
# Probe B: is an abandoned connection slot EVER reclaimed without a power cycle (NEXT_IP=<ip>)
probe-vanished:
	@test -n "$(NEXT_IP)" || { \
	  echo "usage: make probe-vanished NEXT_IP=<ip>   (needs sudo; adds ONE firewall chain)"; \
	  echo "  Audit it first:  $(TEST)/run-vanished-peer.sh --host <ip> --dry-run"; \
	  echo "  If a run is interrupted:  sudo $(TEST)/run-vanished-peer.sh --clean"; \
	  echo "  Run 'make probe-jnext' FIRST. Read doc/HARDWARE-TESTING.md."; \
	  exit 2; }
	sudo $(TEST)/run-vanished-peer.sh --host "$(NEXT_IP)" $(PROBE_ARGS)

# THE EXPECTED TIMEOUT IS AN ARGUMENT AND HAS NO DEFAULT, deliberately. The
# probe cannot read `AT+CIPSTO?` — that needs `.UART` at the machine — so a
# built-in number would be this tool asserting a property of a module it never
# asked. Without one it prints the measurement and attributes nothing; with one
# it says whether the two agree, and a disagreement is a FINDING and still not a
# failure. It never exits non-zero on the comparison.
#
# Minutes, not seconds: at the ESP-AT default of 180 s the whole run is about
# four. Against the shipped ROM, which sets `AT+CIPSTO=1800` since issue #24, a
# run that CONFIRMS the value takes over half an hour — so a shorter --deadline
# is the ordinary thing to pass, and the probe then reports a lower bound and
# says so.
#
# Probe C: how long the module leaves an IDLE connection alone (NEXT_IP=<ip>)
probe-idle-drop:
	@test -n "$(NEXT_IP)" || { \
	  echo "usage: make probe-idle-drop NEXT_IP=<ip>   (the Next's address, port 11000)"; \
	  echo "  Pass what you expect, or nothing is attributed to the number:"; \
	  echo "    PROBE_ARGS=\"--expect-timeout 1800 --deadline 400\"   a CURRENT ROM"; \
	  echo "    PROBE_ARGS=\"--expect-timeout 180\"    before issue #24, or if the"; \
	  echo "                                          module refused AT+CIPSTO"; \
	  echo "  Read the real value at the machine with .UART:  AT+CIPSTO?"; \
	  echo "  Minutes per run, and it renders no verdict. Read doc/HARDWARE-TESTING.md."; \
	  exit 2; }
	python3 $(TEST)/idle-drop-probe.py --host "$(NEXT_IP)" $(PROBE_ARGS)

# The build number is two bytes and, since issue #20, is READ as two: the high
# one says which series and is moved deliberately, the low one counts the merges
# inside it. So there are two targets, and neither can do the other's job:
#
#   make bump         00.0E -> 00.0F     one merge to main that changed a ROM
#   make bump-major   00.0F -> 01.00     a release or a milestone
#
# `bump` DOES NOT CARRY INTO THE HIGH BYTE. At 00.FF it refuses and names
# bump-major, rather than silently minting a new series nobody decided on —
# which is the whole reason the high byte exists. Both refuse to leave FF.FF.
#
# Increment the low byte of the ROM build number (one bump per merge to main)
bump:
	@cur=$$(awk '/^build_number:/ { v = $$2; gsub(/"/, "", v); print v }' $(VERSION_FILE)); \
	case "$$cur" in [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;; \
	  *) echo "ERROR: build_number in $(VERSION_FILE) is not four hex digits: '$$cur'" >&2; exit 1;; \
	esac; \
	n=$$(( 0x$$cur )); \
	if [ $$(( n & 255 )) -eq 255 ]; then \
	  echo "ERROR: build_number $$cur: the low byte is already FF." >&2; \
	  echo "       Use 'make bump-major' — bump does not carry into the high byte." >&2; \
	  exit 1; \
	fi; \
	next=$$(printf '%04X' $$(( n + 1 ))); \
	sed -i "s/^build_number:.*/build_number: \"$$next\"/" $(VERSION_FILE); \
	printf 'build_number %s -> %s   (shown as %s; ROM magic becomes DeZoGiFnG_<VARIANT>_%s)\n' \
	  "$$cur" "$$next" "$$(printf '%s' "$$next" | sed 's/../&./')" "$$next"

# Increment the HIGH byte of the ROM build number, resetting the low one to 00
bump-major:
	@cur=$$(awk '/^build_number:/ { v = $$2; gsub(/"/, "", v); print v }' $(VERSION_FILE)); \
	case "$$cur" in [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;; \
	  *) echo "ERROR: build_number in $(VERSION_FILE) is not four hex digits: '$$cur'" >&2; exit 1;; \
	esac; \
	n=$$(( 0x$$cur )); \
	if [ $$(( n >> 8 )) -ge 255 ]; then \
	  echo "ERROR: build_number $$cur: the high byte is already FF, and FF.FF is the end" >&2; \
	  exit 1; \
	fi; \
	next=$$(printf '%04X' $$(( ((n >> 8) + 1) << 8 ))); \
	sed -i "s/^build_number:.*/build_number: \"$$next\"/" $(VERSION_FILE); \
	printf 'build_number %s -> %s   (shown as %s; ROM magic becomes DeZoGiFnG_<VARIANT>_%s)\n' \
	  "$$cur" "$$next" "$$(printf '%s' "$$next" | sed 's/../&./')" "$$next"


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

# The relocated config-mode window, assembled at its own fixed address. The
# output path is a -D as it is for every other fixture here, so nothing is
# written into the source tree.
$(MFWIN_BIN): $(MFWIN_ASM) Makefile | $(OUT)
	$(SJASMPLUS) -DMFWIN_BIN=\"$@\" $(MFWIN_FLAGS) $(MFWIN_ASM)

# ... and the same bytes as a C array. `xxd -i` derives the array's name from
# the FILE's name, so the binary is copied to `mfwin_bin` first; patching the
# symbol afterwards would be a sed expression that has to keep matching xxd's
# output format.
$(MFWIN_H): $(MFWIN_BIN) Makefile | $(OUT)
	@mkdir -p $(MFWIN_INCDIR)
	@cp -f $(MFWIN_BIN) $(MFWIN_INCDIR)/mfwin_bin
	xxd -i -n mfwin_bin $(MFWIN_INCDIR)/mfwin_bin > $@
	@echo '#define MFWIN_BIN_LEN mfwin_bin_len' >> $@
	@rm -f $(MFWIN_INCDIR)/mfwin_bin

# The dot command. -I finds the generated header; zcc leaves its intermediates
# beside the -o basename, which is $(OUT), for the same reason mfselect's rule
# does.
#
# WHY IT LINKS TO ONE NAME AND SHIPS UNDER ANOTHER. On the z88dk installed here,
# `-subtype=dot -create-app` leaves the -o file EMPTY and writes the actual dot
# command to <name>_CODE.bin — reproduced with z88dk's own `touch` example, so
# it is the toolchain and not this program. Rather than hardcode that, the rule
# takes whichever of the two is non-empty, so a z88dk that stops doing it keeps
# working; and it FAILS LOUDLY if neither is, because the alternative is
# shipping a zero-byte file that a user discovers on the machine.
#
# THE SIZE CHECK IS NOT DECORATION EITHER. A dot command is limited to the 8 KB
# page mapped at 0x2000, and z88dk's own documentation puts the practical
# ceiling nearer 7 KB under stock esxdos. Over that it does not fail to build —
# it fails to LOAD, on the machine, with an error that says nothing about size.
$(MFINSTALL_DOT): $(MFINSTALL_C) $(MFWIN_H) Makefile | $(OUT)
	$(ZCC) $(ZCCDOTFLAGS) -I$(MFWIN_INCDIR) $(MFINSTALL_C) -o $(OUT)/mfinstall-app$(MFWIN_SUFFIX)
	@bin=$(OUT)/mfinstall-app$(MFWIN_SUFFIX)_CODE.bin; \
	[ -s "$$bin" ] || bin=$(OUT)/mfinstall-app$(MFWIN_SUFFIX); \
	if [ ! -s "$$bin" ]; then \
	  echo "ERROR: zcc produced no dot command binary for $(MFINSTALL_C)" >&2; exit 1; \
	fi; \
	size=$$(stat -c%s "$$bin"); \
	if [ "$$size" -gt 8192 ]; then \
	  echo "ERROR: the dot command is $$size bytes, over the 8192-byte page it loads into" >&2; \
	  exit 1; \
	fi; \
	cp -f "$$bin" $(MFINSTALL_DOT); \
	echo "  $(MFINSTALL_DOT): $$size bytes (the dot command page is 8192)"

$(ROM_SUM): $(ROM) $(ROMSUM) | $(OUT)
	python3 $(ROMSUM) $(ROM) > $@

$(OUT):
	mkdir -p $@
