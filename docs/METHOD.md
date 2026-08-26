# Method

How each figure in the report is arrived at, and — more importantly — what it does and does not
mean. Every number in a performance report is a claim, and a claim that cannot be defended is worse
than no number at all.

---

## 1. Processor time

### How it is measured

Processor use cannot be read; it can only be measured. `Win32_Process` reports
`KernelModeTime` and `UserModeTime`, which are the total processor time a process has consumed
*since it started*. On a process that has been running for a week, that says nothing about now.

So the scan takes two or more snapshots separated by a real interval and differences them:

```
CPU %  =  (KernelModeTime + UserModeTime consumed during the interval)
          / (interval x logical processors)
          x 100
```

The times are in 100-nanosecond units. The interval is measured with a `Stopwatch` rather than
assumed from the requested sleep, because a snapshot of several hundred processes is not free and the
requested interval is a floor, not a promise.

### 100% means the whole machine

The result is normalised by the logical processor count, so it reads the way Task Manager reads: a
single-threaded process saturating one core of eight shows **12.5%**, not 100%. This is a choice, and
it is the one that lets the figures be added up — twelve processes at 8% each is a machine that is
fully committed, and that only reads correctly under this convention.

### Process-id reuse

Windows reuses process ids. If the creation time attached to an id changes between two snapshots,
that id now belongs to a different program, and differencing the two would invent a figure — usually
a spectacular one, since the new process may have accumulated far more or far less time. Those are
reported as unmeasured.

### Processes that appear mid-scan

A process created between snapshots has a size but no baseline, so no rate can be derived for it. It
is reported with `n/a`, never `0%`. Reporting zero would be a claim the scan cannot support, and on a
short scan it is exactly the wrong claim: an installer that has just started is the most likely thing
to be at the top of the list.

### Time that belongs to no process

The performance counter `\Processor(_Total)\% Processor Time` includes interrupt and
deferred-procedure-call work, which is charged to no process at all. The difference between it and
the sum of the per-process figures is reported separately as **unattributed** time.

This is one of the more useful numbers in the report. Sustained unattributed time is driver code
running on behalf of hardware — storage, network, audio — and no amount of closing applications will
reduce it. A failing disk produces it as retries. An old Wi-Fi driver is the single most common cause
on a laptop.

Where the counter is unavailable, the sum of the per-process figures is used as the total instead, and
unattributed time then reads as zero because it cannot be separated.

---

## 2. Memory

### Which figure is being quoted

There are three plausible answers to "how much memory is this process using", and they differ by
gigabytes on a browser:

| Figure | What it is | Source |
|---|---|---|
| Working set | Physical memory the process has mapped, **including pages shared with other processes** | `Win32_Process.WorkingSetSize` |
| Private working set | Physical memory this process alone is holding. This is Task Manager's *Memory* column | `\Process(*)\Working Set - Private` |
| Private bytes | Committed address space, whether or not it is resident | `Win32_Process.PrivatePageCount` |

The report uses the **private working set** where the performance counter class could be read, and
falls back to the whole working set where it could not. Which one was used is stated in the output,
per row and per group, because it changes how a total should be read.

This matters when adding up. The whole working set counts a page shared between thirty browser
processes thirty times, so a grouped total built from it is an **upper bound**, not a measurement.
The private working set can be added up honestly, which is why it is preferred.

### Pressure

Three independent signals, worst one wins:

- **Available memory** as a share of what is fitted. On its own the least reliable of the three,
  because Windows will happily use most of the machine for cache without anything being wrong.
- **Commit charge against the commit limit.** This is the number that decides whether an allocation
  *succeeds*. Reaching it does not make the machine slow, it makes applications fail — which is a
  different and worse failure, and one that arrives without warning.
- **Hard page faults** (`\Memory\Page Reads/sec`) running with less than a gigabyte available. This is
  thrashing: the memory manager reading pages back from disk because there was nowhere else to put
  them. It is the worst state a machine can be in, and it scores 95 on its own.

The **compressed page store** — the `Memory Compression` process — is treated as evidence rather than
inference. Windows only compresses pages to avoid writing them to disk, so a store past a tenth of
physical memory means the machine is already trying to avoid paging. Past that threshold it scores 88
regardless of the other signals.

---

## 3. Disk

### Latency, then utilisation

`% Disk Time` is the most quoted and least useful storage counter on Windows. It reports that the
queue was not empty, which on an NVMe device happens during any file copy without a person noticing
anything. A disk at 100% utilisation and 1 ms per transfer is keeping up perfectly.

So the primary measure is **average seconds per transfer**, converted to milliseconds:

