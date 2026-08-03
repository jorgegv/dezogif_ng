# ERRORS.md — failed approaches worth not repeating

Anything that took more than two attempts to build or work. Check this before
attempting similar logic.

---

## Firing a Multiface NMI headless — the NR 0x06 gate

**Symptom.** Injected guest code wrote NR `0x02` bit 3 (documented as "generate
Multiface NMI"). Nothing happened: the screen never changed, with either the
stock Multiface ROM or dezogif's.

**Attempt 1 (failed).** NR `0x02` = 0x08 alone.

**Attempt 2 (worked).** Set NR `0x06` bit 3 first, read-modify-write, then
NR `0x02` = 0x08.

**Root cause.** `zxnext.vhd:2090`:

```vhdl
nmi_assert_mf <= '1' when (hotkey_m1 = '1' or nmi_sw_gen_mf = '1')
                 and nr_06_button_m1_nmi_en = '1' else '0';
```

Every MF NMI source — button, CPU/Copper NR `0x02` write, I/O trap — is gated
by NR `0x06` bit 3 (`zxnext.vhd:5166`), power-on `'0'`. The project plan said
this path was "ungated"; it was wrong, and the wrongness cost the first
attempt. **The VHDL is the authority — read it first, not after.**

---

## "The screen changed" is not "the stub took over"

**Symptom.** The headless bench's T4 reported PASS. The screenshot was, to the
eye, the untouched NextZXOS welcome screen.

**Cause.** The assertion was `cmp -s boot.png nmi.png` — any byte difference
counted. The actual difference was **24 pixels in a 26×2 box**: NextZXOS
idling, not a takeover. For comparison, the stock Multiface monitor repaints
**91.41%** of the screen.

**Fix.** `test/screen-diff.py` reports the percentage of differing pixels and
the bench requires ≥25%. T4 then correctly went red — and stayed red until the
real cause was found (`nmi66h` serves button NMIs only), at which point T4 was
rewritten to assert the *decline*, which is what actually should happen today.

**Lesson.** A green test whose assertion cannot distinguish success from
noise is worse than no test. Always check what the *positive* case actually
measures (T3 exists for exactly this reason).

---

## Deriving a hardware fact instead of reading the VHDL — got it backwards

**Symptom.** A plan-document note explaining why PC-initiated break cannot
work in UART mode claimed that handing the joy ports back to the debuggee
"re-points UART0's RX **at** the joystick pin". Exactly inverted.

**What is actually true**, and all three sources agree:

- `zxnext.vhd:3340` — `uart0_rx <= joy_uart_rx when joy_iomode_uart_en = '1'
  and nr_0b_joy_iomode_0 = '0' else i_UART0_RX`. The joystick pin is selected
  only when the enable is `'1'`; otherwise RX is `i_UART0_RX`, the ESP pin.
- `zxnext.vhd:3536` — `joy_iomode_uart_en <= '1' when nr_0b_joy_iomode_en =
  '1' and nr_0b_joy_iomode(1) = '1'`.
- `src/backup.asm:63` — resuming the debuggee writes
  `REG_JOYSTICK_IO_MODE,0`, comment "Disable joy port IO mode to enable the
  joysticks". That is the enable going to `'0'`.

So while the debuggee runs, RX is pointed **away** from the joystick pin —
where the serial cable physically is — and onto the ESP pin. The conclusion
(no PC byte can arrive while running, in UART mode) was right; the mechanism
was backwards.

**Cause.** The fact was derived from a summary of §3.1 rather than read from
the VHDL, in a document whose own first hard rule is that the VHDL is the
authority. A plausible-sounding derivation is indistinguishable from a
correct one until someone checks the source.

**Lesson.** For any claim about UART/ESP routing, NMI generation, Multiface
paging or MMU behaviour, open the VHDL and quote the line. Do not paraphrase
a paraphrase. Caught by the independent reviewer; the author had already
written it into the plan.

---

## "sjasmplus is not installed"

**Symptom.** `which sjasmplus` fails; CLAUDE.md recorded installing it as the
project's first blocker.

**Cause.** `~/bin/direnv-spectrum.sh` had

```bash
export PATH="~/src/spectrum/sjasmplus:$PATH"
```

The tilde is inside double quotes, so the shell never expands it and the PATH
entry is the literal string `~/src/spectrum/sjasmplus`. sjasmplus 1.23.1 was
installed the whole time.

**Fix.** `$HOME` instead of `~` inside the quotes.
