#!/usr/bin/env python3
"""Tamper matrix for the measured-boot Pi: change one boot input, cold-boot, see which PCRs move.

For every case: mutate one file on the netboot server (with a backup), power-cycle the Pi through
the hub, collect live PCRs, the event-log replay, the event list, the final-device-tree verifier and
the serial log, then restore the file and confirm its hash. Results go to tests/results/<run>/.

  tests/tamper-matrix.py                 # all cases
  tests/tamper-matrix.py baseline-a kernel-append
"""
import hashlib, json, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TFTP = ROOT / "srv/tftp"
PI = "pi@10.42.0.124"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
       "-o", f"UserKnownHostsFile={ROOT}/netboot/known_hosts", PI]
SERIAL = ROOT / "netboot/serial.log"
PCRS = (0, 1, 4, 5)


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def in_srv(script):
    """Run a shell script as root against srv/ (files there are root-owned)."""
    r = sh(["docker", "run", "--rm", "-v", f"{ROOT}/srv:/srv", "-v", "/tmp/tamper:/x",
            "debian:trixie", "sh", "-euc", script])
    if r.returncode:
        raise RuntimeError(f"srv script failed: {r.stderr.strip()}")
    return r.stdout


def pi(cmd, timeout=60):
    r = sh(SSH + [cmd], timeout=timeout)
    return "\n".join(l for l in r.stdout.splitlines()
                     if "SSH may not work" not in l and "rptl.io" not in l)


def wait_for_pi(limit=300):
    t0 = time.time()
    time.sleep(40)
    while time.time() - t0 < limit:
        if sh(SSH + ["true"], timeout=15).returncode == 0:
            time.sleep(5)          # let the TPM driver and tss permissions settle
            return time.time() - t0
        time.sleep(5)
    raise RuntimeError("Pi did not come back")


def power_cycle():
    SERIAL.write_text("")
    r = sh([str(ROOT / "netboot/pi-power.sh"), "cycle"])
    if r.returncode:
        raise RuntimeError(f"power cycle failed: {r.stderr}")


def parse_pcr_block(text):
    out, bank = {}, None
    for line in text.splitlines():
        m = re.match(r"\s*(sha1|sha256):\s*$", line)
        if m:
            bank = m.group(1); out[bank] = {}; continue
        m = re.match(r"\s*(\d+)\s*:\s*0x([0-9A-Fa-f]+)", line)
        if m and bank:
            out[bank][int(m.group(1))] = m.group(2).lower()
    return out


def parse_events(text):
    events, cur = [], None
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("- EventNum:"):
            cur: dict = {"num": int(line.split(":")[1])}; events.append(cur)
        elif cur is None:
            continue
        elif line.startswith("  PCRIndex:"):
            cur["pcr"] = int(line.split(":")[1])
        elif line.startswith("  EventType:"):
            cur["type"] = line.split(":")[1].strip()
        elif "AlgorithmId: sha256" in line and i + 1 < len(lines):
            cur["sha256"] = lines[i + 1].split('"')[1]
        elif line.startswith("  Event:"):
            v = line.split(":", 1)[1].strip()
            if v.startswith('"'):
                try:
                    v = bytes.fromhex(v.strip('"')).decode(errors="replace")
                except ValueError:
                    v = v.strip('"')
            elif v.startswith("|") or not v:
                v = lines[i + 1].strip() if i + 1 < len(lines) else ""
            v = re.sub(r'^String: "(.*)"$', r"\1", v)
            cur["name"] = v
        elif line.startswith("pcrs:"):
            break
    return [e for e in events if e.get("type") != "EV_NO_ACTION"]


