# Resource Monitor

A Windows application that measures what a machine is actually spending its CPU, memory, disk and
network on, **names every process and who makes it**, works out **which resource is the constraint**,
and produces an **ordered plan** for making the machine usable again.

It runs as a desktop window for interactive triage, and as a command-line script for scheduled runs
from an RMM. Nothing on the machine is changed.

```
Sample  ->  Identify  ->  Group by product  ->  Find the constraint  ->  Plan  ->  Report / tuning script
```

---

## Why not just open Task Manager

Task Manager tells you `svchost.exe` is using 31% of the CPU and that `chrome.exe` appears
forty-one times. Neither fact tells you what to do. This tool answers the questions that follow.

| Question | Where the answer comes from |
|---|---|
| What is this process? | A catalogue of ~90 entries covering Windows internals, browsers, security and RMM agents, sync clients, OEM utilities, development tools, virtualisation and the software that exists to slow machines down |
| Who makes it? | The catalogue, the Authenticode signature, and the version resource in the file — in that order of preference, and the report says which one it used |
| Is this reading normal? | Every catalogue entry carries what normal looks like for that process, so a large number can be judged rather than just reported |
| What is `svchost` actually doing? | The services hosted inside that specific instance, by name |
| How much is Chrome *really* using? | Processes grouped by product, because forty-one processes at 300 MB are one 12 GB problem, not forty-one problems |
| Which resource is the problem? | CPU, memory, disk and network each scored on the measurement that matters for it, with the highest above the "a person would notice" line named as the constraint |
| What do I do first? | An ordered plan: impact, then how safe the change is, then how much work it is |
| What if nothing on screen explains it? | Checks for the causes that never appear in a process list — a pending restart, a mechanical system disk, a full system volume, two antivirus products, a throttled processor, a crash loop |

**Two things it will not do.** It never proposes stopping, disabling or removing a component Windows
needs — for those the action is the supported way to reduce what is driving it. And it never reports
a number it did not measure: a process whose rate could not be sampled reads `n/a`, not `0%`.

---

## Requirements

- Windows 10 / 11, or Windows Server 2016 or later
- Windows PowerShell 5.1 (in the box) or PowerShell 7
- No installation, no dependencies, no internet access needed
- Runs unelevated; elevation adds the path, command line and owner of other users' processes

---

## Quick start

**Desktop window**

```
tools\Start-ResourceMonitor.cmd
```

Or from a PowerShell prompt:

```powershell
Import-Module .\src\ResourceMonitor\ResourceMonitor.psd1
Show-ResourceMonitor
```

Press **Quick scan** or **Complete scan** and work through the tabs: *Verdict* for what is wrong and
what to do first, *Plan* for every action with the evidence behind it, *By product* for the grouped
consumers, *Processes* for everything with its publisher, *Starts itself* for what launches at
sign-in and what it costs, *The machine* for the hardware. The buttons along the bottom save an HTML
report, a tuning script, JSON or a CSV of every process.

**Command line**

```powershell
# Look at this machine and print the report
.\tools\Invoke-ResourceMonitor.ps1

# Just the verdict and the plan
.\tools\Invoke-ResourceMonitor.ps1 -ScanMode Complete -PlanOnly

# Scheduled run: write a report to a share, say nothing on the console
.\tools\Invoke-ResourceMonitor.ps1 -ScanMode Complete -Quiet `
    -Report \\fs01\reports\$env:COMPUTERNAME.html `
    -Json   \\fs01\reports\$env:COMPUTERNAME.json
```

It exits `0` when nothing high-impact was found, `1` when something was, and `2` if the scan itself
failed — so an RMM can alert on the exit code alone.

**As a module**

```powershell
Import-Module .\src\ResourceMonitor\ResourceMonitor.psd1

$result = Invoke-ResourceAnalysis -ScanMode Complete

$result.Plan.NarrativeText
$result.Plan.Actions | Where-Object Impact -eq 'High' | Format-List Title, Evidence, Recommendation
$result.Hogs.Families | Select-Object -First 10 Family, Vendor, MemoryText, CpuText, ProcessCount

$result | Export-RmoReport -Path .\report.html
$result | New-RmoRemediationScript -Path .\tune.ps1
```

---

## Quick scan and complete scan

| | Quick | Complete |
|---|---|---|
| Measured intervals | 1, about 1.5 s | 3, about 7.5 s |
| Typical total time | 5–15 seconds | 1–2 minutes |
| Publisher from | the file's version resource | the **Authenticode signature**, verified |
| Startup entries | Run keys and startup folders | plus **scheduled tasks** with a logon or boot trigger, which Task Manager's Startup tab does not show |
| Process owners | – | the account each of the heaviest processes runs as |
| Counters | machine totals | plus **per-disk**, per-adapter and **GPU engine** |
| Event log | – | **crash, hang and unexpected-shutdown history** |
| Best for | "what is it doing right now" | intermittent problems, and machines that are unreliable rather than merely slow |

A quick scan says so in its own verdict, so a reader knows what it did not look at.

---

## How the constraint is decided

Each resource is scored 0–100 on the measurement that actually matters for it, and the highest score
above 65 becomes the constraint. The scoring is deliberately not "whichever number is biggest".

- **CPU** — total busy time, raised into the critical band when the run queue is deeper than about
  two threads per core. A processor at 100% with nothing waiting is a machine doing work; the same
  figure with a deep queue is a machine that will not respond to a click. Time that belongs to *no
  process* is separated out and reported on its own, because that is a driver, and closing
  applications cannot touch it.
