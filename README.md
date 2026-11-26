# FileQueue

A native macOS app for copying, moving, renaming, batch-renaming and trashing files, with a queue that understands disks:

- **Jobs on the same disk run one at a time**, in the order you added them.
- **Jobs on different disks run in parallel.**

## Build and run

Requires macOS 14+ and Swift 6 (the Xcode Command Line Tools are enough; full Xcode isn't needed).

```bash
./scripts/build-app.sh        # builds build/FileQueue.app (release, ad-hoc signed)
open build/FileQueue.app
```

```bash
./scripts/test.sh             # runs the test suite (57 tests)
```

`swift run FileQueue` also works for quick iteration, but notifications only work from the `.app` bundle.

## Using it

The window has two panes side by side — **Source** (left) and **Destination** (right) — each with its own sidebar of Favorites and Disks (removable disks have an eject button). Each pane remembers its folder.

1. Browse to a folder in each pane. Double-click opens a folder (or a file in its default app); use ◀ ▶ ↑ or the path menu to move around.
2. Select items and click **Copy →** / **Move →** to send them to the other pane's folder. The arrows flip if you work from the right-hand pane. You can also drag items from one pane to the other (hold ⌥ to move), or drop files from Finder onto a pane.
3. **Rename**, **Batch Rename…**, **Trash** and **New Folder** act on the pane you're working in. **Swap** exchanges the two folders.
4. Watch the **Queue** panel. It shows one lane per disk; a job that uses two disks (e.g. a copy to a USB stick) appears in both lanes with a 🔗 icon. Both panes refresh when a job finishes.

**Thumbnails:** switch any pane between **List** and **Thumbnails** (⌘1 / ⌘2) to review a folder quickly — big previews of photos, video frames, PDFs and documents (via Quick Look), sized with the slider in the pane's footer (⌘+ / ⌘−). Click, ⌘-click and ⇧-click to select, double-click to open, drag to the other pane, right-click for actions, and **Space** (or ⌘Y) for full-size Quick Look. **MKV/WebM** files, which macOS can't preview, get a real frame too: FileQueue reads the container itself and decodes one keyframe with macOS's own decoder (H.264, HEVC, MPEG-2; no extra software). **AVI** files Quick Look can't show get the same treatment: DivX and Simple-Profile XviD (MPEG-4 Part 2) frames are decoded by macOS, and uncompressed/RLE screen captures are drawn as bitmaps (MJPEG AVIs already work through Quick Look). macOS has no decoder for XviD Advanced Simple Profile, GoPro CineForm, DivX 3, Cinepak, MS Video 1 or Indeo, so those keep the icon — unless **ffmpeg** is installed (`brew install ffmpeg`): FileQueue then uses it as a last resort for any video nothing else can preview (XviD, CineForm, WMV, FLV…), at most 3 at a time and with a 20-second limit per file. Settings → Video previews shows whether it was found.

Shortcuts: ⇧⌘C copy / ⇧⌘M move to other pane · ⌘R rename · ⇧⌘R batch rename · ⌘⌫ trash · ⇧⌘N new folder · ⌘[ ⌘] ⌘↑ back / forward / up · ⌘\ switch pane · ⌘U swap · ⇧⌘. hidden files · ⌘Z undo last job.

Copies and moves keep each item's original **modified and created dates** — files, folders at every level, and symlinks.

Every finished job can be undone (⌘Z undoes the most recent one). If a file already exists you get Skip / Keep Both / Replace (with "apply to all"), or you can set a default with the **If exists** menu. Replaced files go to the Trash — nothing is deleted permanently.

## How the disk-aware scheduling works

The rule lives in `Sources/FileQueueCore/Scheduler.swift` as a pure function, and is tested on its own.

- Each job has a set of **disks**: the disks of its sources plus its destination. A copy from the internal disk to a USB stick uses both.
- "Disk" means the physical device (via DiskArbitration), so APFS volumes in the same container share one lane. Network volumes are grouped per volume.
- A job starts only when **all** its disks are free. While it runs (or is paused) it holds them.
- Waiting jobs reserve their disks in queue order, so a later job can never jump ahead of an earlier one on a shared disk. Use ↑/↓ on a waiting job to change the order.
- A global limit (Settings, default 4) caps how many jobs run at once.
- **Parallel anyway** (toolbar checkbox) makes new jobs ignore the disk rule — handy on fast SSDs.

Example:

| Job | From → To | Disks | Result |
|-----|-----------|-------|--------|
| J1 | Macintosh HD → Macintosh HD | HD | starts right away |
| J2 | Macintosh HD → Macintosh HD | HD | waits for J1 |
| J3 | USB-A → USB-A | USB-A | runs in parallel with J1 |
| J4 | USB-B → NAS | USB-B, NAS | runs in parallel with J1 and J3 |
| J5 | USB-A → NAS | USB-A, NAS | waits for J3 **and** J4 |

## Batch rename from photo & video details

Add a **Metadata** rule (or click a suggestion). Names are built from a template of fields:

| Field | Example |
|---|---|
| `{taken:yyyy-MM-dd HH.mm.ss}` — when the photo/video was taken (EXIF / QuickTime) | 2016-05-28 16.08.43 |
| `{created:…}`, `{modified:…}`, `{date:…}` (taken, else created) | 2016-05-28 |
| `{camera}`, `{make}`, `{model}`, `{lens}` | Canon EOS 100D |
| `{resolution}`, `{width}`, `{height}` | 4000x3000 |
| `{duration}`, `{fps}`, `{codec}` | 1m05s, 29.97, H.264 |
| `{iso}`, `{aperture}`, `{focal}` | ISO200, f2.8, 24mm |
| `{title:clean}` — title stored inside a video, made readable | Edge of Tomorrow (2014) |
| `{title}` — that title exactly as stored | RARBG.COM - Edge.of.Tomorrow.2014.1080p… |
| `{type}`, `{ext}`, `{name}`, `{prefix:3}`, `{n:3}` | Photos, jpg, IMG_0001, IMG, 001 |

When files are added, the window first reads the details of **a sample — a few photos/videos from each folder** (up to ~400) — so suggestions and the preview appear within seconds even for huge folders ("details read for a sample of 240"). **Read All Details** reads the rest in the background (with progress, time left and Stop); files not read yet show as "Details not read yet" rather than being misfiled. If the layout or name uses photo details, the main button becomes **Read All & Move / Rename**, which finishes reading first. Layouts that don't need them ({ext}, {type}, name patterns, created/modified dates) work immediately. Everything heavy runs off the main thread, so the window stays responsive. It shows **which details most of them share** (e.g. "Date taken 97%, Camera 95%") plus **suggested names** with an example; one click applies one. Files missing a detail keep their name. "Number duplicates" adds " 2", " 3" for photos taken in the same second.

**Titles inside videos** are read from AVI, MKV/WebM, WMV/ASF and MP4/MOV/M4V/3GP (AVI, MKV and WMV headers are read directly — macOS can't open those — skipping past the video data, so even multi-GB files take milliseconds). This is especially useful for files from recovery tools that lost their names (`file000196.avi` → "The Intern (2015)"). `{title:clean}` removes site tags, dots and release details (`RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip…` → "Edge of Tomorrow (2014)"; TV episodes keep `S01E02`). Blank titles, site adverts ("> VISIT - EXAMPLE.COM <") and timestamps (used as the date taken instead) don't count as titles. Whenever any file has a title, it's suggested as a name; files without one keep theirs.

**Recursive:** with folders selected, "Include files inside folders (and subfolders)" renames every file in the whole tree (counters can restart in each folder).

## Organize into folders

**Organize…** (⌥⌘O) sorts files into folders using the same fields — `/` makes subfolders:
`{taken:yyyy}/{taken:MM}` → 2016/05 · `{taken:yyyy}/{camera}` → 2016/Canon EOS 100D · `{type}` → Photos / Videos · `{ext}`.
To sort by **file names**, enter a pattern such as `^(\w+)-(\d{4})` and use its parts as `{1}`, `{2}` (INV-2015-001 → INV/2015).

Suggestions come from the same scan. Files missing a detail go to a fallback folder ("Unsorted").

**Rename files while organizing (optional):** "Rename files to" gives files a new name as they're moved — e.g. **Use Title Inside the File** (`{title:clean}`) turns `file000070.avi` into `Edge of Tomorrow (2014).avi`. The extension is kept; files without the detail keep their names; same names get " 2", " 3". (Titles aren't offered for the folder layout, where they'd make a folder per file.) With the layout **Only Split into Numbered Folders** (`.`) files stay where they are and are just renamed.

**Group by range:** files can be sorted into ranges instead of exact values — `{size|100MB,1GB}` → "Under 100 MB", "100 MB – 1 GB", "1 GB or more"; `{duration|30m}` → "Under 30 min", "30 min or longer"; `{res|720p,1080p}` → "Under 720p", "720p – 1080p", "1080p or higher"; `{fps|30,60}`; and `{quality}` → SD, 720p, 1080p, 1440p, 4K. Use any limits (`{duration|10m,30m,1h}`, `{res|1080p,4k}`) and combine levels (`{quality}/{duration|30m}`). Resolution is judged the way videos are labelled, so a 1920×800 widescreen movie counts as 1080p. The **Group by range** helper in the Organize window builds these and shows the folder names first.

**Big folders:** no folder gets more than **4,096 files** (changeable in the window; 0 = no limit), because folders with a huge number of files are slow to open. A folder that would go over — counting files already in it — gets numbered subfolders `001`, `002`, `003`… instead, and existing numbered subfolders are filled up before new ones are made. To fix a folder that's already too big (e.g. an old "Unsorted"), select it, choose **Organize…** and **Only Split into Numbered Folders**. Choose **move or copy**, into the same folder or the **other pane's folder**, and preview every file's destination first. It runs as a normal queued job (disk lanes, merge, skip-on-error, **Undo** — which also removes folders it created). After a move, folders left empty are removed.

### Remove empty folders

Organize › Remove Empty Folders… (⌥⌘E, also in the toolbar's Organize menu and the pane's right-click menu) lists every empty folder under the selected folder. A folder counts as empty if it holds nothing, only system clutter (`.DS_Store`, `Thumbs.db`, `desktop.ini`, `._` files), or only empty folders; only the outermost one of each empty tree is listed. Hidden folders, packages and symlinks are left alone. Untick any you want to keep. The ticked ones are checked again, then moved to the Trash through the queue, so Undo puts them back.

## Disk map

**Disk Map** (⌥⌘M, or right-click → Show Disk Map) shows a folder as a treemap: every item is a block sized by the space it really uses on disk (hidden files included), coloured by kind (photos, videos, audio, documents, archives, apps, folders). Hover for details, click to select, double-click a folder to zoom in; the path bar goes back up. The side list ranks the largest items; selected items can be revealed in a pane, shown in Finder, or moved to the Trash (through the queue, undoable). Disks mounted inside the folder aren't counted; very large folders group their smallest items into one block.

## When things are already there (Merge)

**Merge** is the default for "If exists". Copying or moving a folder that already exists at the destination fills it in rather than duplicating or replacing it:

- Missing files and subfolders are copied.
- Files already there are left alone — "already there" means the same size and either the same modified date or, if the dates differ, the same bytes. (Some disks can't store dates exactly; e.g. exFAT is a day off for dates after 2100.) With **Verify with checksums** on, the bytes are always compared.
- Files with the same name but different content (e.g. a half-finished copy from earlier) are asked about: Skip, Replace (old one to the Trash) or Keep Both, with "apply to all".
- `.DS_Store` and exFAT `._` metadata files are never asked about.
- For moves, each original is removed only once its copy is confirmed or an identical file is already there (identical originals go to the Trash, so Undo can bring them back). Anything you skipped stays in the source folder.

So re-running an interrupted copy only copies what didn't make it. A single file that's already there identically is skipped too (except with **Keep Both**).

**Merge, Keep Both if Different** works the same way but never asks. Each file with the same name gets a quick content check that ignores dates. The sizes must match. Then the bytes are compared: all of them for files up to 1.5 MB, or for bigger files the first and last 256 KB plus 16 evenly spaced 64 KB samples, so even large videos take a moment. If they match, the file counts as already there. If they differ, both are kept and the incoming one gets a new name (`b 2.jpg`). With **Verify with checksums** on, every byte is compared instead. The job's notes count how many files were kept both.

## Duplicates

**Find Duplicates…** (⌥⌘D, the toolbar's **Duplicates** button, or right-click a folder) looks for files with the same contents in a folder and its subfolders. It works on the selected folder, or else the current one. Only same-sized files are ever read, so it's quick. Files up to 1.5 MB are compared byte for byte. Bigger ones are compared on samples and marked **Very likely identical** until they're checked in full. Options:

- Include or skip subfolders and hidden files.
- Ignore files under a size (1 KB by default).
- Compare every byte from the start.

The results start with a summary: how many sets, how many extra copies, and how much space they take. Then each set gets a row with thumbnails of every copy, showing its folder and date. One copy per set is marked **Keep**: the one whose name doesn't look like a copy (`name 2`, `name (1)`, `name copy`), or the oldest, the newest, or the one nearest the top folder. Click a picture to keep it as well, ⌥-click to keep only it, or choose **Keep All** to leave a set alone. Then:

- **Check Every Byte** confirms the sampled matches. A set can split up or disappear if its files turn out to differ.
- **Trash Extra Copies** checks every byte first, then moves only exact copies of a kept file to the Trash through the queue, so **Undo** brings them back.

## When an item can't be read or written

If one file or folder fails (a damaged file, an unreadable folder on a failing disk, a permission problem), the job doesn't just die. You choose:

- **Skip & Continue** — leave that item out and carry on with the rest.
- **Stop This Job** — end this job; other jobs in the queue continue.
- **Stop All** — end this job and put the rest of the queue on hold (resume it when you're ready).

Tick "Do the same for other errors in this job" to answer once. Settings has a default (Ask / Skip it and continue / Stop the job). A job that finished with skipped items shows them under **Needs attention**; **Retry** then fetches only what's missing (thanks to Merge). Disk read errors get a hint (e.g. run `chkdsk /f` on Windows for an NTFS drive).

Folders are copied item by item for this reason, so one bad file doesn't sink the folder, and an interrupted folder copy can be completed later by merging.

## Safety rules

- A new job that clashes with one still in the queue is stopped before it's added — e.g. organizing `jpg/Group 1` while an "Organize jpg" job (which includes Group 1) is waiting, or moving files a queued copy still needs. The message names the other job; **Add Anyway** is there if you mean it.

- Nothing is deleted permanently. Replacing and trashing move items to the Trash.
- A cross-disk move deletes the source only after the copy is verified (size by default, SHA-256 if enabled in Settings).
- Each item is copied under a hidden temporary name (`.<name>.<job>.fqpart`) and renamed only when complete, so an interrupted copy never looks finished. A restarted job cleans up its own leftover; cancelling or a failure removes it.
- Jobs that would have to change a **read-only disk** are refused before anything is copied — e.g. moving off an NTFS drive (macOS can read NTFS but not write it). Copying off it still works. Read-only disks show a 🔒 in the sidebar and the impossible actions are disabled.
- Works on exFAT/FAT/network disks that don't support no-overwrite renames: the app checks the name is free, then renames.
- Batch rename is all-or-nothing: swaps and cycles go through temporary names, and any failure puts every name back.
- Undo checks each file's identity (inode + modified date) and skips files that changed since.
- After a crash or quit, running jobs come back as **Interrupted** and queued jobs as **On hold**; nothing restarts on its own. An unreadable queue file is moved aside, not overwritten.

## Layout

```
Sources/FileQueueCore/     all logic, no UI (tested)
  Scheduler.swift          the disk rule
  QueueEngine.swift        actor: job list, start/pause/cancel/retry/undo, persistence
  FileOperationExecutor    copy/move/rename/batch rename/trash/undo
  Copier.swift             copyfile(3) with progress, pause and cancel; APFS clones
  RenameEngine.swift       rename rules + collision checking (pure)
  DiskResolver.swift       URL → physical disk
Sources/FileQueue/         SwiftUI app
Tests/FileQueueCoreTests/  scheduler, engine, executor, rename and real-disk-image tests
```

## Notes

- The Command Line Tools SDK defines SwiftUI's `@State` as a macro whose plugin only ships with Xcode, so the app uses `@ViewState` (an alias for the same property wrapper — see `ViewState.swift`). It works with full Xcode too.
- The real-disk tests attach small disk images with `hdiutil`; they're skipped where that isn't available.
- Not sandboxed (Developer ID-style). File access goes through the executor and disk resolver, so adding security-scoped bookmarks for a Mac App Store build is contained to those pieces.
