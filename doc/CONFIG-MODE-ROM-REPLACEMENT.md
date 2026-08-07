# Replacing the Multiface ROM at run time, with config mode

**The VHDL analysis behind [issue #21](https://github.com/jorgegv/dezogif_ng/issues/21), and the
record of what was measured on top of it.** It was written as *input to a design, not a design*, and
that is still what most of it is: the consumer it was written for now exists — **`.mfinstall`**, a
dot command that installs the debugger from the NextZXOS command line or from `AUTOEXEC.BAS` instead
of swapping a file on the SD card. For how to *use* it, read [MFINSTALL.md](MFINSTALL.md); this
document is why it is shaped the way it is.

**Scope: the delivery mechanism only.** Nothing about the stub, the DZRP layer, the transports or
the identity block changes. This is about how the 8 KB image gets into Multiface ROM space and how a
user turns it on and off.

**MOST OF THIS HAS NOW BEEN RUN, AND ONE THING IN IT WAS WRONG BY OMISSION.** This document opened
with "Nothing here has been run" until 2026-08-06, when three measurement rounds in jnext under a
booted NextZXOS turned the analysis into a working tool — `.mfinstall`, `tools/mfinstall/`, bench
`make test-mfinstall`, and [MFINSTALL.md](MFINSTALL.md). What changed, in one place, is §1.2c: the
five-way priority contest below is complete about the FPGA and says nothing about the **NextZXOS
runtime**, and the intended caller's own execution context is what takes the window away. Every
mechanical claim is still read from the FPGA VHDL — this project's first hard rule, and the reason
the two contradictory Discord accounts in #21 are both corrected rather than picked between. The
status of every claim, at its own tier, is in the table at the end.

**What has been run, and what has not:**

| | |
|---|---|
| **Run, in jnext** | the whole §1.5 sequence as `tools/mfinstall/mfwin.asm`, including entering and leaving config mode, the DivMMC bridge, the `rst 8` re-arm and the read-back; an 8192-byte ROM installed in two 4 KB passes and verified inside the window; the stub taken live by an M1 button NMI **with no soft reset** |
| **Run, with a control** | that **turning DivMMC off is the load-bearing step** — the identical routine with DivMMC left on, one assembler constant apart, reproduces the blocked result from the same code location |
| **NOT run** | any of it on **real hardware**. jnext's config-mode model cites the same VHDL lines this document does, so agreement between them is not independent evidence |
| **NOT run** | anything **thrown at the window** — no interrupt or NMI was aimed at it, and the expansion-bus hazard in §1.5 has never been provoked |
| **Still open** | whether the `NEXTREG 2,1` in taylorza's example is required **on silicon**. In the emulator it is not: bench I2 |

**The first version of this document was rejected in review for three defects of its own**, all
found by reading the same VHDL more carefully: it described the priority contest as two-way when it
is four-way, it did not mention that config mode remaps the interrupt vectors along with everything
else, and it instructed the caller to save and restore a register that cannot be read. Those are
corrected below and called out where they were wrong, because a reader of a document like this needs
to know which parts have been contested.

---

## 1. The mechanism, verified

### 1.1 Where the Multiface ROM actually is

`zxnext.vhd:3029-3035`. When the CPU addresses `0x0000-0x3FFF` and the Multiface memory is paged in:

```vhdl
if cpu_a(15 downto 14) = "00" then
   if mf_mem_en = '1' then
      sram_pre_A21_A13 <= "00000101" & cpu_a(13);
      sram_pre_rdonly  <= not cpu_a(13);
```

So SRAM address bits A21-A14 are `0x05` and A13 follows the CPU. In 16 KB units that is **bank 5**,
and the CPU's A13 splits it:

| A13 | CPU range | 8 KB page | contents | `rdonly` |
|---|---|---|---|---|
| 0 | `0x0000-0x1FFF` | `0x0A` | **Multiface ROM** | **1 — read-only** |
| 1 | `0x2000-0x3FFF` | `0x0B` | Multiface RAM | 0 — writable |

This confirms the wiki/Discord claim that the MF ROM is *the bottom half of config bank 5*, and it
agrees with upstream's own design doc, which says the NMI entry sees MF ROM at `0x0000` and MF RAM
at `0x2000`.

**It also shows why config mode is needed at all**: through the ordinary Multiface path the ROM half
is `rdonly`. Paging the Multiface in and writing to `0x0000` does nothing.

### 1.2 What config mode changes

`zxnext.vhd:3044-3050`, the branch immediately below:

```vhdl
elsif nr_03_config_mode = '1' then
   sram_pre_A21_A13 <= nr_04_romram_bank & cpu_a(13);
   sram_pre_active  <= '1';
   sram_pre_rdonly  <= '0';
```

So in config mode, `0x0000-0x3FFF` is served from SRAM at **NR `0x04` as the 16 KB bank index**,
with A13 from the CPU as before — and **`rdonly` is `0`**. The same 16 KB the Multiface occupies
becomes ordinary writable memory when `NR 0x04 = 5`.

### 1.2b Config mode is THIRD in priority, and there is a second arbiter after it

The first version of this document said the contest was two-way — Multiface versus config mode — and
that was wrong in a way that matters. `zxnext.vhd:3029-3052` is **four-way**:

```vhdl
if cpu_a(15 downto 14) = "00" then
   if    mf_mem_en = '1'          then   -- Multiface overlay, ROM half read-only
   elsif mmu_A21_A13(8) = '0'     then   -- an ordinary MMU-mapped RAM page in slot 0/1
   elsif nr_03_config_mode = '1'  then   -- config mode, writable
   else                                  -- the normal ROM serving path
```

So **two** things beat config mode, not one. The second is the ordinary MMU: if slot 0 or 1 currently
holds a RAM page rather than a ROM mapping, that branch serves it and config mode never runs.

**MEASURED SINCE: a dot command's MMU0 and MMU1 are both `0xFF`**, the ROM mapping, so this branch is
not the one that wins — §1.2c, where it mattered because it is what excludes the MMU as the cause of
the blocked write. `tools/mfinstall/mfwin.asm` forces MMU0 to `0xFF` anyway and restores it, because a
value that happens to be right is not a value that was checked, and nothing here says what the MMU
holds on a machine set up differently.

**And a second arbiter runs afterwards**, `zxnext.vhd:3084-3132`, which can override the address the
branch above just computed. Config mode sets `sram_pre_override <= "110"` (`:3050`), which
deliberately **leaves DivMMC and Layer 2 eligible**:

```vhdl
if sram_pre_override(2) = '1' and divmmc_rom_en = '1' then   -- :3084, and rdonly
elsif sram_layer2_map_en = '1' then                          -- :3100
```

A **dotcommand runs through esxDOS**, which is DivMMC, and re-enters automap on every `RST 8`. So
this is not a remote edge case for the intended caller: if DivMMC ROM is mapped at the moment of the
write, the write lands on a read-only path and does nothing, silently.

**AND THEY DO NOT ALL FAIL THE SAME WAY. Two of them are silent CORRUPTION, not a no-op**, which the
first two versions of this document got wrong in the more dangerous direction:

| branch | line | `rdonly` | what a misdirected `LDIR` does |
|---|---|---|---|
| Multiface overlay, ROM half | `:3035` | `1` | **nothing** — the write is discarded |
| **MMU RAM page in slot 0/1** | `:3042` | **`0`** | **writes into whatever page is actually mapped there** — NextZXOS working RAM, system variables, anything |
| DivMMC ROM | `:3089` | `1` | **nothing** |
| **DivMMC RAM** | `:3097` | `divmmc_rdonly` | **conditionally writes** into DivMMC RAM |
| **Layer 2 write-map** | `:3105` | **`0`** | **writes into Layer 2 graphics memory** |

So "the write silently does nothing" is true of exactly two of the five, and a caller who assumes
inertness for the others has already destroyed something by the time they notice. **The dotcommand
must establish its memory state deliberately** — not rely on the write failing safely if it has not.

**None of this is an argument against the mechanism**; `tbblue.fw` uses it successfully. It is an
argument that the window has to be entered from a known state.

### 1.2c THE SIXTH HAZARD: the intended caller's own context takes the window away

**MEASURED, 2026-08-06.** The five hazards above are all things a careful caller can avoid. There is
a sixth, and it is **structural rather than a hazard to be careful about**: a dot command cannot
reach bank 5 at all, as it stands. Nothing in the VHDL analysis above could have said so, because it
is a fact about the **NextZXOS runtime** and not about the FPGA — which is why it had to be measured.

A minimal probe dot command entered config mode, selected bank 5, and read eight bytes at `0x0000`
and at `0x1FE0`. The `0x0000` row is the discriminator, and it is unambiguous:

| first 8 bytes at `0x0000` | which ROM |
|---|---|
| what the probe read: `F3 C3 6A 00 44 56 09 02` | **`enNxtmmc.rom` — the DivMMC ROM**, byte-exact |
| `enNextMf.rom` (config bank 5, low half) | `F5 3E 02 CD 69 00 F1 C9` — not what was read |

The write at `0x1FE0` did not stick. `MMU0 = MMU1 = 0xFF` in the same reading, so the *MMU* branch
did not win either: it was the **DivMMC second arbiter**, exactly as the paragraph above warns, and
for a reason no dot command can dodge —

* **DivMMC page0 and page1 are enabled TOGETHER.** `divmmc.vhd:94-95` gates both on
  `conmem = '1' or automap = '1'`. There is no state in which DivMMC RAM is at `0x2000` and `0x0000`
  is free. **A command executing at `0x2000` out of DivMMC RAM therefore NECESSARILY has DivMMC at
  `0x0000`.**
* **And page0 is unconditionally read-only there** — `divmmc.vhd:100`.

Measured for this invocation: **port `0xE3` = `0x82`**, i.e. CONMEM = 1, MAPRAM = 0, DivMMC bank 2.
A dot command is mapped by **CONMEM**, not by automap. Also `SP = 0xFF2B` (already high),
`MMU2 = 0x0A`, `MMU3 = 0x0B` (so `0x4000-0x5FFF` is the display file, ordinary main RAM),
`NR03 = 0x33`, `NR0A = 0x11`, `NR81 = 0x80` (bit 5 clear, so the expansion-bus NMI hazard was not
armed), `0x123B = 0x00`.

**There is no other route to that page.**
`mmu_A21_A13 <= ("0001" + ('0' & mem_active_page(7 downto 5))) & mem_active_page(4 downto 0)`
(`zxnext.vhd:2964`) is `page + 32`, so an MMU value N reaches physical 8K page N+32 and pages 0-31 —
which include the Multiface ROM at page `0x0A` — are unreachable from `NEXTREG 0x50` at **any** value.
Config mode is the only door.

#### The fix, and the control that attributes it

**Relocate the critical section above `0x4000` and turn DivMMC OFF for the window.** Everything at
`0x2000` — the command's own code and statics — vanishes with it, which is what makes the relocation
necessary rather than tidy. Then, and this is the part that had to be measured rather than argued:

| run | one variable | 8 bytes read at `0x0000` inside the window | verdict |
|---|---|---|---|
| **A** | the full sequence | `F5 3E 02 CD 69 00 F1 C9` = **`enNextMf.rom`** | **LANDED**, and the command survived |
| **B** | no `rst 8` re-arm | same | **LANDED**, survived |
| **C** | **DivMMC left ON** | `F3 C3 6A 00 44 56 09 02` = **the DivMMC ROM** | **BLOCKED**, survived |

**C is the point.** It differs from B in one assembler constant and is otherwise identical — same
relocation, same MMU0, same layer-2 clear, same config-mode entry and exit — and it reproduces the
blocked result **from a different code location**. So relocating above `0x4000` is *not* what fixes
this; **turning DivMMC off is**, and relocation is merely what makes turning it off survivable.

#### Every piece of state the window disturbs can be READ BACK, so nothing is guessed

This is what makes the restore exact instead of hopeful, and it is the other thing the measurement
established:

* **Port `0xE3` is readable** — `port_e3_rd` (`:2727`), `port_e3_rd_dat` (`:2815`), and
  `port_e3_dat <= port_e3_reg(7 downto 6) & "00" & port_e3_reg(3 downto 0)` (`:4190`). So CONMEM,
  MAPRAM and the DivMMC bank are saved and restored exactly, and the "which bank do we page back?"
  problem does not exist. **Note the contrast with NR `0x04`, which is write-only** (§4) — these are
  not the same kind of register and the difference decides how each is handled.
* **NR `0x0A` bit 4 is `nr_0a_divmmc_automap_en`** (`:5196`) and reads back (`:5912`). Clearing it
  forces `divmmc_automap_reset <= '1'` (`:4112`), which zeroes `automap_hold` and `automap_held`
  outright. That is the off switch.
* **MAPRAM is sticky**: `port_e3_reg(6) <= cpu_do(6) or port_e3_reg(6)` (`:4182`), so writing 0 to
  port `0xE3` cannot clear it. Harmless here, because clearing CONMEM *and* automap takes DivMMC off
  whichever way MAPRAM points — but exactly the kind of thing that bites a restore written from
  assumption.

#### Getting back in needs a bridge

Restoring NR `0x0A` does **not** restore `automap_held` — clearing bit 4 zeroed it, and automap only
re-arms on an M1 fetch at an entry point, which by then is unreachable because the command at
`0x2000` is gone. So: restore NR `0x0A`, page DivMMC back with `out (0xE3), saved | 0x80` (CONMEM,
original bank), execute one `rst 8` **from high RAM** to re-arm `automap_held` — the M1 fetch lands
at `0x0008`, where `i_automap_active` (= `sram_pre_override(2)`, `:3137`) is true because
`cpu_a(15 downto 14) = "00"` — then restore port `0xE3` byte-exact.

**Run B shows the `rst 8` was not needed in this invocation**, because CONMEM was already set and the
byte-exact restore was sufficient on its own. It is kept anyway, and the reason is a limit of the
measurement rather than a preference: `0xE3 = 0x82` is what *this* NextZXOS gave *this* dot command
typed at *this* command line. Nothing shows a dot command is always CONMEM-mapped, and `--auto` from
`AUTOEXEC.BAS` is a different invocation path that was not measured. If one is ever automapped with
CONMEM = 0, the exact restore alone puts DivMMC back **off** and the return to `0x2000` lands
nowhere. Six bytes.

#### One hazard that would have been ugly, disarmed by the VHDL rather than by luck

The `LDIR` writes **through** `0x0000`, `0x0008`, `0x0038` and `0x0066` — every DivMMC automap entry
point — because it is copying an 8 KB image over them. A write cannot re-trigger automap mid-copy:
`automap_hold` only updates on `i_cpu_mreq_n = '0' and i_cpu_m1_n = '0'` (`divmmc.vhd:126-131`) and
the `divmmc_automap_*_q` inputs are cleared whenever `cpu_m1_n = '1'` (`:4115-4119`). **M1 fetches
only.** Worth recording because the live `automap` expression at `divmmc.vhd:148` has had its
`not i_cpu_m1_n` term commented out, so the gating is not where a reader looks for it.

#### And where the command itself lives

**Dot commands are looked up in `/dot/`**, checked on the reference SD image, which carries
`DISPLAYEDGE` and `ESPUPDATE` there — so the nine-character name `mfinstall` is fine, and the binary
**cannot** sit in `/mfselect/` as the issue's plan assumed. Its ROM files still can, and do; the
plan's operative words are "with access to the same ROM files", which is unaffected. See
[MFINSTALL.md](MFINSTALL.md).

### 1.3 Entering and leaving config mode — both Discord accounts are wrong as stated

`zxnext.vhd:5147-5151`, the tail of the `when X"03"` write handler:

```vhdl
if nr_wr_dat(2 downto 0) = "111" then      nr_03_config_mode <= '1';
elsif nr_wr_dat(2 downto 0) /= "000" then  nr_03_config_mode <= '0';
end if;
```

* **`111` enters.** taylorza had the direction right — the bits are *set* — but the value is **7**,
  not `1`.
* **Any other non-zero value leaves.**
* **`000` hits neither branch.** SevenFFF's "clear the bottom 3 bits" does not leave config mode; it
  does nothing to it.

**And the exit write is not free.** Immediately above, `zxnext.vhd:5137-5145`:

```vhdl
if nr_03_config_mode = '1' then
   case nr_wr_dat(2 downto 0) is
      when "001" => nr_03_machine_type <= "001";   -- and 010, 011, 100
      when others => null;
   end case;
end if;
```

That is evaluated on the **pre-write** value of `config_mode`, in the same clocked process. So one
write of `011` while in config mode **sets machine type to +3 and leaves config mode**.

**The exit values split into two groups, and an earlier version of this document missed that.** The
type case covers `001`-`100`; the exit condition is `/= "000"`. So `101` and `110` **leave config
mode without touching the machine type**, while `001`-`100` leave *and* set it. Either is a
legitimate exit; the caller must know which it is doing.

**DO NOT CHOOSE A MACHINE TYPE — READ THE ONE THAT IS THERE AND WRITE IT BACK.** This corrects the
advice this paragraph used to give ("writing back the machine type you want is the safe habit"),
which is workable but asks the caller to *decide* something it has no business deciding: a tool that
installs a ROM should not be picking the machine's timing model. NR `0x03` **is readable**
(`zxnext.vhd:5894`), and `nr_03_machine_type` is initialised `"011"` and is only ever assigned
`001`/`010`/`011`/`100` (`:1103`, `:5139-5142`) — **never `000`**. So `a = read NR 0x03; a &= 7;`
gives a value that is a valid "leave config mode" **by construction** and that changes nothing.

Measured: the probe read `0x33` and restored `011`, and `tools/mfinstall/mfwin.asm` does exactly
this. It is also why there is no `NEXTREG 4,<previous>` step — see §4 on NR `0x04` being write-only,
which is the asymmetry that makes reading NR `0x03` worth pointing out.

### 1.4 Three traps in the same handler

| | line | |
|---|---|---|
| **bit 3 TOGGLES `user_dt_lock`** | `:5135` | `nr_03_user_dt_lock <= nr_03_user_dt_lock xor nr_wr_dat(3)` — an xor, not a level. Any write with bit 3 set flips it |
| **any write clears `bootrom_en`** | `:5122` | unconditional, before anything else in the handler |
| **bit 7 gates the machine TIMING case** | `:5124-5133` | with bits 6:4 selecting, and only while `user_dt_lock` is clear |

A plain `NEXTREG 3,7` avoids **two** of the three: bits 3 and 7 are clear, so neither the lock nor
the timing moves, and the machine type is untouched because `111` is not in the type case.

**It does not avoid the third, and cannot.** Clearing `bootrom_en` is unconditional on every write to
NR `0x03`. That is expected to be harmless in the intended context — a dotcommand runs long after
boot, so the boot ROM overlay is already disabled — but "harmless here" is not "avoided", and
anything doing this earlier in boot needs to know.

### 1.5 The sequence that follows from all of the above

**BUILT AND RUN.** This is now `tools/mfinstall/mfwin.asm`, assembled at `0x5000` and copied there at
run time; the version below is the sketch it was written from, corrected where the measurement
disagreed. Read the source for the citations in place.

```
    ; -- RELOCATED: this whole routine, its variables AND its stack are >= 0x4000,
    ;    because everything at 0x2000 vanishes when DivMMC goes off (1.2c).
    ; -- establish the memory state first: config mode is THIRD in priority (1.2b)
    ;    MF memory must not be paged in, slot 0/1 must not hold an MMU RAM page,
    ;    and DivMMC ROM must not be mapped, or the write silently does nothing.

    di                           ; closes the MASKABLE half - not optional.
                                 ; config mode suppresses the M1 button and DivMMC by
                                 ; itself; NR 0x81 bit 5 is the one that can still fire
    in   a,(0xE3)  -> save       ; CONMEM/MAPRAM/bank, READABLE (1.2c)
    read NR 0x0A -> save; clear bit 4    ; automap off, automap_held zeroed (:4112)
    out  (0xE3),0                        ; CONMEM off. DivMMC is now gone.
    read NR 0x03 -> mach = a & 7 ; the exit value, ASKED FOR rather than chosen (1.3)
    read port 0x123B -> save; clear the layer-2 map bits    ; (:3077)
    ; read NR 0x81, clear bit 5, write it back   ; belt and braces: the bit defaults to 0,
                                 ; but this is the ONE NMI path that survives config mode.
                                 ; NR 0x81 IS readable (zxnext.vhd:6126), unlike NR 0x04,
                                 ; so a read-modify-write and a restore are implementable
    read NR 0x50 -> save; set 0xFF       ; an MMU RAM page in slot 0 BEATS config mode
    NEXTREG 3,7                  ; enter config mode (bits 2:0 = 111)
    NEXTREG 4,5                  ; 16 KB config bank 5 at 0x0000-0x3FFF, writable
    LDIR                         ; image -> 0x0000, the MF ROM half
    READ IT BACK AND COMPARE     ; INSIDE the window: see below
    NEXTREG 3,mach               ; leave, writing back the type we read
    restore NR 0x50, NR 0x81, NR 0x0A, port 0x123B    ; NOT NR 0x04: write-only (§4)
    out  (0xE3),saved | 0x80     ; CONMEM bridge, original bank
    rst  8 / defb 0x88           ; M_DOSVERSION: the M1 at 0x0008 re-arms automap
    out  (0xE3),saved            ; exact restore
    ei
    ; NO SOFT RESET — see 3.1, which this now answers for the emulator
```

**THE READ-BACK MUST HAPPEN INSIDE THE WINDOW, and that is not belt and braces.** Outside it,
`0x0000` is the DivMMC ROM again, so there is nothing to read: a **silently discarded write is this
mechanism's entire failure mode** — it is what a naive dot command does, every time (1.2c) — and a
tool that reported success on having reached the end of a routine would report success on doing
nothing at all.

**AND `NEXTREG 2,1` IS GONE FROM THE SEQUENCE.** taylorza's example ends with one; bench check
I2 presses the M1 button straight after an install with no reset of any kind, and the stub
takes the screen. So in the emulator the answer to §3.1 is that the soft reset is **not**
required for the bytes to be live. On silicon, nobody has checked. Issuing one "just in case"
would destroy the user's BASIC session to work around something that may not be true — and
would make the check unable to ask the question.

**THE INTERRUPT WINDOW, AND IT IS NARROWER THAN THIS DOCUMENT FIRST SAID.** Config mode remaps the
whole of `0x0000-0x3FFF`, not merely the 8 KB being written — the branch is gated on
`cpu_a(15 downto 14) = "00"`. That range holds the **IM1 vector at `0x0038`**, the **NMI vector at
`0x0066`** and every `RST` vector, and during the copy they are served out of the half-written image.
An interrupt taken inside the `LDIR` fetches its handler from that. **`di` is what closes that**, and
it is not optional.

**Config mode makes the FPGA withdraw its own NMI request — which is most of the story but not all
of it; read to the end of this subsection before concluding anything.** A previous version of this
document said "nothing can" mask NMI, having read `nmi_assert_mf`'s combinational definition at
`zxnext.vhd:2090` and stopped twelve lines short of the clause that governs it. `zxnext.vhd:2102-2105`:

```vhdl
elsif nr_03_config_mode = '1' or nmi_state = S_NMI_END then
   nmi_mf     <= '0';
   nmi_divmmc <= '0';
   nmi_expbus <= '0';
```

That clear is **continuously re-asserted for as long as config mode is set**, so no new Multiface,
DivMMC or expansion-bus NMI can latch during the window at all. Clearing NR `0x06` bit 3 by hand —
which an earlier version of this document recommended — is therefore redundant.

**What remains is an entry race, and settling it took the CPU core's own source.** Two clauses in
`zxnext.vhd` cancel the FPGA's side of an NMI the moment config mode is entered — `:2102-2105` clears
the latches, and `:2156-2157` forces `nmi_state` back to `S_NMI_IDLE` regardless of what it was,
including `S_NMI_FETCH`. Both terms of `nmi_generate_n` (`:2168`) are therefore false, on the same
clock the CPU core samples `/NMI` on (`:1750`). *(An earlier version of this document cited `:2168`
alone and concluded the race was open and unclosable. That was reading one clause and stopping.)*

**But the FPGA withdrawing its request is not the same as the CPU forgetting it**, and that is
settled in the T80 core, `cpu/t80n.vhd:1663-1669`:

```vhdl
if NMICycle = '1' then                          NMI_s <= '0';
elsif NMI_n = '0' and OldNMI_n = '1' then       NMI_s <= '1';
end if;
```

**The falling edge is latched into `NMI_s` and cleared only when the NMI cycle actually runs**, with
service at an instruction boundary (`:1765`, `if NMI_s = '1' and Prefix = "00"`). That is real Z80
behaviour, faithfully modelled. So an edge latched in the instruction *before* `NEXTREG 3,7` is
**still serviced**, whatever the FPGA does with its request line afterwards.

**Where that lands took two more traces, and the answer is not the simple one.** `LDIR` is **not**
atomic in this core, which an earlier version of this document implicitly assumed. `LDI`/`LDD`/
`LDIR`/`LDDR` share one microcode block with `MCycles <= "100"` set unconditionally
(`cpu/t80n_mcode.vhd:2095-2101`), and the branch that resets `MCycle` and runs the `NMI_s` check is
an **OR**: `elsif (MCycle = MCycles) or No_BTR = '1' or …` (`t80n.vhd:1757-1766`). The first term is
true at the end of *every* four-M-cycle pass, whether the loop is terminating or not — so **`LDIR`
re-fetches its own opcode and re-checks `NMI_s` on every single byte it moves.**

So if an edge can be latched during the copy, it is serviced within a few T-states, with config mode
active and bank 5 half written. **The question is therefore whether an edge can be latched during
the copy at all**, and that is decided by what drives the CPU's `/NMI`:

```vhdl
z80_nmi_n <= nmi_generate_n;                                            -- :1841, the only driver
nmi_generate_n <= '0' when (nmi_state = S_NMI_IDLE and nmi_activated = '1')
                        or nmi_state = S_NMI_FETCH
                        or (nr_81_expbus_nmi_debounce_disable = '1' and nmi_assert_expbus = '1')
                  else '1';                                             -- :2168
```

**THREE terms, and the third is the one that matters.** The first two are suppressed throughout
config mode by `:2102-2105` and `:2156-2157`, so **the M1 button, DivMMC and an ordinary
expansion-bus NMI cannot produce a falling edge during the window at all** — no new `NMI_s`, nothing
to service. But the third term is gated on **neither** `nmi_state` **nor** `nmi_activated`: it reads
`nmi_assert_expbus`, the combinational assert, not the latch config mode clears. So an
**expansion-bus NMI, with NR `0x81` bit 5 (debounce disable) set**, still drives `/NMI` low during
config mode, latches `NMI_s`, and is serviced at the next `LDIR` iteration — reading `0x0066` out of
a bank that is partway through being overwritten.

**So the hazard is real, it spans the whole copy, and it has a name.** It is not the M1 button, which
config mode genuinely does suppress. It is an expansion-bus NMI with debounce disabled — NR `0x81`
bit 5, whose power-on default is `'0'` (`:1222`), i.e. **off unless something has deliberately turned
it on.** A dotcommand that wants the window to be safe should ensure that bit is clear, which unlike
the NR `0x06` idea an earlier version of this document proposed, is aimed at the mechanism that can
actually fire.

*(Three rounds of review to get here, and the last two were the interesting ones: the reviewer traced
`LDIR`'s per-iteration interruptibility, which refuted this document's implicit assumption; that
trace then pointed at the M1 button, which the driver above rules out; and the third term is what
survives. Neither trace alone gives the right answer.)*

**There is no `NEXTREG 4,<previous>` step, deliberately, and an earlier version of this document had
one.** NR `0x04` is **write-only**: `nextreg.txt:85-90` documents no `(R)` section, and the VHDL's
register-read multiplexer has no `when X"04"` case at all — `X"03"` is followed directly by `X"05"`
(`zxnext.vhd:5893-5896`), so a read falls into `when others` and returns `0x00`. The value cannot be
saved and restored. It also does not need to be: `nr_04_romram_bank` is consulted **only** inside the
`nr_03_config_mode = '1'` branch, so once config mode is left it has no effect on anything.

---

## 2. It is testable headless, which is what unblocks it

Issue #21 asked whether jnext models config mode, noting that if it did not, the whole path would be
untestable — and every gate in `CLAUDE.md` §Testing is a jnext bench.

**It does, including the half that matters.** `src/memory/mmu.h:164-171` in the jnext tree:

> When `config_mode=1`, CPU accesses to `0x0000-0x3FFF` on ROM-mapped slots route to SRAM at
> `(nr_04_romram_bank << 1) | slot` (8 KB pages) instead of the normal ROM serving path. See
> `zxnext.vhd:3044-3050`. **Writes are permitted through this path** (`sram_pre_rdonly<='0'` at line
> 3049) — this is how tbblue.fw's `load_roms()` populates the Spectrum/DivMMC/MF ROMs in SRAM before
> triggering RESET_SOFT.

All three pieces are present: NR `0x03` config mode (`src/port/nextreg.cpp`, with the latch
surviving reset), NR `0x04` `romram_bank` (`src/port/nextreg.h:88-97`, also surviving reset), and the
writable routing above. **No jnext issue is needed ahead of this work** — unlike jnext#210 and
jnext#211, which had to be filed and shipped before the ESP transport and the slot sweep could be
written.

**What that does not settle** is whether jnext's *model* and real silicon agree here. They agree
with the same VHDL, which is better than usual, but this project has been bitten twice by an
emulator whose values sat on the safe side of ours (a connection id of 0, a 15-character IP address).
Treat a green bench as necessary and not sufficient, as everywhere else.

---

## 3. What a dotcommand still has to decide

### 3.1 Is the soft reset required, and what does it cost?

taylorza's worked example ends with `NEXTREG 2,1`, after which the replacement stuck, and it
**survived** that reset. **That is a description of what they did, not a claim that a reset is
required** — they said so at the time ("I am not sure what the actual clean-up should be so I
just left my iterations in"), and an earlier version of this document read it as a requirement.
The open question is ours.

If the survival claim holds it is a genuine advantage over what we ship today, because the
file-swap method is measured to behave the *opposite* way: after installing our ROM, a Reset
press followed by NMI brought up the **stock** Multiface menu, and only a power cycle brought
up ours (MEMORY.md, 2026-08-04, on hardware). The firmware reads `enNextMf.rom` at power-on
only.

Two things to establish, and the second is ours alone: whether the reset is genuinely required, and
what it does to a machine that is **already** running a debug session — the stub's own `R = Reset`
key is on that screen.

**ANSWERED FOR THE EMULATOR, 2026-08-06: NO RESET IS NEEDED.** `.mfinstall` issues none — deliberately,
because issuing one "just in case" would destroy the user's BASIC session to work around something
that may not be true, and would leave nothing able to ask the question. Bench check **I2** presses the
M1 button straight after an install, with no reset of any kind, and the stub takes the screen: 97% of
it repainted, 95% unlike the stock Multiface monitor. That is exactly the check that would be red if
the bytes were not live.

**NOT ANSWERED ON SILICON**, and this is the one place a difference would be expensive: taylorza's
report is first-hand from real hardware, and jnext's config-mode model is written from the same VHDL
this document reads, so it can only confirm what the VHDL implies. **If a reset turns out to be
needed on a real Next, the fix is a line in `main()` and a change to I2 — not a redesign.** The
second question is untouched either way: nothing has run a soft reset against a live debug session.

### 3.2 What the dotcommand is, and what it is not

Xalior's refinement in #21 avoids the obvious trap and is worth keeping: **do not parse
`AUTOEXEC.BAS`**. The dotcommand reads a **config file** and decides what to install; `AUTOEXEC.BAS`
merely calls it. A YAML form matches this project's existing `version.yaml` convention.

That gives the removal story the file swap does not have:

* hold the key that skips `AUTOEXEC.BAS` → the machine boots with nothing installed;
* a key checked by the dotcommand itself → an explicit uninstall path;
* nothing is ever overwritten, so **the stock ROM cannot be lost** — which is the failure mode
  `mfselect`'s first-run guard exists to prevent and which `ERRORS.md` records as a data-loss bug.

**BUILT.** `/mfselect/mfinstall.yml`, one `install:` key taking `wifi`, `uart` or `none`, and
`.mfinstall --auto` obeys it. It is deliberately not a YAML parser: it finds a line whose first word
is `install:` and reads the next word, which is the whole of the format the issue specifies.
`install: none` is a **success** and not an error, so leaving `--auto` in `AUTOEXEC.BAS` on a day you
are not debugging costs nothing and reports nothing alarming.

The uninstall path is `--unload`, and one clarification the issue's framing invites: it restores
`/mfselect/original.rom` **into SRAM for the rest of the session**. It does not touch the card,
because nothing here touches the card. A power cycle does the same thing.

### 3.3 What happens to `mfselect`

Its identity machinery stays relevant either way: the magic string at ROM offset `0x1FE0`, matched on
prefix and variant and **never** on the build number (issue #4), and the CRC verification of what
landed. This would change *what it does*, not *how it knows what it is looking at*. Whether both
delivery mechanisms live side by side, or one replaces the other, is a decision this document does
not make.

**AS BUILT, THEY LIVE SIDE BY SIDE AND ONE DEPENDS ON THE OTHER.** `.mfinstall` reuses mfselect's
directory, its file names, its `.sum` sidecars and its identity block verbatim — `make mfinstall`
depends on `make mfselect`, and one deploy directory serves both. **`mfselect` keeps one job
exclusively: capturing the stock ROM as `original.rom`, with its first-run guard.** `.mfinstall`
deliberately does not duplicate that, because capturing means deciding whether what is installed is
really the stock ROM, and a second implementation of that decision is a second place for the
data-loss bug in `ERRORS.md` to come back. So `--unload` needs mfselect to have been run once, and
says so when it has not.

**AND THE IDENTITY BLOCK IS USED FOR NOTHING ELSE HERE — deliberately, after a first version used it
for more.** `.mfinstall` reads it through a read-only config-mode pass and *reports* which ROM is
live; it decides nothing on it. Whether to write is settled by **comparing all 8192 bytes** against
what is live, one 4 KB pass at a time, inside the same window that would do the writing.

That is a stronger property than it looks, and the first version got it wrong in the direction that
matters. A variant match answers "is a WiFi ROM live", which is not "are these the bytes": a stub
rebuilt without a `make bump` is a different ROM wearing the same `DeZoGiFnG_WIFI_0010`, and would
have been skipped — by the one person who runs this tool repeatedly, its developer. So `--auto` is
idempotent **by construction** rather than by a rule that can be wrong, and the block is left doing
the job issue #4 says it is for.

### 3.4 Open, and not investigated here

**Two of the three below are now closed, and they are struck rather than deleted so a reader can see
which questions the build answered.**

* ~~Where the ROM image lives once it is not at `machines/next/enNextMf.rom`~~ — **it stays exactly
  where it was.** `machines/next/enNextMf.rom` is never written and never moves; the images
  `.mfinstall` installs from are mfselect's, in `/mfselect/`. Nothing on the machine sees a change to
  any path, which is why bench I6 can assert byte-identity there. Only the **command** had to move,
  to `/dot/` (§1.2c).
* Whether `AUTOEXEC.BAS` runs early and reliably enough, and what boot looks like to a user who is
  not debugging that day. **STILL OPEN, and note that `--auto` from `AUTOEXEC.BAS` is also the
  invocation path §1.2c's `0xE3 = 0x82` reading does NOT cover** — the bench types the command at the
  command line, as the probes did. That is why the `rst 8` re-arm is kept.
* ~~Whether the dotcommand can verify what it wrote~~ — **it does, and it is not optional.** The
  read-back happens **inside** the window, because outside it `0x0000` is the DivMMC ROM again. Shown
  working the only way that means anything: a build with DivMMC left on reports
  `Write blocked: ROM unchanged` instead of succeeding.

Still open, and added by the build rather than inherited from the issue:

* **Anything on real hardware.** Nothing here has run on a Next.
* **The window under load.** No interrupt or NMI has ever been aimed at it, and the expansion-bus NMI
  hazard §1.5 guards against has never been provoked.
* **A partially written ROM.** If the second 4 KB pass fails there is nothing to roll back to — the
  first pass has already overwritten the previous contents and SRAM has no rename. `.mfinstall` says
  so; a power cycle always fixes it; no test produces the state.

---

## 4. Status of every claim above

**A tier was added on 2026-08-06: `measured in jnext`.** It sits below `verified` for anything about
the FPGA, because jnext's config-mode model cites the same VHDL lines this document reads and
agreement between them is not independent evidence. It sits **above** `verified` for anything about
the **NextZXOS runtime** — what a dot command's `0xE3`, MMU and SP actually are — which no amount of
VHDL can answer and which is where §1.2c came from. Nothing below is `verified on hardware`; nothing
here has run on a real Next.

| Claim | Source | Status |
|---|---|---|
| **A dot command CANNOT write bank 5 through config mode as it stands** — DivMMC wins the second arbiter and the write is silently discarded | probe read back `enNxtmmc.rom`'s bytes at `0x0000` inside the window, byte-exact; `divmmc.vhd:94-95`, `:100` | **measured in jnext**, and the mechanism **verified** in the VHDL. §1.2c |
| **DivMMC page0 and page1 are enabled together, so a command at `0x2000` necessarily has DivMMC at `0x0000`** | `divmmc.vhd:94-95` | **verified** — this is what makes the hazard structural rather than avoidable |
| A dot command is mapped by **CONMEM**, not automap: port `0xE3` = `0x82` | read back in the window; decoded per `zxnext.vhd:4190` | **measured in jnext** — one invocation path (typed at the command line); `--auto` from `AUTOEXEC.BAS` was NOT measured |
| A dot command's SP is already high (`0xFF2B`), MMU2/3 are `0x0A`/`0x0B`, MMU0 is `0xFF` | same reading | **measured in jnext** |
| **Relocating above `0x4000` and turning DivMMC OFF makes the write land, and the command survives** | `tools/mfinstall/mfwin.asm`; runs A and B | **measured in jnext** |
| **Turning DivMMC off is the load-bearing step; relocation alone fixes nothing** | run C — the same routine with DivMMC left on, one assembler constant apart, reads back the DivMMC ROM from the same code location | **measured in jnext, with a control** |
| The `rst 8` automap re-arm works | runs A and B | **measured in jnext**, and **not needed in this invocation** — B survived without it because CONMEM was already set. Kept for the unmeasured path |
| **An 8192-byte ROM can be installed this way, in two 4 KB passes, and verified inside the window** | bench `make test-mfinstall`, I1 | **measured in jnext** |
| **The bytes are LIVE with no soft reset**: an M1 button NMI straight after an install brings up the stub | bench I2 — 97% repainted, 95% unlike the stock monitor | **measured in jnext** — answers §3.1 for the emulator ONLY |
| The SD card is never written | bench I6 — `machines/next/enNextMf.rom` byte-identical after a run in which the stub was demonstrably live | **measured in jnext** |
| Dot commands are looked up in `/dot/`, and a 9-character name is fine | the reference SD image carries `DISPLAYEDGE` and `ESPUPDATE` there | **verified** |
| A dot command reports success/failure through **carry and A**, from `main`'s return value | z88dk `zxn_crt_286.asm.m4:332-346`; both probes' spurious "Path too long, 0:1" came from a `void main` | **verified** in z88dk's source, and the fix **measured in jnext** — `.mfinstall --help` returns cleanly with no trailing error |
| MF ROM is the bottom 8 KB of 16 KB bank 5; MF RAM the top | `zxnext.vhd:3029-3035` | **verified** |
| The MF path serves the ROM half read-only | same, `sram_pre_rdonly <= not cpu_a(13)` | **verified** |
| Config mode maps NR `0x04`'s bank to `0x0000-0x3FFF`, writable | `zxnext.vhd:3044-3050` | **verified** |
| Config mode is THIRD in priority: the Multiface overlay AND an MMU-mapped RAM page in slot 0/1 both beat it | `zxnext.vhd:3029-3052`, a four-way `if`/`elsif` | **verified** — the first version of this document said two-way |
| A second arbiter after it can still override, DivMMC and Layer 2 being left eligible by config mode's own `"110"` | `zxnext.vhd:3050`, `:3084`, `:3100` | **verified** |
| Config mode remaps the WHOLE of `0x0000-0x3FFF`, so the IM1, NMI and RST vectors are served from the bank being written | `zxnext.vhd:3029` (`cpu_a(15 downto 14) = "00"`) | **verified** |
| **Config mode itself suppresses new NMI latching** for the whole window — `nmi_mf`/`nmi_divmmc`/`nmi_expbus` are cleared continuously while it is set | `zxnext.vhd:2102-2105` | **verified** — an earlier version of this document said nothing could mask NMI, having read `:2090` and stopped short of this |
| `nmi_state` is ALSO forced to `S_NMI_IDLE` while config mode is set, so both terms of `nmi_generate_n` are false — the FPGA withdraws its own request | `zxnext.vhd:2156-2157` against `:2168` | **verified** — an earlier version of this document cited `:2168` alone and called the race unclosable |
| The T80 core latches the `/NMI` falling edge in `NMI_s`, cleared only by the NMI cycle itself, so an edge taken before config mode is still serviced | `cpu/t80n.vhd:1663-1669`, `:1765` | **verified** — in the CPU core's source, not in `zxnext.vhd` |
| `LDIR` re-fetches its opcode and re-checks `NMI_s` every iteration, so it is interruptible throughout | `cpu/t80n_mcode.vhd:2095-2101`, `t80n.vhd:1757-1766` | **verified** — refutes an implicit assumption of an earlier version |
| `z80_nmi_n` has exactly one driver, and `nmi_generate_n` has THREE terms | `zxnext.vhd:1841`, `:2168` | **verified** |
| The M1 button, DivMMC and an ordinary expansion-bus NMI cannot latch during config mode; **an expansion-bus NMI with NR `0x81` bit 5 set still can**, and would be serviced mid-copy | the two rows above plus `:2102-2105`, `:2156-2157` | **verified** — the third term is gated on neither `nmi_state` nor `nmi_activated` |
| NR `0x81` bit 5 defaults to `'0'` | `zxnext.vhd:1222` | **verified** |
| What the Multiface handler does if it ever runs with config mode active | — | **unverified.** Nothing has run |
| Of the five paths that can beat or override config mode, only two discard the write; three can corrupt what is actually mapped | `zxnext.vhd:3035`, `:3042`, `:3089`, `:3097`, `:3105` | **verified** — earlier versions called them all no-ops |
| **NR `0x04` is WRITE-ONLY** — it cannot be saved and restored | `nextreg.txt:85-90` has no `(R)` section; `zxnext.vhd:5893-5896` goes `X"03"` → `X"05"` with no `when X"04"`, falling to `when others => 0x00` | **verified** — the first version of this document instructed a restore that cannot be written |
| `nr_04_romram_bank` is consulted only inside the config-mode branch, so it need not be restored | `zxnext.vhd:3045`, sole reference | **verified** |
| `111` enters config mode; other non-zero leaves; `000` is a no-op | `zxnext.vhd:5147-5151` | **verified** — corrects both Discord accounts |
| Leaving config mode with `001`-`100` also writes the machine type; `101`/`110` leave without touching it | `zxnext.vhd:5137-5145` against `:5147-5151` | **verified** — an earlier version said "always", which is false for two of the six exit values |
| Bit 3 toggles `user_dt_lock`; any write clears `bootrom_en` | `zxnext.vhd:5122`, `:5135` | **verified** |
| jnext models config mode including the writable path | jnext `src/memory/mmu.h:164-171`, `src/port/nextreg.*` | **verified**, in jnext's source |
| A soft reset is NOT enough for the **file-swap** method | hardware, 2026-08-04 (MEMORY.md) | **verified on hardware** |
| A soft reset is **required** for the config-mode method | **our earlier misreading** of the Discord thread — taylorza described what they did, not a requirement, and said so | **DISPROVED in jnext** — bench I2 presses the M1 button after an install with no reset of any kind and gets the stub's screen. Untested on silicon |
| A soft reset is **enough** for it, i.e. the replacement survives one | taylorza, Discord | **reported by a third party** — not tested here, and not by anything this bench does: no run issues `NEXTREG 2,1` at all |
| Config mode is re-enterable | `.mfinstall` enters and leaves it THREE times per install — one identity read plus two 4 KB passes — and the bench's run 5 does two installs in one session, six entries, without a reset between them | **measured in jnext** — was **inferred** from `:5147` having no one-way guard, and is now exercised on every run of `make test-mfinstall` |
| The sequence in §1.5 works | it IS `tools/mfinstall/mfwin.asm`; bench `make test-mfinstall` I1 and I2 | **measured in jnext** — 8192 bytes installed in two passes, verified inside the window, and live on the next M1 press |