- **Memory** — the worst of three independent signals: how much is available, how close the commit
  charge is to the limit, and whether hard page faults are running with little memory left. The size
  of the compressed page store is treated as evidence in its own right, because Windows only
  compresses pages to avoid writing them to disk.
- **Disk** — **latency first, utilisation second.** "Disk 100%" only means the queue was never
  empty, which on an NVMe device happens during any file copy without anyone noticing. Thirty
  milliseconds per transfer is where a person starts to feel it.
- **Network** — throughput against each adapter's link speed.

One rule overrides the ranking: **a machine out of memory drives its disk hard**, so on a machine
with severe memory pressure *and* hard page faults, the disk is a symptom and memory is named as the
constraint. Getting that backwards sends somebody off to replace the wrong component.

---

## The plan

Every finding — from processes, from startup, and from the machine itself — is ranked on one scale:
**impact**, then **how safe the change is**, then **how much work it is**. So among equally useful
actions the safe, quick ones are offered first.

Each action carries what was measured, what the thing is, who publishes it, what to do, and what to
expect from doing it:

```
[HIGH] 4. Google Chrome - Google LLC
     Category: Browser | Effort: Quick | Risk: Review
     Measured: 1.2 GB memory (Private working set), 40.0% of total CPU, 32.0 MB/s disk,
     2 processes, 14.6% of fitted memory
     What it is: Web browser. Runs one process per tab, per extension and per subframe, which is
     why it appears dozens of times. What normal looks like: Each tab is 50-400 MB. The individual
     numbers are meaningless; the family total is what matters.
     Do this: Judge it on the family total, not per process. Turn on Memory Saver so background
     tabs are discarded, audit extensions (they run all the time, not just when the tab is open),
     and treat a hundred open tabs as the capacity problem it is.
     Expected gain: Frees up to 1.2 GB of memory
```

The same reading is rated differently on different machines: 2.6 GB of browser is the headline on an
8 GB laptop that is paging and a footnote on a 64 GB workstation with 40 GB free.

---

## The generated tuning script

`New-RmoRemediationScript` writes a script that carries the plan to the machine. **It does nothing
when it is run.** It has to be told which action to apply, by id:

```powershell
.\tune-PC01.ps1                       # print the plan and the ids
.\tune-PC01.ps1 -List                 # ids only, marked [can run] or [manual]
.\tune-PC01.ps1 -Run power-plan-saver -WhatIf
.\tune-PC01.ps1 -Run power-plan-saver
```

Only mechanical, reversible, machine-level steps are ever runnable. Anything that restarts the
machine, removes software or ends a process is carried as documentation and refuses to run, and so is
every command that came from a catalogue entry — those are worked examples with placeholders in them,
written for a person to adapt.

---

## Teaching it about your own software

A line-of-business application appears as a filename with whatever publisher its version resource
happens to carry. Give it a proper entry with an overlay catalogue:

```powershell
# SiteApps.psd1
@{
    Entries = @(
        @{
            Id = 'site-ledger'
            Match = @('ContosoLedger', 'ContosoLedgerSync')
            Name = 'Contoso Ledger'
            Vendor = 'Contoso Software Ltd'
            Family = 'Contoso Ledger'
            Class = 'Productivity'
            Description = 'The finance system. The sync service holds an open connection to SQL.'
            Expected = '300-600 MB. More during month end, when it caches the whole ledger.'
            Guidance = 'Do not stop the sync service during working hours - it will not reconcile.'
        }
    )
}
```

```powershell
Invoke-ResourceAnalysis -ScanMode Complete -CatalogFile .\SiteApps.psd1
```

Entries are merged by `Id`, so an overlay can also override a shipped one. A name claimed by two
entries is reported as a collision rather than silently lost.

---

## What it does not do

- **Per-process network use.** Windows only exposes that through ETW, which is out of scope here.
  Network is reported per adapter.
- **Change anything.** A scan is read-only. The tuning script is the only thing that can change the
  machine, and only when it is told to.
- **Judge whether software belongs on the machine.** It reports what something is, who makes it and
  what it costs. Whether the person using the machine needs it is not a measurement.
- **Diagnose a problem that is not happening.** A scan measures the machine as it is now. If the
  complaint is "it is slow first thing in the morning", run the scan then.

---

## Tests

```
pwsh -File .\tests\Invoke-Tests.ps1
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1
```

No dependencies — the harness is in the repository. 150-odd assertions, and it exits with the number
of failures so it can gate a build.

The whole analysis pipeline is tested against synthetic machine states, and the collection functions
are tested against a fixture that stands in for WMI (`tests/FakeCim.ps1`), so the counter
differencing, unit conversions, process-id reuse detection and service attribution are all verified
rather than assumed — including on a machine that is not under load, and on a host that is not
Windows. On Windows the suite additionally runs a real scan end to end.

---

## Layout

```
src/ResourceMonitor/
  Data/ProcessCatalog.psd1     what each process is, who makes it, and what to do about it
  Private/                     formatting, scoring, publisher lookup, report rendering
  Public/                      the commands, one per file
tests/                         the harness, the WMI fixture and the suite
tools/                         launchers for the window and the command line
docs/METHOD.md                 how each figure is measured, and what it does and does not mean
```
