#!/usr/bin/env python3
"""Rewrite the upstream Z80 unit tests for headless execution (issue #3).

Upstream's tests are written for DeZog's z80-unit-test framework, where the
driver runs on the PC. Two things it does have to be moved into the guest:

  * enumerating the test entry points, and
  * evaluating the assertions.

The assertions are the interesting half. Upstream writes them as comments::

        call div_hl_e
        nop ; TEST ASSERTION HL == 2

sjasmplus copies the comment into the SLD file and DeZog sets a conditional
breakpoint at that address, evaluating ``HL == 2`` on the PC. The ``nop`` is
deliberately inert, so the assertion disturbs nothing.

Headless there is no PC-side evaluator, so this script rewrites each such
comment into a call to one of the macros in
``src/unit_tests/headless/ut_headless.inc``, which do the same comparison in
Z80 while preserving every register and flag::

        call div_hl_e
        UT_ASSERT_HL 2

The other ~260 assertions in the suite come from macros (TEST_MEMORY_BYTE and
friends) defined in ``unit_tests.inc``; those are handled by replacing that
file wholesale, not here.

Nothing under ``src/unit_tests/`` is modified. The rewritten copies go to the
build directory, so the DeZog path in VS Code keeps working and ``git blame``
against maziac/dezogif stays useful.

WHAT THIS SCRIPT REFUSES TO DO SILENTLY
---------------------------------------
Every ``ASSERTION`` comment in the input must be recognised and rewritten. An
assertion this script did not understand would be dropped on the floor and the
suite would go green with less coverage than it claims, which is the exact
failure mode issue #3 warns about. So an unparsable condition, or an assertion
comment attached to an instruction other than ``nop``, is a hard error.
"""

import argparse
import os
import re
import shutil
import sys

# An assertion comment: optional code, then a comment containing ASSERTION.
# Upstream writes both `nop ; ASSERTION x` and a bare `; ASSERTION x` on its
# own line; DeZog treats them the same, because a comment-only line carries
# the address of the next instruction. Both forms are rewritten in place, so
# the check happens at exactly the point DeZog would have broken.
ASSERTION_RE = re.compile(r'^(?P<code>[^;]*?)\s*;\s*(?:TEST\s+)?ASSERTION\b(?P<cond>.*)$')

# `bc == 0x32DE	; Only 0x32 is set` — a trailing comment on the condition.
TRAILING_COMMENT_RE = re.compile(r';.*$')

REG8 = {'a', 'b', 'c', 'd', 'e', 'h', 'l'}
REG16 = {'hl', 'de', 'bc', 'ix', 'iy'}

# A test entry point. Upstream's convention, and DeZog's: a label starting
# with UT_. Dotted forms like `UT_save_registers.UT_returns` are one test,
# not two — DeZog shows them as a group and a case.
LABEL_RE = re.compile(r'^(UT_[A-Za-z0-9_.]*)\s*:?\s*(?:;.*)?$')
MODULE_RE = re.compile(r'^\s*MODULE\s+(\S+)', re.IGNORECASE)
ENDMODULE_RE = re.compile(r'^\s*ENDMODULE\b', re.IGNORECASE)
TC_END_RE = re.compile(r'\bTC_END\b')

# ---------------------------------------------------------------------------
# Tests that cannot run outside DeZog, and how they are recognised.
#
# zsim is not just a Z80 simulator here: ``.vscode/launch.json`` gives it a
# ``customCode`` plugin, ``src/simulation/uart.js``, which invents peripherals
# that exist on no real machine and in no other emulator:
#
#   port 0x8000 (write)   push a byte into a simulated UART RX queue
#   port 0x0001 (read)    pop a byte the debugger wrote to PORT_UART_TX
#   port 0x0002/3 (read)  length of that TX queue
#   port 0x0002 (write)   set the value NR 0x02 will read back
#   port 0x0004 (read)    read back the last value written to any nextreg
#   ports 0x133B/0x143B   a UART whose RX is that queue and whose TX is
#                         always ready
#
# Every test that drives the debugger through a command depends on those, and
# they cannot be provided from inside the guest: the Z80 cannot trap its own
# I/O. Providing them in jnext is out of scope — a project-specific peripheral
# does not belong in a general emulator, and this project's rule is that
# nothing of ours goes into jnext.
#
# So those tests are EXCLUDED, by marker, and reported as UT-SKIP at run time
# rather than dropped from the table. The markers below were validated against
# a measured per-test sweep (every test run alone in its own emulator): the
# derived set covers every test that fails or hangs under jnext, and adds
# exactly one more — ut_nmi.UT_nmi_cause_button, which PASSES but only by
# coincidence, because its zsim-only setup write to port 0x0002 does nothing
# on real hardware and the real NR 0x02 happens to satisfy the cause check
# anyway. A test that passes without its own setup having worked is not
# evidence, so it is excluded too.
SKIP_MARKERS = [
    ('test_get_response',    'reads the debugger response back through zsim '
                             'ports 0x0001-0x0003 (uart.js)'),
    ('test_prepare_command', 'feeds a command through zsim port 0x8000 '
                             '(uart.js)'),
    ('TEST_PREPARE_COMMAND', 'feeds a command through zsim port 0x8000 '
                             '(uart.js)'),
    ('TEST_EMPTY_COMMAND',   'feeds a command through zsim port 0x8000 '
                             '(uart.js)'),
    ('PORT_TEST_DATA',       'writes test data to zsim port 0x8000 '
                             '(uart.js)'),
    ('in a,(4)',             'reads a nextreg back through zsim port 0x0004 '
                             '(uart.js); no such port on real hardware'),
    ('in a,(LOW UART_SELECT)',
                             'reads the UART channel select back from port '
                             '0x153B, which jnext reports in bit 3 where the '
                             'hardware reports it in bit 6 (uart.vhd:355,:371 '
                             'and ports.txt:370 against jnext '
                             'src/peripheral/uart.cpp:751), so the same read '
                             'cannot be judged there. uart.js models bit 6. '
                             'This marker RETIRES when jnext#253 is fixed'),
    ('ld bc,0x0002',         'sets the NR 0x02 read-back value through zsim '
                             'port 0x0002 (uart.js); on a real Next that '
                             'write goes to the paging port instead'),
]


