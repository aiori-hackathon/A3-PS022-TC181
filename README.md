# PacketSentinel

**PS-022 · AIORI Hackathon 3 · Cybersecurity**  
**Bounded eBPF/XDP rate limiting for UDP DNS query floods in a private Linux lab**

> **Reviewed implementation package, not a verified performance claim.** Source, scripts, and documentation are included. Kernel verifier acceptance, NIC compatibility, nftables behavior, and comparative performance MUST be validated on the team's two-host lab before presentation.

## At a glance

| Feature | Implementation |
|---|---|
| Early filtering | XDP hook, native driver or generic skb mode |
| Safe parser | Ethernet (up to two VLAN tags) + IPv4 + UDP/53 + DNS header + bounded first question |
| Limits | Spinlock-protected per-source LRU hash and global bucket |
| Counters | Per-CPU passed, dropped and parser-status counters |
| Baselines | No-filter and nftables source/global rule |
| Scenarios | Steady, 0.5-s burst/on-off, increasing-rate ramp |
| Evaluation | Host B CPU, interface RX drops, Host A success rate, offered rate, XDP drop delta |
| Reproducibility | Fixed caps, commands, raw CSV schema and comparison scripts |

## Safety and scope

This tool is ONLY for a private, permissioned lab of two Linux hosts. The built-in load client **rejects non-RFC1918 destinations**, forbids public, loopback and link-local targets, and caps at **2,000 queries/s for 30 seconds, 8 workers**. Do not bypass those caps or point the tool at public infrastructure. No spoofing, reflection, amplification, recursion or Internet targets are implemented. On Host B the responder returns a short `NOERROR` no-answer response; it is not a production resolver.

## Repository contents

```text
src/xdp_dns.c          BPF/XDP bounded packet parser, token buckets, counters
src/packetctl.c        libbpf XDP attach/detach/configuration and stats
config/nftables.nft    comparable source/global nftables baseline (edit destination)
tools/dns_lab.py       constrained UDP DNS responder, probes, load generator
tools/metrics.py       CPU and interface drop collector on receiver
tools/compare.py       merge one run's observed measurements into results/runs.csv
tools/summarize.py     per-mode/per-scenario summary of actual samples
tools/nft_mode.sh      apply/remove isolated nftables table
tests/                 python unit tests
docs/                  setup, reproducibility, design, mentor demo, limitations
reports/               proposed technical report PDF
.github/workflows/     unit and BPF build checks on Linux runner
```

## Requirements

- Host A (sender): Linux and Python 3.10+ (no external Python packages).
- Host B (receiver): root with Linux kernel supporting XDP, BPF map spinlocks and libbpf; `clang` with BPF backend, `gcc`, `libbpf-dev`, `libelf-dev`, `linux-libc-dev`, `make`, `pkg-config`, `nftables`.
- Distinct, isolated RFC1918 addresses and an Ethernet-like XDP-capable interface. Example: Host A `192.168.56.10`, Host B `192.168.56.20`.
- **Recommended:** Ubuntu 24.04, a dedicated virtual network or VLAN, network admin permission, and clean test machines. Generic XDP fallback is allowed, but its results must not be represented as native XDP performance.

### Install dependencies (Host B)

```bash
sudo apt update
sudo apt install -y clang llvm gcc make pkg-config libbpf-dev libelf-dev linux-libc-dev nftables python3
make CLANG=/usr/bin/clang
sudo mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
```

Ensure `/sys/fs/bpf` is mounted, choose `IFACE` by running `ip -br addr`, and `cd` to this repository before running commands.

### DNS server: Host B

```bash
sudo python3 tools/dns_lab.py server --bind 192.168.56.20 --port 53
```

Stop conflicting DNS daemons bound to the intended address, if needed. If the server is not reachable across the lab network, fix networking first.

### Sanity check: Host A

```bash
python3 tools/dns_lab.py probe --target 192.168.56.20 --count 30
```

Test legitimate-query success without any load before proceeding. Python unit tests also run without root:

```bash
make test
```

## Three comparison modes (Host B)

Only one mode at once. Always run in the dedicated lab.

**A. No filter:** verify `sudo nft list table ip packetsentinel` reports no table and no project XDP program is attached. Do not reset other firewall rules.

**B. nftables:** edit `config/nftables.nft` to replace `192.168.56.20` with **Host B's actual address**, then:

```bash
bash tools/nft_mode.sh on
sudo nft -a list table ip packetsentinel
# After finishing this mode:
bash tools/nft_mode.sh off
```

**C. XDP:** identify **Host B's RX interface**, not the loopback interface:

```bash
sudo ./build/packetctl attach enp1s0 native 200 400 800 1600
# Use 'generic' in place of 'native' if the driver cannot attach native XDP.
sudo ./build/packetctl stats enp1s0
# After the test:
sudo ./build/packetctl detach enp1s0 native
```

Per-source rate/burst = 200 packets/s and 400 packets; global = 800 packets/s and 1600 packets. Set the same intended rates in nftables. `nftables` and XDP algorithms are not guaranteed semantically identical, so discuss enforcement differences.

## Reproducible run: collect all three scenarios

For **each** baseline mode (`none`, `nftables`, `xdp`) and **each** traffic pattern (`steady`, `bursty`, `ramp`), run the following with a **fresh mode initialization** and a one-minute cooldown. Use identical host addresses, rate caps, query names, durations, worker counts and background conditions. Because concurrent commands run across two hosts, synchronize clocks, start the receiver-side measurement first and overlap the probing period with the traffic.

On **Host B** (terminal 2):

```bash
python3 tools/metrics.py --iface enp1s0 --seconds 12 > metrics.json
# XDP mode only, snapshot stats BEFORE and AFTER:
sudo ./build/packetctl stats enp1s0 > xdp-before.json
# ... run 12-second window ...
sudo ./build/packetctl stats enp1s0 > xdp-after.json
```

