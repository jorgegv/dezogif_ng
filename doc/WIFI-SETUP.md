# WiFi setup — a prerequisite, not a feature

**In WiFi mode the stub assumes the Next is already on a WiFi network, and it will never put it
there.** Set WiFi up once, with the Next's own tooling, before using the debugger. This page says
exactly what that means, how to do it, how to check it worked, and what breaks it later.

None of this applies to **UART mode**, which uses a serial cable on the joystick port and touches
no network at all.

---

## 1. What the stub does and does not do

| | |
|---|---|
| **Does not** join a network | It never sends `AT+CWJAP`, never asks for an SSID, never asks for a password |
| **Does not** store credentials | There is no SSID or passphrase anywhere in the ROM, the build, or this repository |
| **Does** check | On bring-up it asks the module for its address (`AT+CIFSR`) and shows it |
| **Does** fail loudly | With no address, it says so on screen rather than hanging or showing a connect string with nothing behind it |

The address it shows is the one to put in your `launch.json` (Appendix B.5 of the
[project plan](ZXNEXT-REMOTE-DEBUG-STUB.md)).

---

## 2. Why it works this way

Three reasons, each independently sufficient.

**The stub cannot read the SD card.** Verified across `src/`: nothing in it opens a file. The only
`rst 8` in the tree is inside `MF_BREAK` in `macros.asm`, a macro upstream disabled with the
comment "did not work for me". There is no config file to read because there is no way to read
one.

**Nor could it safely.** The stub is a Multiface **NMI handler**. It runs with the debuggee's banks
paged however the debuggee left them, at an arbitrary instant, with NextZXOS possibly mid-operation
or not present at all. Calling the esxdos API from there needs guarantees the NMI path cannot make.
Reading a config file at NMI time is not a small change; it is a different design.

**And a password in a ROM is cleartext on a removable card.** `enNextMf.rom` is a file that gets
copied, backed up, and passed around — including to us, when someone reports a bug. Putting a WPA2
passphrase in it would make every copy a credential leak, readable by any program on the machine.
Obfuscating it would be theatre. This was considered and **rejected** (see `MEMORY.md`).

The ESP-01 keeps its own credentials in its own flash, which is the right place for them.

---

## 3. Setting WiFi up

Use the wizard that ships on the NextZXOS SD card:

```
/apps/wifi/setup/wifi2.bas
```

Run it from the Browser, or from BASIC with `LOAD "/apps/wifi/setup/wifi2.bas"`.

It identifies itself as **"WIFI wizard v2p3, by Tony Hoyle and Tim Gilberts"**. On start it queries
the module and reports:

```
Firmware:     <ESP-AT firmware version>
Connected to: <SSID, or blank if not associated>
IP Address:   <address, or blank>
DNS:          <servers>
```

and offers:

| | |
|---|---|
| 1 | Set Manual SSID — *this is the one you want*; it asks for the network and passphrase |
| 2 | Set Manual IP |
| 3 | Set Manual DNS |
| 4 | Set automatic IP/DNS |
| 5 | Scan Networks |
| 6 | List/Join Networks |
| 7 | WiFi Firmware update |
| 9 | Refresh |
| 0 | Quit |

**Use `wifi2.bas`, not `wifi.bas`.** Both are present; `wifi.bas` is the older wizard, with a
different menu, and it queries `AT+CIPDNS_CUR?` where v2 queries `AT+CIPDNS?`.

**A static DHCP reservation on your router is worth the five minutes.** The stub reports whatever
address it is given, but if that address never changes you write `launch.json` once and never
revisit it. Option 2 (Manual IP) achieves the same from the Next's side.

---

## 4. Checking it worked

**Before involving the debugger at all**, re-run `wifi2.bas` and confirm `Connected to:` names
your network and `IP Address:` is a real address. If those two lines are populated, the stub has
everything it needs.

That check is worth doing on its own, because it separates two failures that look identical from
the debugger's side: "WiFi is not set up" and "the stub's transport is broken".

---

## 5. How often

**Once per machine, not once per session.** The ESP-01 stores credentials in its own flash and
reconnects by itself at power-on.

> **Not verified by this project.** That is standard ESP-AT behaviour (`AT+CWJAP_DEF` persists,
> `AT+CWAUTOCONN` defaults to on) but we have not measured it on a real Next, and jnext cannot
> answer it — its emulated module is permanently associated and implements only the *query* form
> `AT+CWJAP?`, never the setting form. If your Next turns out to need re-association after a power
> cycle, that is worth telling us: it changes the setup story from "once" to "every boot".