def collect():
    sel = "+".join(f"{b}:{','.join(map(str, PCRS))}" for b in ("sha1", "sha256"))
    live = parse_pcr_block(pi(f"tpm2_pcrread {sel}"))
    log = pi("sudo tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements 2>/dev/null")
    replay = parse_pcr_block(log[log.find("pcrs:"):]) if "pcrs:" in log else {}
    sh(["scp", "-q", "-o", "BatchMode=yes", "-o", f"UserKnownHostsFile={ROOT}/netboot/known_hosts",
        str(ROOT / "tools/verify/final-dt-digest.py"), f"{PI}:/tmp/"])
    dt = pi("sudo python3 /tmp/final-dt-digest.py")
    serial = SERIAL.read_text(errors="replace")
    replay_ok = all(replay.get(b, {}).get(p) == live.get(b, {}).get(p)
                    for b in ("sha1", "sha256") for p in PCRS)
    return {
        "live": live, "replay": replay, "replay_matches_live": replay_ok,
        "events": parse_events(log),
        "final_dt_verifier_sha256": (re.search(r"sha256 ([0-9a-f]+)", dt) or [None, None])[1],
        "not_measured": [l.strip() for l in serial.splitlines() if "NOT measured" in l or "NOT installed" in l],
        "hooks_installed": "hooks installed" in serial,
    }


def file_sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ---- cases: (name, description, mutation script run against /srv, files touched, expected PCRs) ----

def startelf_string_patch():
    data = (TFTP / "start.elf").read_bytes()
    off = data.find(b"Loaded overlay '")
    assert off > 0
    return f"printf 'l' | dd of=/srv/tftp/start.elf bs=1 seek={off} conv=notrunc status=none"


def overlay_variant():
    """tpm-eventlog overlay with one extra harmless property on the TPM node."""
    src = (ROOT / "firmware/overlays/tpm-eventlog.dts").read_text()
    src = src.replace("linux,sml-size = <0x8000>;", "linux,sml-size = <0x8000>;\n\t\t\ttamper-test = \"1\";")
    Path("/tmp/tamper").mkdir(exist_ok=True)
    (Path("/tmp/tamper") / "variant.dts").write_text(src)
    r = sh(["docker", "run", "--rm", "-v", "/tmp/tamper:/x", "debian:trixie", "sh", "-c",
            "apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "
            "device-tree-compiler >/dev/null && dtc -q -@ -I dts -O dtb -o /x/variant.dtbo /x/variant.dts"])
    if r.returncode:
        raise RuntimeError(r.stderr)
    return "cp /x/variant.dtbo /srv/tftp/overlays/tpm-eventlog.dtbo"


CASES = [
    ("baseline-a", "no change", None, [], set()),
    ("baseline-b", "no change (reproducibility)", None, [], set()),
    ("config-comment", "comment line appended to config.txt",
     "echo '# tamper test' >> /srv/tftp/config.txt", ["tftp/config.txt"], {1}),
    ("config-dtparam", "dtparam=audio=off appended to config.txt",
     "echo 'dtparam=audio=off' >> /srv/tftp/config.txt", ["tftp/config.txt"], {1, 5}),
    ("cmdline-arg", "' quiet' appended to the kernel command line",
     "sed -i 's/$/ quiet/' /srv/tftp/cmdline.txt", ["tftp/cmdline.txt"], {5}),
    # kernel8.img is gzip: appending bytes breaks start.elf's decompressor (measured fine, then no boot).
    # Recompressing keeps the kernel identical but changes the file.
    ("kernel-recompress", "kernel8.img recompressed with gzip -1 (same kernel, different file)",
     "apt-get -qq update >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y gzip >/dev/null; "
     "zcat /srv/tftp/kernel8.img | gzip -1 -n > /x/k && cat /x/k > /srv/tftp/kernel8.img",
     ["tftp/kernel8.img"], {4}),
    ("dtb-trailing", "16 zero bytes after the end of the base .dtb (beyond totalsize)",
     "head -c 16 /dev/zero >> /srv/tftp/bcm2710-rpi-3-b-plus.dtb", ["tftp/bcm2710-rpi-3-b-plus.dtb"], {5}),
    ("overlay-content", "tpm-eventlog overlay gains a property; config.txt unchanged",
     overlay_variant, ["tftp/overlays/tpm-eventlog.dtbo"], {5}),
    ("startelf-string", "one character of a start.elf log string changed",
     startelf_string_patch, ["tftp/start.elf"], {0}),
    ("unloaded-file", "an extra file nothing loads, added to the boot folder",
     "echo hello > /srv/tftp/unused-tamper.txt", ["tftp/unused-tamper.txt"], set()),
    ("rootfs-change", "/etc/motd changed in the root filesystem",
     "echo tampered >> /srv/rootfs/etc/motd", ["rootfs/etc/motd"], set()),
]