On **Host A** (two terminals, in parallel):

```bash
python3 tools/dns_lab.py load --target 192.168.56.20 --pattern steady --pps 300 --seconds 10 --workers 2 > load.json
python3 tools/dns_lab.py probe --target 192.168.56.20 --count 30 --interval 0.3 --timeout 0.2 > probe.json
```

Replace `steady` with `bursty` and `ramp` for the other patterns. **Start `probe` and `load` at the same time** using parallel terminals. Generate 3 or more independent repetitions per mode × pattern when possible, and keep each JSON file separate. The receiver metric reports total machine CPU busy % (not exclusively BPF costs); measure a stable idle baseline and avoid other workloads. The `ramp` pattern intentionally sends a lower average offered rate than the other patterns; compare its **observed achieved PPS** rather than assuming identical packet volumes.

Copy result files to one machine. For each observed test:

```bash
python3 tools/compare.py --mode xdp --pattern steady --load load.json --probe probe.json --metrics metrics.json --xdp-before xdp-before.json --xdp-after xdp-after.json
python3 tools/summarize.py results/runs.csv
```

Omit `--xdp-before/--xdp-after` for `none` and `nftables`. **Host B kernel RX drops are not the same as XDP decision counters or nftables drop counters.** For nftables counters, use `sudo nft -a list table ip packetsentinel` before/after the run, and preserve those snapshots as evidence. For an analysis comparing packet drops, label each counter's measurement location precisely.

## Quality review

See [`docs/CODE_AUDIT.md`](docs/CODE_AUDIT.md) for resolved findings, remaining risks and the exact validation boundary. The Python test suite exercises query encoding and the local mock responder but cannot substitute for Linux BPF verifier and NIC tests. The included PDF remains a technical-report draft, not a results-backed final submission.

## Design trade-offs

- IPv4 total-length and UDP-length consistency are checked before DNS header access. Parsing handles Ethernet with up to two VLAN tags, IPv4, UDP destination port 53, query QR=0, QDCOUNT=1, and a bounded first DNS name up to 255 wire bytes; DNS name compression in the first question is rejected. IPv6, more than two VLAN tags, IPv4 fragments and non-target traffic pass through. Fragment bypass is a known evasion; never imply complete DNS flood prevention.
- The first blocked packet at the source stage does not consume a global token. A global rejection **does** consume a per-source token. Source LRU eviction can allow bursts after source state removal.
- `bpf_spin_lock` serializes updates to the global bucket; this prioritizes correctness over maximum multicore throughput. The BPF verifier and native-NIC acceptance must be checked in the target lab.
- An unset/invalid configuration or map lookup failure **fails open**, increments `map_failure` when possible, and avoids inadvertently blackholing DNS. Document this choice in mentor demo.
- Native XDP is before normal `skb` allocation; generic XDP does not provide the same early-drop advantage.
- DNS responses do not exercise this filter because the filter targets inbound queries only.

## Required deliverables

1. A **private** GitHub repository named after the team (`PacketSentinel` if that is the registered name). Add `aiori-hackathon` as collaborator; the brief requests transfer of ownership to that account after acceptance and coordination with the team. Check this process with organizers before surrendering owner permissions.
2. Upload required structured PDF; `reports/PacketSentinel-Technical-Report.pdf` is an implementation/report draft based on the supplied problem statement and proposal. The separately mentioned `Proposed-structure-hackathon.pdf` was **not provided**; check the organizer's official template and adapt before final submission.
3. Demonstrate compilation, live receiver, filter, counters, all three modes and pseudocode to the mentor; follow `docs/DEMO.md`.
4. Supply actual `results/runs.csv`, `results/summary.json`, configurations, logs/screenshots and discussion of legitimate query impact after lab runs. Sample values must not be invented.

## References

- [Linux kernel BPF documentation](https://docs.kernel.org/bpf/)
- [RFC 1035 DNS message format](https://www.rfc-editor.org/rfc/rfc1035)
- [nftables meter examples](https://wiki.nftables.org/wiki-nftables/index.php/Meters)

## License

MIT user-space/tools and GPL-2.0 BPF source; see `LICENSE` and source headers.

## Repeatable measurement runner (Host A)

Set up Host B's DNS responder, choose **one** filtering mode on Host B, and establish authorized SSH key access from Host A. Both hosts must have the repository checked out and run commands from its root. The runner does **not** change firewall policies or attach XDP automatically. For XDP counters, `sudo -n` must be allowed for the stats command on Host B.

```bash
python3 tools/experiment.py --target 192.168.56.20 --receiver labuser@192.168.56.20 --iface enp1s0 --mode none --pps 300 --seconds 10 --repeats 3
# repeat after manually enabling nftables, with --mode nftables
# repeat after manually enabling native or generic XDP, with --mode xdp
python3 tools/summarize.py results/runs.csv
python3 -m pip install matplotlib
python3 tools/plot_results.py results/runs.csv
```

The three mode invocations produce **27 measured runs** in aggregate (3 patterns × 3 repeats × 3 modes). Check modes and receiver paths before each invocation. Plots are produced only from observed CSV values; no results are generated or inferred in advance. See [validation status](docs/VALIDATION.md).


## Latest corrections and release checklist

See [Release Readiness](docs/RELEASE_READINESS.md) for updated protocol bounds, rate-limit accounting, verification details and remaining Linux-only validations. The experiment harness performs a read-only receiver-mode verification before every trial. It will stop if both nftables and XDP are present, or if the wrong mode appears active. The check cannot prove identity of an attached XDP program; inspect with `bpftool` as well.

**No performance gains are claimed without reproducible measurements.**
