# Method and accuracy notes

This document covers how the analysis is produced and, more usefully, where it can be wrong.
Anything here that affects a particular scan is repeated in that scan's report under
*How these numbers were produced*, so nobody has to have read this to interpret the output.

---

## 1. Scanning

The scanner is an iterative walk over `DirectoryInfo.EnumerateFiles` / `EnumerateDirectories`,
streaming one record per file into the aggregator.

**Why iterative rather than `Get-ChildItem -Recurse`.** A recursive `Get-ChildItem` gives up the
whole subtree when it meets a folder it cannot read, buffers everything in memory, and cannot be
cancelled cleanly. The walk here catches per-directory, records the failure, and carries on, so a
scan of `C:\` returns a usable answer even though `System Volume Information` and other users'
profiles are unreadable. Every skipped location appears in the report — coverage is stated, not
assumed.

**Reparse points are not followed** unless asked. Junctions such as
`C:\Users\All Users` -> `C:\ProgramData` would otherwise be counted twice, and a symlink loop
would not terminate.

**Long paths.** Paths at or beyond 240 characters get the `\\?\` prefix so enumeration continues
past `MAX_PATH`. Shorter paths deliberately do not, because Windows PowerShell 5.1 on older .NET
Framework builds rejects the prefixed form.

**Hidden and system files are included.** They have to be: `hiberfil.sys`, `pagefile.sys` and
`$Recycle.Bin` are all hidden, and they are frequently the answer.

---

## 2. Three ways a size can lie

The report separates these rather than quietly folding them into one number.

**Cloud placeholders.** A OneDrive or SharePoint file with Files On-Demand reports its full logical
size while occupying almost nothing locally. Counting it as reclaimable would promise space that
does not exist — and "reclaiming" it by deleting it would delete the cloud copy too. Placeholders
are detected from the `Offline` attribute and the two recall attributes that have no entry in the
.NET enum, reported as their own total, and excluded from every reclaimable figure.

**Sparse files.** A sparse file's logical length overstates what it allocates. They are flagged and
counted separately.

**Hard links.** `WinSxS` is mostly hard links into `System32`, so its apparent size is far larger
than the space it occupies. No file-level walk can resolve this without opening every file, so the
tool does not try: the component store is classified Unsafe with a remediation that points at
`DISM /AnalyzeComponentStore`, which reports the real figure. That is why the deep probe exists.

---

## 3. Classification

Every file is matched against an ordered rule set; the first match wins. A rule can require any
combination of a directory pattern, a file name pattern and an extension list.

Path patterns are the expensive part, and files arrive grouped by directory, so the candidate rules
for a directory are computed once and cached. In practice that turns a scan of a million files into
roughly one regular expression pass per folder rather than per file.

`EligibleAfterDays` separates *classification* from *candidacy*: a two-day-old file in
`C:\Windows\Temp` is still classified as a temp file and still appears in the breakdown, but it does
not count toward reclaimable space, because something may still have it open.

Anything that matches nothing lands in `unclassified`, which is deliberately treated as **Review**
with Low confidence. Unidentified data is proposed last, after everything that has been positively
identified — recommending the deletion of data nobody can name is worse than recommending the
deletion of a larger pile that has been.

---

## 4. Age

Age is measured from **LastWriteTime**. `LastAccessTime` is reported separately as *idle days* and
never used for the age, because NTFS has had last-access updates disabled by default since Windows
Vista, which makes it unreliable and frequently identical to the creation time.

Timestamps in the future — clock skew, a bad archive, a restore from another machine — are clamped
to an age of zero rather than being allowed to produce negative ages that would corrupt the
histogram.

The *oldest data* table has a minimum file size (1 MB by default) because otherwise it fills with
ancient but trivially small files and says nothing about space.

---

## 5. Growth

Files are bucketed by creation month. The estimate is the **median of the last twelve complete
months**; the current month is excluded because it is always partial and would drag the figure
down. The median is used rather than the mean so that one month containing a server migration or
a software rollout does not dominate the forecast. When the busiest month exceeds four times the
median, the report says so.

Fewer than three complete months of data drops to averaging the entire scan over the age of its
oldest file, reported as **Low** confidence and labelled as an order of magnitude only.

### What this method cannot see

- **Deletions.** It only sees files that still exist, so a volume with heavy churn is understated.
- **In-place growth.** A database file, a virtual disk or an append-only log keeps one creation
  date while growing continuously. This is the largest single source of error on a server, and it
  errs toward *under*-estimating growth.
- **Copies.** Copying (rather than moving) data between volumes rewrites creation timestamps, so a
  recent bulk copy inflates the most recent months.

### Doing better

Where a real trend line already exists — RMM disk-space history, a monitoring system, or two runs
of this tool a month apart — feed it in and the estimate is used verbatim at High confidence:

```powershell
Invoke-DiskSpaceAnalysis -Path C:\ -KnownGrowthBytesPerMonth 4GB
```

This is why *Re-scan on a schedule* is in every plan's preventive controls. Two or three real data
points beat any single-scan estimate.

---

## 6. The plan

```
projected growth  =  growth per month  x  horizon months  x  safety factor   (default 1.25)
operating reserve =  max(15 % of capacity, 10 GB), capped at 25 % of capacity
target free       =  projected growth + operating reserve
shortfall         =  target free - free space today
```

The **operating reserve** is the point the volume should still be above at the *end* of the
horizon, not the point at which it fails. Windows starts behaving badly well before zero — updates
fail, shadow copies get discarded, page file expansion fails — so a plan that lands the volume on
empty on the last day of month six has not delivered six months.

The reserve is capped at 25 % of capacity so that the 10 GB floor cannot demand an unreasonable
share of a small volume; when the cap applies, the report says so.

Actions are then selected in order of:

1. **Safety** — everything Safe first, then Review. Unsafe is never selected.
2. **Confidence** — positively identified data before unidentified data.
3. **Size** — largest first within a tier.

Selection stops as soon as the shortfall is covered, so the plan proposes the least intervention
that reaches the target rather than everything it could possibly delete. If a volume already has
enough headroom, the Safe housekeeping is still proposed — that is what stops the headroom eroding.

When even everything reclaimable is not enough, the plan says so explicitly and reports the
shortfall, rather than presenting a partial cleanup as a solution. That case is a capacity problem,
and the escalations list is where the answer is.

---

## 7. System probes

Four things a directory walk cannot see or cannot act on, probed separately and each degrading
quietly to "unavailable, and here is why" rather than failing the analysis:

| Probe | Source | Needs elevation |
|---|---|---|
| Hibernation file | File length of `hiberfil.sys` | To read it |
| Page file allocation | `Win32_PageFileUsage` | No |
| Shadow copy storage | `vssadmin list shadowstorage` | Yes |
| Component store | `DISM /Online /Cleanup-Image /AnalyzeComponentStore` | Yes, and slow — `-DeepSystemProbe` only |
| Stale user profiles | `Win32_UserProfile` | Yes |

Where a probe and the file scan describe the same thing, the probe wins: it measures what is
actually allocated.

---

## 8. Safety model

| Level | Meaning | Automation |
|---|---|---|
| **Safe** | Regenerated by the OS or the application, or already a copy of something else | May be removed by an automated job |
| **Review** | Almost certainly reclaimable, but the owner, the size or a retention requirement must be confirmed | Requires an explicit override |
| **Unsafe** | Deleting it causes data loss or breaks the system | Never automated; the remediation is the answer |

Two invariants are enforced by the test suite rather than by convention:

- **Every Unsafe classification carries a remediation.** A classification that says "do not delete
  this" without saying what to do instead leaves a technician stuck, which is exactly the situation
  the tool exists to avoid.
- **The generated cleanup script never automates anything that is not Safe.** Everything else is
  emitted as a commented block carrying its remediation.

`Remove-DsaClassifiedFile` enforces the same model at runtime: it refuses Unsafe rules outright,
requires `-AllowReviewClass` for Review, will not accept an age threshold below the rule's own,
skips cloud placeholders, and treats a locked file as expected rather than as an error.