| Latency | Reading |
|---|---|
| under 5 ms | healthy |
| 5–15 ms | busy, and noticeable on a spinning disk |
| 15–30 ms | the machine feels sluggish at everything involving a file |
| over 30 ms | the disk is why nothing responds |

Thirty milliseconds is where the latency term reaches full scale. Utilisation contributes at a 40%
discount, and a queue deeper than four outstanding requests raises the floor to 80.

### What the disk is

The media type comes from `MSFT_PhysicalDisk` in the Storage namespace, which reports HDD, SSD or
storage-class memory directly. On older builds where that namespace is absent, the model string is
used as a weaker signal and the report says so — `SSD (from model name)` rather than `SSD`.

This distinction changes the recommendation completely. High latency on an SSD means finding what is
issuing the I/O. High latency on a 5400 rpm laptop drive under Windows 11 means the disk is the
answer, and every software change is working around it.

### Per-process disk figures

Differenced from `ReadTransferCount` and `WriteTransferCount`, which count **all** I/O the process
performed — file, network and device. It is not "disk bytes". For finding what is hammering the
storage it is the right signal anyway, and the `System` process legitimately carries the file system
and paging traffic for the whole machine.

---

## 4. Network

Per adapter, from `\Network Interface(*)\Bytes Total/sec` against `Current Bandwidth`. The loopback,
ISATAP and Teredo pseudo-interfaces are excluded — loopback carries local traffic and would otherwise
dominate the total on any machine running a database or a local web server.

**Per-process network use is not reported.** Windows only exposes it through ETW, which needs a trace
session and elevation, and is out of scope for a tool that has to run unelevated in a support call.

---

## 5. Which resource is the constraint

Each resource carries a 0–100 score. The highest above **65** is named as the constraint; 65 is the
point at which a resource stops being merely busy and starts being felt by the person using the
machine. Below that the report says there was no single constraint, which is a real and common
answer — and an important one, because it means the complaint is about something a capacity
measurement cannot see.

One rule overrides the ranking:

> A machine that is out of memory drives its disk hard. Where memory pressure is severe **and** hard
> page faults are running, the disk is a symptom, and memory is named as the constraint with the disk
> as secondary.

Without that rule, the most common seriously-degraded machine — 8 GB of RAM, everything open, paging
continuously — reports as disk-bound. The disk would then get replaced, the machine would page
faster, and it would still be slow.

---

## 6. Identifying processes and their publishers

Three sources, and the report always says which one it used.

**The catalogue** (`Data/ProcessCatalog.psd1`) is matched first by exact process name, then by
pattern in priority order. Exact names always win, so the deliberately broad
`(service|svc|agent|host|helper|tray|monitor)` fallback can never take a process a real entry claims.
It supplies the name, the publisher, the class, whether the process is essential, what normal looks
like, and what to do.

**The Authenticode signature** supplies a publisher a certificate authority verified. It is the most
trustworthy attribution available on the machine, and it is only read on a complete scan because
verifying it can touch the network for revocation checking.

**The version resource** in the file supplies `CompanyName`, `FileDescription` and `ProductName`.
Anyone can write anything into these, so they rank last.

Publisher precedence is not simply "catalogue first". Many entries cover a family of products from
different vendors — endpoint security agents, OEM utilities, game launchers — and carry a placeholder
such as `Various`. Where the catalogue is only holding a placeholder and the file can name the actual
publisher, **the file wins**, because at that point it knows the specific answer and the catalogue
does not.

A process the catalogue has never heard of still gets a name and a manufacturer from the file. Only a
process whose executable cannot be read at all comes back unknown — which on an unelevated scan mostly
means it belongs to another user.

### Grouping

Consumers are grouped by the catalogue's `Family` key. This is what turns forty-one `chrome.exe`
processes into one 12 GB finding. Two deliberate choices:

- **Edge WebView2 is kept separate from Edge.** It is not a browser window; it is an embedded copy of
  the engine that other applications use to draw their interface — the current Teams and Outlook,
  Widgets, and a great deal of line-of-business software. Attributing it to Edge would hide the
  application that is actually hosting it, which is the thing a person needs to act on.
- **Service hosts are labelled with their services.** `svchost.exe` is a container, not a workload,
  so each instance is reported with the display names of the services running inside it and the
  `-k` group from its command line.

---

## 7. Startup

Four sources, because software has largely stopped using the obvious one:

- **Run keys and startup folders**, through `Win32_StartupCommand`, cross-referenced with the
  Explorer `StartupApproved` keys so that entries a user has already switched off in Task Manager are
  not counted against them. The state lives in a binary value whose first byte is even when enabled
  and odd when disabled.