---

## 6. What breaks it afterwards

The ESP is a single shared resource and other software reconfigures it.

- **Anything else using WiFi during a debug session.** NextSync, NXtel and similar will reconfigure
  the module out from under the stub. One program owns the ESP at a time. This is the reason the
  **UART build exists** — for a debuggee that needs the ESP itself, use the serial ROM.
- **`.ESPBAUD`** changes the module's baud rate. The stub talks to it at **115200**, the ESP-01's
  power-on default. If something has moved it, the stub will see silence.
- **`.ESPUPDATE`** reflashes the module's firmware. It reports itself as "Updates firmware for
  ESP8266-01 WiFi module on the Spectrum Next". Expect to re-run the WiFi wizard afterwards.
- **`.UART`** is an interactive AT terminal (it sends `ATE0` and `AT+UART=115200,8,1,0,0` on entry).
  Useful for diagnosing by hand, and equally capable of leaving the module in a state the stub does
  not expect.

---

## 7. If the stub reports no address

In order, cheapest first:

1. Run `wifi2.bas` and look at `Connected to:` and `IP Address:`. If they are blank, the problem is
   WiFi, not the debugger — fix it there.
2. Power-cycle the Next. If WiFi then works but did not before, the module is not auto-reconnecting;
   see the note in §5, and please report it.
3. Check nothing else has claimed the ESP — no NextSync or NXtel session in progress.
4. Check the baud with `.ESPBAUD` if you have ever changed it.
5. If the module answers nothing at all through `.UART` either, the problem is below this project:
   ESP firmware or hardware.

---

## 8. In the emulator

`wifi2.bas` runs under jnext and is a useful way to see what the stub will see — **but jnext needs
`--esp`**. Without it there is no module to answer, and the failure looks like a broken wizard
rather than a missing flag.

```
jnext --machine next --sdcard <image> --esp
```

Measured 2026-08-04, jnext 0.99.118. The wizard reaches its menu and reports:

```
Firmware:     1.7.4.0(jnextemulatedESP-01)
Connected to: JNextWifiHost
IP Address:   192.168.1.50
```

**The read-only half works and the configuring half does not**, which is the split that matters
here — everything this project needs is in the first half:

| Works | Does not, and why |
|---|---|
| Firmware, Connected to, IP Address | DNS is blank — jnext has `AT+CIPDNS_CUR?` but not `AT+CIPDNS?` |
| | Scan / List Networks say "0 networks" — no `AT+CWLAP` |
| | Set Manual SSID, Manual IP, automatic IP/DNS, firmware update — no `AT+CWJAP=`, `AT+CIPSTA=`, `AT+CWDHCP=`, `AT+CIUPDATE` |

**So credentials can never be set from inside the emulator**, and there is no need for them to be:
jnext's module is permanently associated. Setting up WiFi is a hardware-only activity, which is
consistent with it being a prerequisite rather than a feature.

> A static comparison of the wizard's commands against jnext's dispatch table predicted it would
> die at startup on the unimplemented `AT+CWMODE=1`. **It does not** — unknown commands answer
> `ERROR` and the wizard shrugs them off. The prediction was wrong and running it was what showed
> that, which is the habit `ERRORS.md` keeps arguing for.

---

## 9. What is verified, and what is not

This project's rule is that a derived claim is a hypothesis. So, explicitly:

| Claim | Status |
|---|---|
| The stub never reads the SD card | **verified** — `grep` across `src/`; the only `rst 8` is in a disabled macro |
| `/apps/wifi/setup/wifi2.bas` exists and is the WiFi wizard | **verified** — read from the reference SD image |
| Its menu options, and that v1 vs v2 differ on `CIPDNS_CUR?`/`CIPDNS?` | **verified** — menu read off a real run, not from the program's strings |
| `.UART` / `.ESPBAUD` / `.ESPUPDATE` exist and what they are for | **verified** — read from the image |
| The wizard runs under jnext with `--esp`, and which half of it works | **verified** — measured, jnext 0.99.118 |
| The ESP persists credentials and auto-reconnects | **inferred**, not measured — see §5 |
| The stub's WiFi bring-up works on real hardware | **untested.** Nothing in this project has ever run on a real Next |