class Error(Exception):
    pass


def rewrite_condition(cond, where):
    """Turn a DeZog assertion condition into a ut_headless.inc macro call."""
    cond = TRAILING_COMMENT_RE.sub('', cond).strip()

    # `ASSERTION` with no condition, and `ASSERTION false`, both mean
    # "reaching this point is a failure".
    if cond == '' or cond.lower() == 'false':
        return 'UT_ASSERT_FALSE'

    if '==' not in cond:
        raise Error('%s: unsupported assertion condition %r '
                    '(only `<reg> == <expr>`, `false` and bare are known)'
                    % (where, cond))

    lhs, rhs = cond.split('==', 1)
    lhs = lhs.strip()
    rhs = rhs.strip()
    lhs_l = lhs.lower()
    rhs_l = rhs.lower()

    if lhs_l in REG8:
        # `A == d` compares two registers; anything else is an expression.
        if rhs_l in REG8:
            return 'UT_ASSERT_R8R8 %s, %s' % (lhs_l, rhs_l)
        return 'UT_ASSERT_R8 %s, %s' % (lhs_l, rhs)

    if lhs_l in REG16:
        if rhs_l in REG16:
            if (lhs_l, rhs_l) == ('hl', 'de'):
                return 'UT_ASSERT_HL_DE'
            raise Error('%s: no macro for %s == %s; add one to ut_headless.inc'
                        % (where, lhs_l, rhs_l))
        return 'UT_ASSERT_%s %s' % (lhs_l.upper(), rhs)

    raise Error('%s: unknown left-hand side %r in assertion %r'
                % (where, lhs, cond))


def transform_file(src_path, dst_path):
    """Copy src to dst, rewriting assertion comments. Returns the count."""
    rewritten = 0
    out = []
    with open(src_path, 'r') as fh:
        for lineno, line in enumerate(fh, 1):
            raw = line.rstrip('\n')
            m = ASSERTION_RE.match(raw)
            if not m:
                out.append(raw)
                continue

            where = '%s:%d' % (src_path, lineno)
            code = m.group('code').strip()

            # The only instruction upstream ever attaches an assertion to is
            # the inert `nop` that DeZog breaks on. Anything else would mean
            # the rewrite is dropping real code, so refuse rather than guess.
            if code not in ('', 'nop'):
                raise Error('%s: assertion attached to %r, expected `nop` or '
                            'nothing' % (where, code))

            indent = re.match(r'^\s*', raw).group(0) or '    '
            macro = rewrite_condition(m.group('cond'), where)
            # Keep the original text as a comment: the generated file is what
            # you read when a test fails, and the DeZog form is the reference.
            out.append('%s%s\t; was: %s' % (indent, macro, raw.strip()))
            rewritten += 1

    with open(dst_path, 'w') as fh:
        fh.write('\n'.join(out) + '\n')
    return rewritten


def skip_reason(body):
    """Why this test body cannot run outside DeZog's zsim, or None."""
    for marker, reason in SKIP_MARKERS:
        if marker in body:
            return reason
    return None


