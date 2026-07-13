Photo pipeline: turns phone screenshots of the official WH40K app into the
repo's unit photos. Run order (see each script's header):
  1. scan_screenshots.ps1   OCR + photo-band detection -> manifest.csv
  2. rematch.ps1 / rematch2.ps1   fuzzy-match OCR damage against unit lists
  3. (review manifest.csv, fix leftovers by eye)
  4. organize_photos.ps1    crop into faction folders + covers
  5. fix_crops.ps1          re-crop any that swallowed UI (white pages)
  6. rewire_repo.ps1        copy into WH40K/Images/Units + rebuild mappings
  7. compact_and_embed.ps1  re-embed the map into thestrategium.html
Then: git push, re-run Build-Obsidian.ps1, refresh Supabase unit_images.
manifest.csv is the 2026-07-12 run (625 screenshots -> 584 units, 36 covers).
