# Gallery Cleaner

An iOS app that scans your photo library and finds things worth cleaning up. It sorts them into six categories, shows how much space each one takes, and lets you delete what you pick. Deletes go through Photos, so iOS asks you to confirm and the items land in Recently Deleted.

## Categories

- **Screenshots**: images iOS flagged as screenshots when they were taken.
- **Videos**: every video in the library.
- **Large videos**: videos over 100 MB, biggest first.
- **Duplicate photos**: exact copies, confirmed byte for byte, plus the same picture saved again as a different file (for example a re-save from a messaging app). In an exact set, the oldest copy is marked Keep, unless one copy is a synced item the app can't delete, in which case that one is kept. In a re-saved set, the highest-resolution copy is marked Keep.
- **Similar photos**: near-identical shots of the same moment.
- **Duplicate videos**: exact copies, confirmed byte for byte.

## Running it

1. Open `GalleryCleaner.xcodeproj` in Xcode.
2. Pick an iPhone running iOS 17 or later and run it.
3. On first launch the app asks for photo library access. With limited access, it only scans the photos you shared with it.

Use a real device. The simulator's photo library is too small to show much.

## How it works

The first pass reads the library's metadata only, such as type, size, dates and the screenshot flag. Screenshots, Videos and Large videos fill in during this pass, so their counts go up live.

The grouping categories need the complete index, so they run afterwards:

- **Exact copies**: candidates are matched by size first, then confirmed by hashing the whole file. Two files are only called duplicates if every byte matches.
- **Re-saved copies and similar shots**: these are compared with small image signatures, then confirmed with Vision feature prints.

Each step does the cheap filtering first, so the expensive work only runs on a small set of candidates.

File hashes are cached on disk, keyed by asset, modification date and size. A rescan only hashes files that are new or have changed, which is why rescans are faster than the first scan.

None of the scanning or comparison touches the network. The only time the app fetches anything over the network is when you tap the button to load an iCloud preview.

## Performance

On a test library of about 5,000 items on an iPhone 15, the first full scan took about 65 seconds and a rescan about 34 seconds. The home screen stays usable during the scan, and each category can be opened as soon as its results are ready.

## Project layout

- `App`: entry point and `AppConfig`, which holds every threshold and tuning value.
- `Models`: asset records, file fingerprints, categories.
- `Services`: photo access, indexing, metadata reading, the store, hash cache.
- `Detection`: the detectors for each category.
- `Views`: root view, home grid, category screens, viewer, thumbnails.
- `Utilities`: formatters.

All thresholds and tuning values are in `AppConfig.swift`.

## Known limitations

- **Similar photos has a time limit.** It only compares photos taken within 60 seconds of each other, or in the same burst. A similar photo from another day, or a cropped copy, will be missed.
- **Thresholds are estimates.** The similarity thresholds for Similar photos and for re-saved copies were set by estimate. They have not been tuned on a large real library.
- **iCloud-only and shared photos are left out of comparisons.** Photos whose original lives only in iCloud, and photos in shared albums, are skipped by the duplicate and similar checks, because those checks never use the network. They still show up in Screenshots and Videos.
- **Synced items can't be deleted.** Items synced to the phone from a computer through Finder are shown with a lock. iOS doesn't let any app delete them. To remove them, sync again from the computer without them.
- **Some re-saved copies get missed.** If a photo has exact copies, those copies claim it first. A re-saved copy of the same photo can then be missed.
- **Not tested on optimised storage.** I haven't been able to test a library that uses iCloud's Optimize iPhone Storage setting. Expect the comparison categories to find less there.
