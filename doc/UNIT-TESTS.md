# The Z80 unit tests, headless

`make test-unit` runs the Z80 unit tests under `src/unit_tests/` in jnext, with no VS Code and no
DeZog, and gates on the result. This document says how that works, what it does **not** cover, and
why 40 of the 69 test cases cannot run at all outside DeZog.

Issue: [#3](https://github.com/jorgegv/dezogif_ng/issues/3).

---

## 1. Why they needed VS Code

The tests are upstream's and are written for **DeZog's z80-unit-test framework**, in which the
*driver* is the VS Code extension rather than anything in this repository. Two jobs live on the PC:

**Enumerating the tests.** DeZog reads the `UT_*` labels out of the SLD file, patches
`UNITTEST_CALL_ADDR` in `unit_tests.inc`'s wrapper to point at one of them, and runs the machine.
Pass or fail is decided by which breakpoint gets hit.

**Evaluating the assertions — and this is the part that is easy to miss.** An assertion in this
suite is a *comment*:

```asm
    call div_hl_e
    nop ; TEST ASSERTION HL == 2
```

`SLDOPT COMMENT WPMEM, LOGPOINT, ASSERTION` at the top of `unit_tests.asm` makes sjasmplus copy
that comment into the SLD, and DeZog then sets a **conditional breakpoint** at the `nop`'s address
and evaluates `HL == 2` in JavaScript, on the PC. The `nop` is deliberately inert: the assertion
must disturb no register and no flag, because upstream writes runs of them back to back on
different registers.

So `build/ut.nex` is not a test that needs a runner. It is a test whose **checks do not exist in
the image at all**. Nothing in this repository could ever have driven it.

## 2. How the headless build works

Three pieces, and none of them touches a file under `src/unit_tests/` other than by copying it.

**`src/unit_tests/headless/ut_headless.inc`** replaces `unit_tests.inc`. It defines the same macro
names with the same parameters, so upstream's test bodies assemble against it unchanged, but every
assertion compiles into real Z80. The inertness requirement is kept: each macro saves and restores
AF and any scratch register it uses, and consumes the comparison with a **conditional call**,
because `ld` between the `cp` and the `call` does not touch the flags and no label is needed
inside a macro.

```asm
    cp value
    call nz,ut_assert_fail      ; never returns
```

`ut_assert_fail` pops its own return address, which is the address inside the failing macro
expansion. That is what names the failing assertion in the output, with no per-assertion
identifier to allocate or keep in step with the source. Map one back with:

```sh
grep -n ' <ADDR> ' build/ut-headless.list
```

**`tools/ut-headless-gen.py`** rewrites the ~65 assertions upstream wrote *inline* rather than
through a macro — `nop ; ASSERTION HL == 2`, and the bare-comment form `; ASSERTION HL == cmd_init`
that DeZog attaches to the following instruction — into calls to those macros, and emits the test
table. The rewritten copies go to `build/ut_headless/`; `src/unit_tests/` is never modified, so
`make unit-tests` and the DeZog path in VS Code keep working and `git blame` against
maziac/dezogif stays useful. Every generated line keeps the original as a `; was:` comment.

The generator **refuses** an assertion condition it does not understand, and refuses an assertion
comment attached to any instruction other than `nop`. An assertion silently dropped would leave
the suite green with less coverage than it claims.

**`src/unit_tests/headless/ut_runner.asm`** is the driver, in the guest. It walks the generated
table, calls each test, and reports to jnext's **magic debug port** (`--magic-port 0xCAFE
--magic-port-mode line`), which puts the bytes on the emulator's stderr. One headless jnext run
therefore prints a full test report that `test/run-unit-tests.sh` reads.

## 3. Silence is a failure

This is the property the bench is built around, and the reason the output is shaped the way it is.

```
UT-RUN <count>
UT-BEGIN <idx> <name>      <-- emitted BEFORE the test runs
UT-SKIP <idx> <name>
UT-PASS <idx>
UT-FAIL <idx> <addr>
UT-DONE <total> <pass> <fail> <skip>
```

jnext's run is bounded in **frames**, so a wedged guest ends the run quietly, on time, and with an
exit status of 0. Without a positive end-of-run marker that is indistinguishable from success —
and a test that hangs at number 7 would read as "7 passed".

So `UT-BEGIN` is emitted *before* entry, and check **U2** requires `UT-DONE`. A hang therefore
fails the bench and the last `UT-BEGIN` names the test that wedged:

```
FAIL  U2 the suite did NOT finish — it hung or crashed in: 01 ut_utilities.UT_div_hl_e
```

The counts are pinned in **two independent places** — `UT_EXPECTED_TESTS` / `UT_EXPECTED_SKIPPED`
in the Makefile, which the generator checks against the *sources* at build time, and the same two
numbers in `test/run-unit-tests.sh`, checked against what actually *ran*. Pinning only the total
would let a test quietly move from the runnable set into the excluded set while the total stayed
right.

### The counts were right and three tests never ran

**Found 2026-08-13, live since issue #41, and it is the sharpest illustration this project has of
what a pinned total cannot see.** `load_entry` computed its table offset as `test_index × 4` in the
**8-bit** accumulator. Four bytes per entry, so the multiply overflows at index `0x40` — and the
table crossed 64 entries when #41 took the suite from 64 cases to 66.

From the 65th case on, the runner therefore read the entry of `index & 0x3F`: it **CALLed the wrong
test's code** and printed the wrong test's name. The skip flags were unaffected, being one byte per
entry with no multiply, so exclusions stayed correct and only the runnable cases were displaced.

What that looked like, at 69 cases:

| index | the manifest's test | what actually ran |
|---|---|---|
| `40` | `ut_breakpoints.UT_check_tmp_breakpoints.UT_no_bp` | `ut_utilities.UT_write_read_slot` |
| `41` | `ut_breakpoints.UT_check_tmp_breakpoints.UT_first_bp` | `ut_utilities.UT_div_hl_e` |
| `42` | `ut_breakpoints.UT_check_tmp_breakpoints.UT_second_bp` | `ut_utilities.UT_itoa_2digits` |

**Three breakpoint tests never executed, and the suite reported 29 of 29 passing.** U1-U5 were green
throughout, on **both** independent pins, because the totals were right: a duplicate was counted in
place of the test it displaced. The pins say **how many** cases run, never **which**, and this is the
one shape that distinction lets through. `UT-FAIL`'s own diagnostic — which maps a failing index back
to a name through the manifest — would likewise have named the wrong test.

**U6 is the guard.** It asserts the identity of every printed line against the manifest: each index
must carry that index's name, and `UT-BEGIN`/`UT-SKIP` must agree with its `RUN`/`SKIP`. Watched to
fail against the 8-bit form — five lines, naming every displaced test, with U1-U5 still green.

The three tests pass now that they run, which is luck rather than vindication: three ROM-moving builds
shipped while they were providing no protection at all. `src/breakpoints.asm` itself did not move in any
of them — checked — so nothing is known to have slipped past, but nothing was watching either.

## 4. Isolation between tests

Several tests **self-modify the debugger they are testing** and never undo it — `ut_uart.asm`
patches `transport_read_byte.timeout` with a `JP` into itself, `ut_nmi.asm` patches
`MF.nmi66h.is_button_cause`, `ut_backup.asm` and `ut_commands.asm` patch `save_registers.ret_jump`
and `restore_registers.ret_jump1/2`. Run back to back with no reset, a later test calling
`transport_read_byte` would jump into `ut_uart`'s leftover trampoline, land on its `TC_END` and be
reported as a **pass it never earned**.

Tests also page banks 28/29/39/40/70/75/76 into slots 0, 6 and 7 and do not always put them back.

So before every test the runner restores all eight MMU slot registers to what they were at
startup, and copies a pristine image of the 8 KB program bank back over it from
`UT_SNAPSHOT_BANK` (80, chosen because no test touches it).

**This was verified rather than assumed**: every test was also run *alone, in its own emulator
process* (`-DUT_ONLY=<n>`, still available as a diagnostic), and the per-test verdicts are
identical to the single-run ones.

## 5. What does NOT run, and why

**40 of the 69 test cases are excluded.** They are reported as `UT-SKIP` on every run rather than
dropped from the table, because an exclusion that does not appear in the output is an exclusion
nobody will notice.

`.vscode/launch.json` gives zsim a **`customCode` plugin**, `src/simulation/uart.js`. It is a
JavaScript peripheral that invents ports existing on no real machine and in no other emulator:

| port | direction | what the plugin does |
|---|---|---|
| `0x8000` | write | push a byte into a simulated UART RX queue |
| `0x0001` | read | pop a byte the debugger wrote to `PORT_UART_TX` |
| `0x0002`/`0x0003` | read | length of that TX queue |
| `0x0002` | write | set the value NR `0x02` will read back |
| `0x0004` | read | read back the last value written to any nextreg |
| `0x133B`/`0x143B` | both | a UART whose RX is that queue and whose TX is always ready |

Every test that drives the debugger through a DZRP command reads its response back through those
ports. **They cannot be provided from inside the guest — the Z80 cannot trap its own I/O** — and
providing them in jnext is out of scope: a project-specific peripheral does not belong in a
general emulator, and this project's rule is that nothing of ours goes into jnext.

Under jnext those reads return real-hardware behaviour instead. `0x8000` is a paging port, and a
read of `0x0001` returns bus noise rather than the `0xA5` `MESSAGE_START_BYTE` that
`ut_commands.test_get_response` asserts, which is where 33 of the exclusions fail. Two more hang
outright in `wait_for_uart_tx`, polling a UART that will never drain.

The exclusion list is **derived, not hand-maintained**: `tools/ut-headless-gen.py` scans each
test's body for the markers that mean "this test needs the plugin" (`test_get_response`,
`test_prepare_command`, `TEST_PREPARE_COMMAND`, `TEST_EMPTY_COMMAND`, `PORT_TEST_DATA`,
`in a,(4)`, `ld bc,0x0002`). That rule was **validated against a measured per-test sweep**: it
covers every test that fails or hangs under jnext, and adds exactly one more —
`ut_nmi.UT_nmi_cause_button`, which passes but only by coincidence, because its zsim-only setup
write to port `0x0002` does nothing on a real machine and the real NR `0x02` happens to satisfy
`nmi66h`'s cause check anyway. A test that passes without its own setup having worked is not
evidence, so it is excluded too.

### The one exclusion that was jnext's fault, and has retired

An eighth marker, `in a,(LOW UART_SELECT)`, existed from issue #42 until 2026-08-13 and is the
only one that was never about a zsim-invented port. It excluded the two cases that read port
`0x153B` — a **real** port, which jnext reported in **bit 3** where the hardware reports the UART
channel select in **bit 6** (`serial/uart.vhd:355` and `:371`, `ports.txt:370` in words), so the
same read could not be judged there at all. `src/simulation/uart.js` models bit 6, i.e. the
hardware.

**jnext#253 (0.99.155) fixed the read-back, so the marker is gone and
`ut_uart.UT_transport_select_reclaimed` runs — the first case in this project's history to move
from the excluded set to the runnable one.** Exactly one moved, and a prediction that both would
was wrong: `UT_transport_poll_borrows_select` stages its byte through `PORT_TEST_DATA`
(port `0x8000`) and so keeps a marker of its own. The check is a `grep` over the test bodies, not
a memory of which tests carried which marker.

### What the 29 that do run actually cover

All of `ut_utilities.asm` (nextreg read/write, division, itoa), all of `ut_breakpoints.asm` (the
temporary-breakpoint bookkeeping, 8 cases), all of `ut_backup.asm` (register save/restore
including the shadow set, I and IM, and `read`/`write_debugged_prgm_mem` across the slot-7 and
`0xFFFF`/`0x0000` bank boundaries — i.e. the **SWAP-window paging** the plan's §4.1 is about),
`transport_read_byte`'s timeout path, `ut_uart.UT_transport_select_reclaimed` (issue #42 — that
the debugger takes the UART channel select back at every entry), and the parts of
`ut_commands.asm` that do not need a simulated response (`get_cmd_pointer`, four
`cmd_set_register` cases, `cmd_pause`).

That is real coverage of the banking and breakpoint code M1 and M2 disturb. It is **not** coverage
of the DZRP command layer — for that the gate is `make test-dzrp-stub`, which drives the real
protocol over a real socket and does not need any of this.

## 6. What it does not prove

- **Nothing about hardware.** This is jnext. The tests it runs include ones about MMU paging,
  which jnext models rather than is.
- **Almost nothing about the transport.** `ut_uart.asm`'s two runnable cases test a timeout path
  and the select reclaim; the ESP transport has no unit tests at all, and its gate is
  `make test-dzrp-stub`.
- **It does not replace the DeZog path.** `make unit-tests` still builds `build/ut.nex`, and the
  "Unit Tests" launch configuration still runs all 69 cases in VS Code with the plugin, which is
  the only way the excluded 40 can ever be exercised.
