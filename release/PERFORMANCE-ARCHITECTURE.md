# Loading & speed — architecture options (2026-10-31)

## Where the time goes today

Fast already: Home paints a disk snapshot on the first frame; browse/search/
detail read a local SQLite store; images come from a downsampled disk + memory
cache (parallel decode since 2026-10-31).

Slow — all of it is the provider import (`XtreamProviderClient.fetchStaged`):

1. **The whole provider catalogue is downloaded, then mostly thrown away.**
   `get_live_streams` / `get_vod_streams` / `get_series` return every region;
   the Swedish-market filter (`RelevanceFilter`, `CatalogWriter`) runs *after*
   download + decode. A big provider's VOD JSON is ~100 MB decoded.
2. **The EPG is one giant XMLTV file** (`xmltv.php`, often 50–300 MB) for every
   channel on the provider, streamed to disk and parsed, each refresh.
3. **Everything refreshes every 6 h** (`AppEnvironment.staleAfter`), though VOD
   and series rarely change.
4. Series episodes load on first open (`get_series_info`), then cached — minor.

No device timings yet: `HomeViewModel.performRebuild` logs them (Console,
subsystem `com.aeriaplus.appletv`), but only the TV can read them.

## Options

| | Approach | Speed | Cost / risk |
|---|---|---|---|
| **A** | **Smarter on-device import** (recommended) | Much faster first launch + refresh | Work in the import path; fallback needed for providers without per-category endpoints |
| B | Lazy / on-demand per category (typical simple IPTV app) | Fastest first launch | Breaks search, Home curation, Top 10 — they need the whole catalogue |
| C | Own backend pre-processing catalogues | Fastest overall | User's IPTV credentials would pass through our server: privacy, App Review (positioned as "player only"), running cost, legal exposure |
| D | Tune the current pipeline only | Small | Doesn't touch the big downloads |

## Recommendation: A, in three steps

1. **Category-first import.** Fetch `get_live_categories` / `get_vod_categories`
   / `get_series_categories` (small), drop foreign-market sections with
   `RelevanceFilter.isForeignSection`, then fetch streams per kept category
   (`&category_id=`). Cuts download/decode/memory roughly by the share of
   foreign content. Fall back to the bulk endpoints when per-category calls
   fail or return nothing.
2. **Two-tier EPG.** Now/next for visible channels via `get_short_epg`
   immediately; the full XMLTV in the background, less often, keeping only
   kept channels' `channel` ids during the stream parse.
3. **Staggered refresh.** Channels every 6 h, EPG every 12 h, VOD/series every
   24 h; "Refresh library" in Settings still refreshes everything at once.

Everything stays on the TV; credentials still go only to the provider.
