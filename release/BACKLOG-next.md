# Aeria+ — forward backlog (written for Claude Code, not for humans)

Read this first when picking up work. It supersedes §5 of
`release/SPRINT-2026-09-features.md` (which is partly stale) and records what is
verified vs. not. The user is **not a developer**, develops on Windows, builds
only on a Mac, and cannot compile here — so every change is blind until they
build. Prefer small, additive, self-contained commits.

## 0. Standing rules (do not violate)

- Hand-offs to the user = exact Terminal + Xcode steps, never "rebuild" shorthand.
- Do NOT touch `SWIFT_VERSION` in `project.yml`. Keep `NSAllowsArbitraryLoads: true`.
- Bundle id `com.aeriaplus.appletv` is permanent.
- `Sources/App/TMDBDefaults.swift` stays committed with `readAccessToken = ""`; the
  user has `skip-worktree` on it locally with the real token. Never commit it.
- Never commit any password or token. (A specific old Mac password is on the
  user's blocklist in the Claude memory files — do not write it into the repo.)
- IPTV credentials / API keys: Keychain only, never logged, never committed.
- `main` = what Xcode Cloud builds. Only advance it after the user confirms a
  green local build: `git push origin origin/import-progress-checklist:main`
  (do not `git checkout main` — it conflicts with the skip-worktree token file).
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Multi-profile is permanently out of scope.
- Nested `struct Body: View` inside a `ButtonStyle` breaks compilation (collides
  with the associatedtype). Hoist helper views to top level.

## 1. State at time of writing (2026-10-31)

- v1.0 was submitted to App Store review (expect IPTV 4.2/5.x scrutiny; drafted
  replies in `docs/app-store-listing.md` / `release/SUBMIT.md`).
- `origin/main` = `f13c966` (CI fixes + unique build numbers). Xcode Cloud
  workflow works: `ci_scripts/ci_post_clone.sh` (xcodegen + seeds
  `ci_scripts/Package.resolved`), `ci_scripts/ci_pre_xcodebuild.sh` (stamps
  `CFBundleVersion` from `CI_BUILD_NUMBER`).
  - If the VLCKitSPM version in `project.yml` ever changes, regenerate
    `ci_scripts/Package.resolved` (copy from
    `Aeria.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).
- `origin/import-progress-checklist` = `4078494`, ahead of main by the "Wave 1"
  commits below. **None of Wave 1 has been confirmed built or run.**
  - `7771fa5` channel-number chip (`ChannelNumberBadge`) + Live TV "★ Favourites" filter
  - `f7f7182` sidebar remembers last section (`UserDefaults` key
    `sidebar.lastSection.v1`, restored in `SidebarShell.init()`)
  - `4078494` "Because You Watched" up to 2 anchors (`mostRecentWatchedAnchors`,
    `watchedAnchors`; new test `testMakeContentProducesUpToTwoBecauseYouWatchedRows`)

## 2. Unverified on device — verify before building on top of it

Ask the user to run the build, `⌘U`, and report. Likely compile-risk spots listed
first because none of it has seen a compiler:

1. Wave 1 files: `ChannelCard.swift`, `QualityBadge.swift`, `LiveTVBrowseView.swift`
   (new `favorites:` init param, `loadFavorites`), `SectionModels.swift`,
   `SidebarShell.swift` (custom `init()` with `State(initialValue:)`),
   `HomeViewModel.swift`.
2. Earlier unbuilt batch (`e8a1f0d`, `ed33e5c`, `cc24c30`): `ChannelRegionScope`,
   `CatalogDatabase.appendChannelCountry` + `guideChannels` rewrite, browse
   header restructure (header outside `ScrollView`, `zIndex(1)`), `seriesShells`.
3. Behaviour to eyeball on the Apple TV:
   - Browse header stays fixed and content scrolls *under* it (Movies, Series,
     Live TV, Guide) — `.scrollClipDisabled()` is why `zIndex(1)` was needed.
   - Sidebar: rail expansion scales/shifts/dims content; d-pad focus containment of
     the keep-alive `ZStack` (`.disabled` + `.opacity(0)` on inactive sections) is
     a known uncertainty. Menu on a section root returns focus to the rail; Menu on
     Home must background the app.
   - Sweden-first channels: default `ChannelRegionScope.homeCountry` shows only
     `country_code IN ('SE')` or NULL. If the provider tags Swedish channels with
     another code, they vanish — user can widen in Personalize → Live TV channels.
   - **Home load time is not diagnosed.** Fixes so far: no extra
     `catalogRevision` bump on warm launch (`applyPreferences(bumpRevision:)`),
     `seriesShells` instead of full trees. Timing logs exist in
     `HomeViewModel.performRebuild` ("Home fast pass painted in N ms", "Home full
     pass in N ms · rows · MB headroom", Console.app, subsystem
     `com.aeriaplus.appletv`, category `app`). Get those numbers before optimising
     further. First launch after any schema bump = one full re-import (expected).

## 3. Known design smells / tech debt introduced or noticed

- **Two parallel anchor-resolution paths for "Because You Watched"**:
  `HomeViewModel.watchedAnchors` (actor side, decides which DB rows to prefetch)
  and `mostRecentWatchedAnchors` (pure, inside `makeContent`). They can drift;
  both hard-code `limit: 2` — introduce one shared constant.
- `InMemoryCatalogRepository` intentionally defaults `regionLimited=false` and
  `channelCountries=nil` (tests see the raw catalog); `SQLiteCatalogRepository`
  defaults are the shipping behaviour. Don't assume parity.
- Live TV Favourites: fetched by id, so it **bypasses** `channelCountries` (a
  hearted foreign channel still shows — probably desired, but undecided). It also
  sorts client-side (`.number` = `sortIndex`, `.nameAsc` = name) without the
  home-region tiering of the normal "For you" sort. `scheduleReload()` still
  refetches categories needlessly while favourites mode is on.
- Copy inconsistency: chip says "★ Favourites" (British); sidebar/Settings say
  "Favorites". Pick one (app is en-US in ASC → "Favorites").
- Channel-number chip only on Live TV browse. Home "Live Now" `ChannelCard`s don't
  get it (`HomeCard` has no number). `sortIndex == 0` means "no number" and hides
  the chip.
- Sidebar restore can reopen into `.settings`/`.favorites`; `.defaultFocus($focusedItem, .home)`
  still points at Home regardless. Check feel on device; may want to exclude Settings.
- `PosterCard(route:)` refactor (review finding, skipped): `GenreGridView.poster`
  duplicates card construction.
- `GenreGridView` pages movies+series with the same page index (60 movies, 60
  series, 60 movies…) — a merged sort would be tidier.
- `Theme.swift` — `pinnedHeaderStyle()` was removed; make sure nothing references it.
- Watch progress / favourites JSON-encode the whole list to `UserDefaults` on every
  write — fine now, move to a `user_state` SQLite table if history grows.

## 4. Backlog, prioritised

### Performance
1. `[M]` Precompute Home genre-shelf tallies into `meta` (like the facet cache);
   `genreCounts` is a double `GROUP BY` join on every full Home rebuild.
2. `[M]` **Drop foreign VOD rows at import** instead of flagging `is_relevant=0`
   (smaller DB/indexes). Cost: "show all regions" needs a re-import. Decide with
   the user first — Sweden-first now makes the trade more defensible; live channels
   already use query-time scoping and should stay that way.
3. `[S]` `artworkSeeds` ordering `(added_at IS NULL), added_at DESC` defeats the
   `movie_added_at` index — partial index or `recent_rank` column.
4. `[M]` Cold-import fast path (`journal_mode=OFF` + one transaction for the
   initial import, WAL afterwards).
5. `[M]` Home rebuild frequency: it re-shapes on progress, metadata revision,
   prefs, catalog revision, refresh-finished, favourites — patch rows in place
   where possible. Expect one extra rebuild ~4 s after launch when TMDB ratings land.
6. `[S]` `CatalogDatabase` scale test (50k rows, region-scoped) so index
   regressions fail CI. Current perf tests use the in-memory repo only.
7. `[S]` Sequential `await`s in the Home full pass (~20 queries) serialize on the
   single reader connection — parallelising won't help; reduce query count instead.

### Features
1. `[M]` "For You" VOD sort (preferred languages + watched genres) as the default
   for Movies/Series.
2. `[M]` Playback speed — `AVPlayerViewController.speeds` (tvOS 16+) native; VLC
   `player.rate`.
3. `[L]` 2-D Guide grid (time × channel).
4. `[M]` In-player "Next Episode" (deferred earlier as transport surgery).
5. `[M]` Trailer via TMDB `/videos` — tvOS can't play YouTube directly; needs a plan.
6. `[S]` Search "trending" ranked by real TMDB rating.
7. `[S]` Empty states that offer "Switch to the Demo Library".
8. `[S]` Swedish UI localisation (the product is now Swedish-first; strings are
   currently English only). Larger than it looks — audit all literals.
9. `[M]` Top Shelf extension was never confirmed on device — verify Continue
   Watching row + deep link (`aeria://movie/<id>`).

### UX / polish
- Genre-shelf "See all" header is an extra focus stop; if annoying, gate behind
  long-press.
- `SeeAllLinkStyle` only tints on focus; consider underline.
- Sleep timer uses a `UIMenu` in `transportBarCustomMenuItems`; if it doesn't
  render as a submenu on device, fall back to flat `UIAction`s (30 / 60 / Off).
- Series detail redesign (wide season picker, 320×180 episode rows,
  `contentMaxWidth: 1600`) — confirm it actually fills the screen on a real TV.

### Correctness / hardening
- `RelevanceFilter`: a UK/US channel with a risky word and no country code/English
  track can still be dropped; note any real misses the user reports.
- `foreignMarkers` were pruned of ambiguous nouns; re-check false negatives after
  real-world feedback.
- Keychain/credential logging audit when touching provider code (`AppLog.redacting`).

### App Store / ops
- If Apple rejects (4.2 IPTV, 2.1 couldn't test, 5.x ATS): use drafted replies;
  "Try the demo" path must remain reachable without credentials.
- Every upload needs a unique build number — now automatic via
  `ci_pre_xcodebuild.sh`; local archives use `CURRENT_PROJECT_VERSION` (currently 3,
  keep it ahead of anything uploaded).
- Xcode Cloud workflow must have an Archive action with TestFlight deployment;
  a green build without it never shows up in "Add Build".
- Marketing version is `1.0`; bump `MARKETING_VERSION` in `project.yml` for the
  first update, and update "What's New" in `release/app-store-listing.md`.

## 5. Suggested next session plan

1. Get the user's result for the Wave 1 build (errors / `⌘U` / device notes).
2. Fix whatever broke; then advance `main` only after confirmed green.
3. Collect the Home timing log numbers; only then decide on Home perf work.
4. Wave 2: genre-tally cache → "For You" sort → playback speed.
5. Revisit "drop foreign VOD rows at import" with the user as its own decision.
