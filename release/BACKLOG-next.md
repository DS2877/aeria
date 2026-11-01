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
- `main` = what Xcode Cloud builds → TestFlight. **The user delegated this
  (2026-10-31): advance `main` yourself once the GitHub Actions run for the
  branch is green** — `git push origin <branch-sha>:main` (fast-forward only).
  Don't wait for a local build; the user does zero manual steps and tests via
  TestFlight on the Apple TV. (On the user's Mac, never `git checkout main` —
  it conflicts with the skip-worktree token file.)
- UI language: **English** (owner decision 2026-10-31 — international feel).
  Don't translate the interface; the search parser understands Swedish too.
- Product scope: **Swedish market only** (2026-10-31). Foreign content is
  dropped at import by `RelevanceFilter` / `CatalogWriter`; bump
  `RelevanceFilter.rulesVersion` whenever the rules change.
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

### 1a. Cloud session 2026-10-31 (Claude Code on the web)

Work moved to branch `claude/laughing-sagan-ysfi19` (= `import-progress-checklist`
+ the commits below). To advance `main` after a green build, push **this** branch
instead: `git push origin origin/claude/laughing-sagan-ysfi19:main`.

- Desk-checked every Wave 1 call site against the real APIs (`channels(ids:)`,
  `epgIndex` → `EPGIndex.nowPlaying`, `FavoritesStore.all()`, `Favorite.kind/itemID`,
  `Section(rawValue:)`, test fixtures). Found no compile errors — still unbuilt.
- Wave 1 follow-ups: shared `HomeViewModel.becauseYouWatchedAnchorLimit`;
  Live TV Favorites mode defers the category query (`categoriesStale`);
  copy → "Favorites"; sidebar restore never reopens into Settings.
- Perf #1 done: genre tallies cached per scope in `meta`
  (`MetaKey.genreTally(scope)`, 4 keys, written in `refreshFacetCache`, cleared by
  `clearCatalog`; `genreCounts` falls back to the live query when missing).
  New test `testGenreTallyIsCachedPerScopeAtImportEnd`. Existing libraries get the
  cache on their next import/refresh — no schema bump.

### 1b. CI now builds + tests on every push (no local build needed)

`.github/workflows/build-and-test.yml` runs on a GitHub-hosted Mac (`macos-26`)
for every push to `claude/**` / `import-progress-checklist`: XcodeGen via
`ci_post_clone.sh`, `xcodebuild test` (scheme `Aeria`) on an Apple TV 4K
simulator, then a screenshot pass (scheme `AeriaScreenshots`, UI test
`Tests/AeriaUITests/HomeScreenshotTests.swift`) that launches the demo library
with the DEBUG-only `-AeriaScreenshots` flag (seeds progress + fake ratings) and
uploads Home screenshots as the `home-screenshots` artifact. Read failures with
the GitHub MCP tools (`actions_list` / `get_job_logs`). The user wants to do
**zero** manual steps — use CI as the build gate, not "please build in Xcode".
Simulator-only: device feel (focus, scroll smoothness, real artwork) still
needs the TV.

### 1c. Performance pass (2026-10-31)

- `ImageCache`: the load task used to inherit the actor → all disk reads and
  decodes were serialized. Now `Task.detached`; `DecodeLimiter` caps decodes.
  Disk-size sweep moved off the first image request.
- SQL: leading `(added_at IS NULL)` / `(year IS NULL)` ORDER BY terms removed
  (SQLite sorts NULL lowest; DESC already puts them last) so shelves/browse walk
  the `*_visible_*` indexes instead of sorting the library. Genre shelves use
  `EXISTS`. Sampled `ANALYZE` after each import.
- Home: `makeContent` off the main actor; TMDB rating batches re-shape cached
  inputs (`refreshRatings`) instead of a ~20-query rebuild.
- Launch: `AppEnvironment.startUp()` wires only the TMDB key before `bootstrap`.
- Not done (schema bump needed): Live TV "For you" order still leads with
  `(recent_rank IS NULL)` → full sort per page. Fold recents into a single
  `for_you_rank` column + index when a schema bump is next due.

### 1d. Home redesign (2026-10-31)

Hero 800 pt with slow push-in + first shelf overlapping its fade
(`HeroBanner.shelfOverlap`); Continue Watching = `ResumeCard` (16:9, prefers TMDB
backdrop via `EnrichedArtwork(preferEnriched:)`); Top Rated → ranked Top 10
(`RankedPosterCard`); `HomeRow.style`; snapshot v3.

### 1e. 2026-11-01 batch (all CI-green, on main)
- Detail pages paint at once; hover warm-up (episodes, TMDB, backdrop).
- Grid Menu: deep → top → (category → overview) → sidebar.
- Two-tier guide: get_short_epg now/next for 60 kept channels right after
  channels (`RawStage.guidePreview`), XMLTV parse filtered to kept channels.
- For You sort (default) for Movies/Series (`BrowseSort.forYou`,
  `CatalogDatabase.forYouOrder`, `AppEnvironment.forYouProfile`).
- Category browsing: schema v4 `collection` column (provider section,
  `CategoryMapper.vodCollection`), Collections / Genres / Quick picks tiles.
- Surprise Me: weighted pick from For You top, rating ≥ 6, unseen, poster.
- More Like This: varied pool + `RelatedRanker` (genres, era, cast, rating,
  diversity, dedupe).
- Sidebar order: Search above Home.
- "Drop foreign VOD at import" was already true (CatalogWriter filters).
- Trailers: dropped by the owner.

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
  both now use `becauseYouWatchedAnchorLimit` (done), but the resolution logic
  itself is still duplicated.
- `InMemoryCatalogRepository` intentionally defaults `regionLimited=false` and
  `channelCountries=nil` (tests see the raw catalog); `SQLiteCatalogRepository`
  defaults are the shipping behaviour. Don't assume parity.
- Live TV Favourites: fetched by id, so it **bypasses** `channelCountries` (a
  hearted foreign channel still shows — probably desired, but undecided). It also
  sorts client-side (`.number` = `sortIndex`, `.nameAsc` = name) without the
  home-region tiering of the normal "For you" sort. (Category refetch in
  favourites mode: fixed.)
- Channel-number chip only on Live TV browse. Home "Live Now" `ChannelCard`s don't
  get it (`HomeCard` has no number). `sortIndex == 0` means "no number" and hides
  the chip.
- Sidebar restore can reopen into `.settings`/`.favorites`; `.defaultFocus($focusedItem, .home)`
  still points at Home regardless. Settings is now excluded (falls back to Home);
  check the feel of the rest on device.
- `PosterCard(route:)` refactor (review finding, skipped): `GenreGridView.poster`
  duplicates card construction.
- `GenreGridView` pages movies+series with the same page index (60 movies, 60
  series, 60 movies…) — a merged sort would be tidier.
- Watch progress / favourites JSON-encode the whole list to `UserDefaults` on every
  write — fine now, move to a `user_state` SQLite table if history grows.

## 4. Backlog, prioritised

### Performance
1. ~~`[M]` Precompute Home genre-shelf tallies into `meta`~~ — done (see §1a).
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