def run_case(name, desc, mutate, files, expected, outdir):
    print(f"\n=== {name}: {desc}", flush=True)
    backups = {}
    for f in files:
        p = ROOT / "srv" / f
        backups[f] = file_sha(p) if p.exists() else None
    if files:
        in_srv("; ".join(f"[ -e /srv/{f} ] && cp -p /srv/{f} /srv/{f}.tamper-bak || true" for f in files))
    try:
        if mutate:
            in_srv(mutate() if callable(mutate) else mutate)
        power_cycle()
        up = wait_for_pi()
        res = collect()
        res.update(name=name, description=desc, expected_changed=sorted(expected), boot_seconds=round(up))
    finally:
        restore = "; ".join(
            f"if [ -e /srv/{f}.tamper-bak ]; then mv /srv/{f}.tamper-bak /srv/{f}; else rm -f /srv/{f}; fi"
            for f in files)
        if restore:
            in_srv(restore)
        for f, h in backups.items():
            p = ROOT / "srv" / f
            now = file_sha(p) if p.exists() else None
            assert now == h, f"restore failed for {f}"
    (outdir / f"{name}.json").write_text(json.dumps(res, indent=2))
    print(f"    replay==live: {res['replay_matches_live']}  hooks: {res['hooks_installed']}  "
          f"not-measured: {res['not_measured'] or 'none'}", flush=True)
    return res


def warm_reboot_case(outdir):
    print("\n=== warm-reboot: reboot without power cycle (after a cold boot)", flush=True)
    power_cycle(); wait_for_pi()
    before = collect()
    SERIAL.write_text("")
    pi("sudo systemctl reboot", timeout=15)
    wait_for_pi()
    after = collect()
    # bootcode.bin pulses TPM RST# (GPIO4) every boot, so a warm reboot must look like a cold boot
    res = {"name": "warm-reboot", "description": "reboot without power cycle",
           "before": before, "after": after, "expected_changed": []}
    (outdir / "warm-reboot.json").write_text(json.dumps(res, indent=2))
    print(f"    after warm reboot replay==live: {after['replay_matches_live']}", flush=True)
    return res


def main():
    wanted = set(sys.argv[1:])
    run = time.strftime("%Y%m%d-%H%M%S")
    outdir = ROOT / "tests/results" / run
    outdir.mkdir(parents=True)
    Path("/tmp/tamper").mkdir(exist_ok=True)
    results = {}
    for c in CASES:
        if not wanted or c[0] in wanted:
            name, desc, mutate, files, expected = c
            results[name] = run_case(name, desc, mutate, files, expected, outdir)
    if not wanted or "warm-reboot" in wanted:
        results["warm-reboot"] = warm_reboot_case(outdir)

    base = results.get("baseline-a")
    lines = ["| case | expected | changed sha256 | changed sha1 | replay = live | verdict |", "|---|---|---|---|---|---|"]
    for name, r in results.items():
        if name == "warm-reboot" or not base:
            continue
        ch = {b: {p for p in PCRS if r["live"][b].get(p) != base["live"][b].get(p)} for b in ("sha1", "sha256")}
        exp = set(r["expected_changed"])
        ok = ch["sha256"] == exp and ch["sha1"] == exp and r["replay_matches_live"] and not r["not_measured"]
        lines.append(f"| {name} | {sorted(exp) or '-'} | {sorted(ch['sha256']) or '-'} | {sorted(ch['sha1']) or '-'} "
                     f"| {r['replay_matches_live']} | {'PASS' if ok else 'CHECK'} |")
    if "warm-reboot" in results:
        w = results["warm-reboot"]
        moved = [p for p in PCRS if w["after"]["live"]["sha256"].get(p) != w["before"]["live"]["sha256"].get(p)]
        lines.append(f"| warm-reboot | - (TPM reset via GPIO4) | {moved or '-'} | - | {w['after']['replay_matches_live']} | "
                     f"{'PASS' if not moved and w['after']['replay_matches_live'] else 'CHECK'} |")
    summary = "\n".join(lines)
    (outdir / "summary.md").write_text(summary + "\n")
    print("\n" + summary)
    print(f"\nresults: {outdir}")


if __name__ == "__main__":
    main()