def collect_tests(src_path):
    """Return [(full_label, skip_reason_or_None)] for every test entry point.

    A test's body runs from its label to its TC_END. Anything after that is
    the test's data, not its code, so it is not scanned for markers.
    """
    tests = []
    module = None
    current = None
    body = []

    def close():
        if current is not None:
            tests.append((current, skip_reason('\n'.join(body))))

    with open(src_path, 'r') as fh:
        for line in fh:
            line = line.rstrip('\n')
            m = MODULE_RE.match(line)
            if m:
                module = m.group(1)
                continue
            if ENDMODULE_RE.match(line):
                module = None
                continue
            m = LABEL_RE.match(line)
            if m:
                close()
                label = m.group(1)
                current = '%s.%s' % (module, label) if module else label
                body = []
                continue
            if current is not None:
                body.append(line)
                if TC_END_RE.search(line):
                    close()
                    current = None
                    body = []
    close()
    return tests


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--src', required=True, help='src/unit_tests directory')
    ap.add_argument('--out', required=True, help='output directory')
    ap.add_argument('--expect-tests', type=int, default=None,
                    help='pinned number of test cases; mismatch is an error')
    ap.add_argument('--expect-skipped', type=int, default=None,
                    help='pinned number of tests excluded as zsim-dependent')
    args = ap.parse_args()

    # Same files, same order, as unit_tests.asm includes them.
    sources = ['ut_utilities.asm', 'ut_uart.asm', 'ut_backup.asm',
               'ut_commands.asm', 'ut_message.asm', 'ut_breakpoints.asm',
               'ut_nmi.asm']

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)

    total_rewritten = 0
    tests = []
    for name in sources:
        src = os.path.join(args.src, name)
        if not os.path.exists(src):
            raise Error('missing test source %s' % src)
        total_rewritten += transform_file(src, os.path.join(args.out, name))
        tests.extend(collect_tests(src))

    if not tests:
        raise Error('no UT_ labels found — the table would be empty and the '
                    'suite would pass by running nothing')

    # Duplicate labels would make the table run one test twice and silently
    # never run another.
    seen = {}
    for full, _ in tests:
        if full in seen:
            raise Error('duplicate test label %s' % full)
        seen[full] = True

    skipped = [t for t in tests if t[1] is not None]

    # BOTH counts are pinned, and that is deliberate. Pinning only the total
    # would let a marker start matching a test that used to run, quietly
    # shrinking the suite while the total stayed right — the exact "runs 5 of
    # 25 and reports 5/5" failure this is supposed to prevent.
    if args.expect_tests is not None and len(tests) != args.expect_tests:
        raise Error('found %d test cases, expected %d. If a test was added or '
                    'removed, update UT_EXPECTED_TESTS in the Makefile and in '
                    'test/run-unit-tests.sh.'
                    % (len(tests), args.expect_tests))

    if args.expect_skipped is not None and len(skipped) != args.expect_skipped:
        raise Error('%d tests are excluded as zsim-dependent, expected %d. '
                    'If that is intended, update UT_EXPECTED_SKIPPED in the '
                    'Makefile and in test/run-unit-tests.sh — and say why in '
                    'doc/UNIT-TESTS.md.'
                    % (len(skipped), args.expect_skipped))

    with open(os.path.join(args.out, 'ut_table.asm'), 'w') as fh:
        fh.write(';========================================================\n')
        fh.write('; ut_table.asm — GENERATED by tools/ut-headless-gen.py.\n')
        fh.write('; Do not edit; edit the generator.\n')
        fh.write(';\n')
        fh.write('; One entry per test entry point, in the order the test\n')
        fh.write('; sources are included. This is the same set of labels\n')
        fh.write('; DeZog enumerates from the SLD file.\n')
        fh.write(';========================================================\n\n')
        # Plain global names, not sjasmplus local (`.foo`) ones: a local label
        # binds to the preceding non-local label, and the names below are
        # referenced from above their own definitions, where that parent is a
        # different label. That silently resolves to the wrong symbol.
        fh.write('@ut_test_table:\n')
        for i, (full, _) in enumerate(tests):
            fh.write('    defw %s, ut_name_%02X\n' % (full, i))
        fh.write('@ut_test_table_end:\n\n')
        fh.write('@UT_TEST_COUNT: equ (ut_test_table_end-ut_test_table)/4\n\n')

        fh.write('; 1 = excluded, because the test needs DeZog\'s zsim\n')
        fh.write('; customCode plugin (src/simulation/uart.js).\n')
        fh.write('@ut_skip_flags:\n')
        for i, (full, reason) in enumerate(tests):
            fh.write('    defb %d\t; %02X %s%s\n'
                     % (1 if reason else 0, i, full,
                        '  -- ' + reason if reason else ''))
        fh.write('\n')

        for i, (full, _) in enumerate(tests):
            fh.write('@ut_name_%02X: defb "%s",0\n' % (i, full))
        fh.write('\n')
        # A second, independent statement of the counts. If the table and the
        # pins ever disagree the build stops here rather than at run time.
        fh.write('    ASSERT UT_TEST_COUNT == %d\n' % len(tests))
        fh.write('    ASSERT ut_name_00-ut_skip_flags == %d\n' % len(tests))

    with open(os.path.join(args.out, 'ut_manifest.txt'), 'w') as fh:
        for i, (full, reason) in enumerate(tests):
            fh.write('%02X %s %s\n'
                     % (i, 'SKIP' if reason else 'RUN ', full))
            if reason:
                fh.write('         reason: %s\n' % reason)

    print('ut-headless-gen: %d test cases (%d runnable, %d excluded as '
          'zsim-dependent), %d inline assertions rewritten'
          % (len(tests), len(tests) - len(skipped), len(skipped),
             total_rewritten))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Error as exc:
        print('ut-headless-gen: ERROR: %s' % exc, file=sys.stderr)
        sys.exit(1)
