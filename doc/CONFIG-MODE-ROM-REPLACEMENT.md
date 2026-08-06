# Replacing the Multiface ROM at run time, with config mode

**Analysis for [issue #21](https://github.com/jorgegv/dezogif_ng/issues/21). Input to a design, not
a design.** The intended consumer is a **dotcommand** that installs the debugger from the NextZXOS
command line and/or from `AUTOEXEC.BAS`, instead of the SD-card file swap `mfselect` performs today.

**Scope: the delivery mechanism only.** Nothing about the stub, the DZRP layer, the transports or
the identity block changes. This is about how the 8 KB image gets into Multiface ROM space and how a
user turns it on and off.

**Nothing here has been run.** Every mechanical claim below is read from the FPGA VHDL — this
project's first hard rule, and the reason the two contradictory Discord accounts in #21 are both
corrected rather than picked between. The status of every claim is in the table at the end.

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
holds a RAM page rather than a ROM mapping, that branch serves it and config mode never runs. Nothing
here establishes what a dotcommand's MMU state is at the moment of the write, and it must be
established rather than assumed.

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
legitimate exit; the caller must know which it is doing. Writing back the machine type you want is
the safe habit, and it is why taylorza's "restore NR `0x04`, then NR `0x03`" ordering works.

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

```
    ; -- establish the memory state first: config mode is THIRD in priority (1.2b)
    ;    MF memory must not be paged in, slot 0/1 must not hold an MMU RAM page,
    ;    and DivMMC ROM must not be mapped, or the write silently does nothing.

    di                           ; closes the MASKABLE half - not optional.
                                 ; NMI needs nothing: config mode suppresses it (below)
    NEXTREG 3,7                  ; enter config mode (bits 2:0 = 111)
    NEXTREG 4,5                  ; 16 KB config bank 5 at 0x0000-0x3FFF, writable
    LDIR                         ; 8 KB image -> 0x0000, the MF ROM half
    NEXTREG 3,<machine type>     ; leave: 001-100 sets the type too, 101/110 do not
    ei
    NEXTREG 2,1                  ; soft reset - reportedly required; see 3.1
```

**THE INTERRUPT WINDOW, AND IT IS NARROWER THAN THIS DOCUMENT FIRST SAID.** Config mode remaps the
whole of `0x0000-0x3FFF`, not merely the 8 KB being written — the branch is gated on
`cpu_a(15 downto 14) = "00"`. That range holds the **IM1 vector at `0x0038`**, the **NMI vector at
`0x0066`** and every `RST` vector, and during the copy they are served out of the half-written image.
An interrupt taken inside the `LDIR` fetches its handler from that. **`di` is what closes that**, and
it is not optional.

**NMI needs nothing, because config mode already suppresses it** — and a previous version of this
document said the opposite, "nothing can", having read `nmi_assert_mf`'s combinational definition at
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

**What remains is an entry race of a few clock cycles, and no software closes it.** `nmi_generate_n`
(`:2168`) fires on `nmi_state = S_NMI_IDLE and nmi_activated = '1'` **or** on
`nmi_state = S_NMI_FETCH`. The second term does not consult `nmi_activated`, so an NMI whose state
machine has already reached `S_NMI_FETCH` in the cycle or two before `NEXTREG 3,7` takes effect will
complete its fetch of `0x0066` from the newly remapped bank. Neither `di` nor NR `0x06` reaches it,
because both act on the *assertion* and this transition is already under way. It is a genuine hazard
and it is a vanishingly small target; the honest handling is to know it exists rather than to defend
against it with something that does not work.

**There is no `NEXTREG 4,<previous>` step, deliberately, and an earlier version of this document had
one.** NR `0x04` is **write-only**: `nextreg.txt:85-90` documents no `(R)` section, and the VHDL's
register-read multiplexer has no `when X"04"` case at all — `X"03"` is followed directly by `X"05"`
(`zxnext.vhd:5893-5896`), so a read falls into `when others` and returns `0x00`. The value cannot be
saved and restored. It also does not need to be: `nr_04_romram_bank` is consulted **only** inside the
`nr_03_config_mode = '1'` branch, so once config mode is left it has no effect on anything.

**This has not been run**, here or anywhere in this project. It is what the VHDL says should work.

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

taylorza reports needing `NEXTREG 2,1` for the replacement to take, and reports that it **survived**
that reset. If true it is a genuine advantage over what we ship today, because the file-swap method
is measured to behave the *opposite* way: after installing our ROM, a Reset press followed by NMI
brought up the **stock** Multiface menu, and only a power cycle brought up ours (MEMORY.md,
2026-08-04, on hardware). The firmware reads `enNextMf.rom` at power-on only.

Two things to establish, and the second is ours alone: whether the reset is genuinely required, and
what it does to a machine that is **already** running a debug session — the stub's own `R = Reset`
key is on that screen.

### 3.2 What the dotcommand is, and what it is not

Xalior's refinement in #21 avoids the obvious trap and is worth keeping: **do not parse
`AUTOEXEC.BAS`**. The dotcommand reads a **config file** and decides what to install; `AUTOEXEC.BAS`
merely calls it. A YAML form matches this project's existing `version.yaml` convention.

That gives the removal story the file swap does not have:

* hold the key that skips `AUTOEXEC.BAS` → the machine boots with nothing installed;
* a key checked by the dotcommand itself → an explicit uninstall path;
* nothing is ever overwritten, so **the stock ROM cannot be lost** — which is the failure mode
  `mfselect`'s first-run guard exists to prevent and which `ERRORS.md` records as a data-loss bug.

### 3.3 What happens to `mfselect`

Its identity machinery stays relevant either way: the magic string at ROM offset `0x1FE0`, matched on
prefix and variant and **never** on the build number (issue #4), and the CRC verification of what
landed. This would change *what it does*, not *how it knows what it is looking at*. Whether both
delivery mechanisms live side by side, or one replaces the other, is a decision this document does
not make.

### 3.4 Open, and not investigated here

* Where the ROM image lives once it is not at `machines/next/enNextMf.rom`, and whether anything else
  on the machine expects a Multiface ROM at that path.
* Whether `AUTOEXEC.BAS` runs early and reliably enough, and what boot looks like to a user who is
  not debugging that day.
* Whether the dotcommand can verify what it wrote — reading back through config mode should work by
  §1.2, since the mapping is symmetric, but that is inference and has not been checked.

---

## 4. Status of every claim above

| Claim | Source | Status |
|---|---|---|
| MF ROM is the bottom 8 KB of 16 KB bank 5; MF RAM the top | `zxnext.vhd:3029-3035` | **verified** |
| The MF path serves the ROM half read-only | same, `sram_pre_rdonly <= not cpu_a(13)` | **verified** |
| Config mode maps NR `0x04`'s bank to `0x0000-0x3FFF`, writable | `zxnext.vhd:3044-3050` | **verified** |
| Config mode is THIRD in priority: the Multiface overlay AND an MMU-mapped RAM page in slot 0/1 both beat it | `zxnext.vhd:3029-3052`, a four-way `if`/`elsif` | **verified** — the first version of this document said two-way |
| A second arbiter after it can still override, DivMMC and Layer 2 being left eligible by config mode's own `"110"` | `zxnext.vhd:3050`, `:3084`, `:3100` | **verified** |
| Config mode remaps the WHOLE of `0x0000-0x3FFF`, so the IM1, NMI and RST vectors are served from the bank being written | `zxnext.vhd:3029` (`cpu_a(15 downto 14) = "00"`) | **verified** |
| **Config mode itself suppresses new NMI latching** for the whole window — `nmi_mf`/`nmi_divmmc`/`nmi_expbus` are cleared continuously while it is set | `zxnext.vhd:2102-2105` | **verified** — an earlier version of this document said nothing could mask NMI, having read `:2090` and stopped short of this |
| A residual entry race remains: an NMI already at `S_NMI_FETCH` completes its fetch from the remapped bank, and no software action closes it | `zxnext.vhd:2168`, the second term | **verified** |
| Of the five paths that can beat or override config mode, only two discard the write; three can corrupt what is actually mapped | `zxnext.vhd:3035`, `:3042`, `:3089`, `:3097`, `:3105` | **verified** — earlier versions called them all no-ops |
| **NR `0x04` is WRITE-ONLY** — it cannot be saved and restored | `nextreg.txt:85-90` has no `(R)` section; `zxnext.vhd:5893-5896` goes `X"03"` → `X"05"` with no `when X"04"`, falling to `when others => 0x00` | **verified** — the first version of this document instructed a restore that cannot be written |
| `nr_04_romram_bank` is consulted only inside the config-mode branch, so it need not be restored | `zxnext.vhd:3045`, sole reference | **verified** |
| `111` enters config mode; other non-zero leaves; `000` is a no-op | `zxnext.vhd:5147-5151` | **verified** — corrects both Discord accounts |
| Leaving config mode with `001`-`100` also writes the machine type; `101`/`110` leave without touching it | `zxnext.vhd:5137-5145` against `:5147-5151` | **verified** — an earlier version said "always", which is false for two of the six exit values |
| Bit 3 toggles `user_dt_lock`; any write clears `bootrom_en` | `zxnext.vhd:5122`, `:5135` | **verified** |
| jnext models config mode including the writable path | jnext `src/memory/mmu.h:164-171`, `src/port/nextreg.*` | **verified**, in jnext's source |
| A soft reset is NOT enough for the **file-swap** method | hardware, 2026-08-04 (MEMORY.md) | **verified on hardware** |
| A soft reset IS enough for the **config-mode** method, and is required | taylorza, Discord | **reported by a third party** — not tested here |
| Config mode is re-enterable | SevenFFF, Discord; consistent with `:5147` having no one-way guard | **inferred** — the VHDL shows no latch preventing re-entry, but nothing has run |
| The sequence in §1.5 works | — | **unverified.** No code has been written and nothing has been run |
