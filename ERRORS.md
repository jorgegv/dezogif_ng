# ERRORS.md — failed approaches worth not repeating

Anything that took more than two attempts to build or work. Check this before
attempting similar logic.

---

## Firing a Multiface NMI headless — and what actually blocked it

**Symptom.** Injected guest code wrote NR `0x02` bit 3 ("generate Multiface
NMI"). Nothing happened: the screen never changed.

**What was concluded at the time, and it was wrong.** That the NMI was gated
off by NR `0x06` bit 3 (`zxnext.vhd:2090`), because adding a read-modify-write
of that bit "fixed" it. Both observations were real; the causal link was not.

**What actually happened.** The failing run used *dezogif's* Multiface ROM,
which declines software NMIs by design — `nmi66h` masks NR `0x02` with
`00011100b` and returns unless the result is zero. The "fix" run used the
*stock* Multiface ROM, which accepts them. The variable that changed was the
ROM, not the register. Two changes at once, and the wrong one got the credit.

**Measured properly, 2026-08-04**, with the Copper fixture against the stock
ROM, one variable at a time:

| NR `0x06` bit 3 | result |
|---|---|
| set by the fixture | NMI fires, 91.41% repaint |
| left untouched | NMI fires, 91.41% repaint |
| explicitly cleared | **no NMI**, 0.00% |

So the gate in `zxnext.vhd:2090` is real and jnext models it faithfully — and
**NextZXOS leaves NR `0x06` bit 3 set after boot**, which is why a guest that
never touches it still gets its NMI. The register's *power-on* value is 0
(`zxnext.vhd:1110`); by the time anything runs under NextZXOS it is 1.

**Consequences.**

- The fixtures still set the bit, deliberately: it costs seven bytes and makes
  them independent of what the firmware happened to leave behind.
- For the stub, the risk is not "must set it" but "**the debuggee may clear
  it**" — and if it does, M2's asynchronous break stops working silently.
  Re-asserting it from the poll is cheap insurance.

**Lesson, and it is not the one this entry used to teach.** Two variables
changed between the failing run and the working one, and the conclusion picked
the interesting one. A fix that is never tested by *removing* it is a
correlation. The three-row table above took one extra emulator run.

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