- **Scheduled tasks** with a logon or boot trigger. These do not appear in Task Manager's Startup
  tab, which is why it can look clean on a machine that takes four minutes to settle. Windows' own
  maintenance tasks under `\Microsoft\` are excluded — there are hundreds, and they are not what
  makes a machine slow to sign in.
- **Automatic services**, counted and split by whether they are delayed, because that count decides
  how long the machine takes to become usable after a restart.

Each entry's executable is resolved from its command line — which may be quoted, may carry arguments,
and may contain spaces with no quoting at all — by cutting at the first executable extension. That
deliberately does not depend on the file still being present, because a Run key frequently outlives
the software it points at, and those entries are worth reporting.

An entry is then matched against what is running, so its impact can be rated on **what it is costing
right now** rather than on the mere fact of its existence.

---

## 8. Checks that are not about a process

Several causes of an unusable machine never appear in a process list, and some of them outweigh
anything that does:

| Check | Why it matters |
|---|---|
| Pending restart | Servicing keeps re-staging the same work and files stay locked. It also makes every other measurement less trustworthy, which is why it sorts first |
| Mechanical system disk | A few hundred random operations per second against tens of thousands. No software change closes that gap |
| System volume under 10% free | The page file cannot expand, servicing has nowhere to stage, writes fragment |
| Memory below what the build needs | Windows, the security agent and a browser will consume most of 8 GB before the user opens anything |
| Free memory slot | The cheapest hardware fix there is, and only worth saying when memory is actually short |
| Commit near the limit | Allocations start failing rather than slowing down |
| Page file disabled | Removes the commit headroom the system needs. Somebody did this on purpose, following advice that has been wrong for twenty years |
| Power-saving plan | The processor is capped below what the hardware can do |
| Clock far below rating under load | Thermal throttling or a firmware power limit — dust and dried thermal paste on an older laptop |
| Two real-time antivirus products | Every file operation inspected twice, for no additional protection |
| Basic Display Adapter | All compositing falls back to the processor |
| Crash, hang and shutdown history | A machine that is failing rather than slow. Performance tuning is the wrong response |

The event log checks only run on a complete scan. `Get-WinEvent` reports "no events found" as an
error, which is the answer the scan wanted, so that particular message is not recorded as a failure.

---

## 9. Ranking the plan

Actions from all three sources — processes, startup and the machine — are ranked on one scale:

1. **Impact** — High, Medium, Low, Info.
2. **Risk** — Safe, then Review, then Caution.
3. **Effort** — Instant, then Quick, then Planned, then Hardware.
4. **Weight** — the size of what it would recover.

So among equally useful actions, the safe and quick ones are offered first.

Impact is judged against the constraint, not in the abstract. The thresholds scale with the machine:
"significant" is the larger of 300 MB and 4% of fitted memory, and "large" the larger of 1 GB and
12%. A product that is not on the critical path is capped one level down, which is how 2.6 GB of
browser can be the headline on one machine and a footnote on another.

**Essential components are handled differently.** Anything the catalogue marks as essential — the
kernel, service hosts, the shell, the security subsystem — never receives a proposal to stop,
disable or remove it, is capped at Medium, and carries no command. The action for those is the
supported way to reduce what is driving them.

**Recoverable memory** totals only the software that could actually be reduced. Essential components
are excluded, and so are startup actions, because a startup entry and a process action frequently
describe the same software and counting both would promise the same memory twice.

---

## 10. Robustness

A scan reads around twenty CIM classes, several of which are absent or broken on any given machine —
a de-registered performance counter class, a Storage namespace that is not on Server 2012 R2, a WMI
repository that needs rebuilding. Every reading is taken independently, and a failure costs that one
reading rather than the scan. What could not be read is listed at the end of the report, because a
missing counter changes how the rest should be interpreted.

The one exception is `Win32_Process`: without it there is nothing to measure, and the scan fails with
an explanation rather than reporting an empty machine.

---

## 11. What a scan cannot tell you

- **It measures now.** If the complaint is about a particular moment — first thing in the morning,
  during a meeting, when one application is used — the scan has to be run then.
- **A quick scan sees one interval.** A process that is busy in bursts may be caught mid-burst or
  missed entirely. That is what the complete scan's longer window is for, and a quick scan says so in
  its own verdict.
- **Unelevated, other users' processes are partly opaque.** Their path and command line cannot be
  read, so some are named only by their executable. The report states whether it had elevation.
- **Whether software belongs on the machine is not a measurement.** The report says what something
  is, who makes it and what it costs. The decision is a person's.
