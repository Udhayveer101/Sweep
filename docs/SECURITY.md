# Security and safety

A cleanup tool has unusually powerful filesystem reach, so the design assumes the filesystem is
hostile and that its own scan results are stale by the time they are acted on.

## Guarantees

These are enforced in `SafetyEngine.eligibility`, which the executor calls again for every item
immediately before touching it. Each has a test.

1. **Nothing outside `$HOME` is eligible.** Not by traversal, not by `..`, not by symlink, not
   by a caller passing an absolute path directly.
2. **`$HOME` itself is never eligible.**
3. **Symlinks are never followed and never deleted as if they were their target.** The check
   runs on the *lexical* path before normalization, because resolving first would turn "a link
   inside my home" into whatever it points at.
4. **Cross-volume paths are refused.** A mounted disk image or network share inside the home
   folder is not treated as home-scope.
5. **The immutable protection list cannot be overridden**, including by the user.
6. **Data belonging to a running application is refused**, checked at scan and again at delete.
7. **Only `.safe` items are ever deleted.** `.review`, `.unknown` and `.protected` are refused
   by the executor even if a caller explicitly asks.
8. **Deletion is Trash-first** unless the user opts into permanent deletion in Settings. Items
   already in the Trash are the sole exception, because emptying the Trash has no other meaning.

## Threat model and mitigations

| Threat | Mitigation |
|---|---|
| Symlink escape (`~/Library/Caches/x → /etc`) | Lexical symlink detection before normalization; refused, tested |
| Symlink loop | Traversal never follows links at all; loop is impossible |
| TOCTOU: item changes between scan and delete | Full re-validation: eligibility, existence, symlink status, and modification date |
| TOCTOU: item replaced by a symlink after scanning | `lstat`-based checks, re-run at delete time |
| Path traversal via crafted filenames | Paths are normalized and component-checked; never passed to a shell |
| Malicious deep nesting | Depth cap (24) with the skip recorded |
| Directory with millions of entries | Entry budget (400k) checked per entry, not per directory |
| Mount point inside home | Device-ID comparison against the home volume |
| Files vanishing mid-scan | Recorded as skips; never fatal |
| Partially inaccessible directories | Recorded as permission-denied skips and surfaced in the UI |
| Concurrent scans racing on the same paths | Actor-enforced single-scan-in-flight lock |
| Two scanners claiming the same bytes | Structural dedup, including nested paths |
| A scanner crashing or hanging the whole run | Per-scanner failure isolation; partial results are reported as partial |
| Privilege escalation | No privileged code exists: no helper, no XPC, no elevation |
| Data exfiltration | No networking code in the project |
| History log leaking what was on the Mac | Local only, `0600`, never transmitted |

## Deliberately not defended against

- **An attacker who already has code execution as this user.** They do not need Sweep.
- **Hardlinked files.** Removing one link of a multiply-linked file frees no space, so the
  verified figure can overstate the true saving in that case. Rare in the scanned categories.
- **A crash during cleanup.** Items already moved are in the Trash and recoverable through
  Finder, but that interrupted run is not written to the history log, which is only recorded on
  completion. Recovery is unaffected; only the record is lost.

## The malware scanner's own threat model

A security product is a high-value target. The protection scanner adds this surface, and these
mitigations, on top of everything above.

| Threat | Mitigation |
|---|---|
| Malicious definition update controlling what gets quarantined | HTTPS only, size-capped, content validated before it is trusted, staged and swapped atomically, previous set retained on failure, no user-supplied update URL |
| Hostile file crashing or exploiting the scanner | Every scanned byte treated as hostile input: bounded reads, no shell invocation anywhere in the scan path, parse failures become findings-of-unknown |
| Oversized or pathological file | Hard byte cap on hashing; the artifact is reported as unchecked rather than silently treated as clean |
| TOCTOU between detection and quarantine | Content hash re-verified immediately before the move; a changed file is refused |
| Symlink attack during quarantine | `lstat` on the lexical path; links are refused, never followed |
| Quarantine used as an execution vector | Stored outside any loader-scanned path, execute bits stripped, `0700` directory and `0600` entries |
| Quarantine store losing track of a file | Journal written before the move, so a crash leaves a recoverable record rather than an orphan |
| Code-signing or bundle-identifier spoofing | Identity keyed on cdhash and signing certificate, never on bundle ID or path |
| The scanner being weaponised to delete good files | Nothing is ever deleted: quarantine only, reversible, with verified restore |
| A false positive arriving pre-selected | Only exact-identity evidence (file hash or signing certificate) may pre-select; asserted in tests, including against this real machine |

### Deliberately not defended against (scanner)

- **A signed, notarized, never-revoked, novel threat.** Suppression deliberately favours Apple's
  trust signals; this is the accepted cost of the false-positive record.
- **Pre-existing infection at first run.** The trust baseline records what was already installed,
  so anything already present is trusted. It is a false-positive control, not a completeness claim.
- **Kernel or firmware compromise.** Out of scope for an unprivileged userspace scanner.

### Coverage the scanner deliberately does not have

- **Login items (BTM)**: readable only via `sfltool dumpbtm`. The scanner runs **no subprocess in
  the scan path**, which removes an entire class of injection risk from a component whose whole
  job is reading untrusted files. That trade is deliberate, and the gap is stated rather than
  papered over. The `.btm` archive is a private format and is not parsed.
- **Archive interiors**: `.zip`, `.dmg` and `.pkg` files are examined as files, not expanded.
- **Configuration profiles and `periodic` scripts**: declared in the model, not yet enumerated.

### What the scanner does not claim

No real-time protection, no behavioural detection, no machine learning, no cloud reputation, and
no independent test validation. "No known threats found" means exactly that, and the UI reports
definitions age and unreadable locations alongside it rather than saying "you are protected".

## Permissions

Least privilege throughout:

- No entitlements are requested beyond what a normal app has, and no helper is installed. This
  survived the malware work on measured grounds: SIP restricts root, TCC restricts root, and
  `task_for_pid` still fails, so a root helper would add a permanent local privilege-escalation
  target in exchange for very little reach.
- The scanner reads machine-wide locations (`/Library` persistence) but writes nothing there;
  SIP-protected paths are refused with an explanation rather than attempted.
- Networking exists only to fetch threat definitions. Nothing about the user's files is ever
  transmitted: not names, not paths, not hashes, not contents.
- Full Disk Access is **optional**. Sweep detects its absence by probing (macOS offers no query
  API), explains what is affected, and works anyway.
- Per-folder TCC prompts carry purpose strings specific to what Sweep does with that folder.
- `~/Music` and `~/Pictures` were removed from the scan roots specifically because walking them
  triggered a media-library prompt for access the feature does not need.

## Adversarial review

Reviewed and either handled or explicitly accepted above: malicious filesystem structures,
vanishing files, post-classification changes, disappearing permissions, running applications,
unexpected symlink targets, mid-cleanup cancellation, crash during cleanup, unavailable
filesystems, very large filesystems, incorrect scanner metadata, misclassified candidates,
denied access, and simultaneous scans. Privileged-operation and helper-crash scenarios do not
apply: there is no privileged component.
