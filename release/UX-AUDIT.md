# Aeria+ — UX audit (2026-10-31)

A feature-by-feature review from a viewer's point of view: code read-through
plus the CI screenshot tour (`Tests/AeriaUITests`). Each finding has a
priority (P1 = hurts every user, P2 = noticeable, P3 = polish) and a status.
Swedish summary for the owner at the bottom.

## Search

| # | Finding | P | Status |
|---|---|---|---|
| S1 | **Channels never appear in results** unless the query says "channel"/"live" — searching "SVT1" finds nothing. (`SQLiteCatalogRepository.search` only adds channels when `kinds` contains `.liveChannel`.) | P1 | Done (CI) |
| S2 | **No live search.** Results only appear after pressing Done on the full-screen keyboard; you type blind. Apple TV apps update results as you type. | P1 | Done (CI) |
| S3 | **Can't search the TV guide.** "Rapport", "Allsvenskan", "Melodifestivalen" — the programmes on air today — return nothing. | P1 | Done (CI) |
| S4 | **Doesn't understand Swedish.** The on-device parser only knows English ("scary", "swedish subtitles"); "skräck med svenska undertexter", "komedi under 2 timmar", "efter 2015" fall through to a literal title match and return nothing. | P1 | Done (CI) |
| S5 | Free text must match as one exact phrase — "thrones game" or "ove man" miss. | P2 | Done (CI) |
| S6 | All results in one mixed poster grid; channels drawn as 2:3 posters with a logo in them. Group by kind: Channels (wide cards with what's on), On TV, Movies, Series. | P2 | Done (CI) |
| S7 | Recent searches are only remembered on Done. | P3 | Done (CI) |

## Home

| # | Finding | P | Status |
|---|---|---|---|
| H1 | Launched with focus in the sidebar → dimmed screen. | P1 | Fixed |
| H2 | Tonight sat above Continue Watching. | P2 | Fixed |
| H3 | No row for **your favourite channels** — the thing an IPTV viewer opens the app for. | P2 | Done (CI) |
| H4 | Live Now / channel cards open a channel *info* page; you then press Play. A TV app should play on click (info via long-press). | P1 | Done (CI) |

## Live TV & Guide

| # | Finding | P | Status |
|---|---|---|---|
| L1 | Clicking a channel opens its info page instead of playing it (same as H4) — two clicks to watch TV. | P1 | Done (CI) |
| L2 | Guide: no way to watch without leaving the guide. | P1 | Fixed (preview + full screen) |
| L3 | While watching live TV, changing channel needs the transport-bar menu; no "channel list" on the remote's swipe-down Info panel. | P2 | Done (CI) |

## Detail screens

| # | Finding | P | Status |
|---|---|---|---|
| D1 | "More Like This": the title sits inside the focusable card, so it's clipped when the card lifts ("he Last Man on Earth"), and the first card is clipped at the left edge. | P2 | Done (CI) |
| D2 | Series: season picker, runtimes, progress and watched marks are good. | — | OK |

## Player

| # | Finding | P | Status |
|---|---|---|---|
| P1 | Next episode closed the player and re-opened it. | P1 | Fixed (Up Next in place) |
| P2 | No playback speed. | P3 | Fixed |
| P3 | Info panel showed only the title. | P3 | Fixed (plot + artwork) |
| P4 | Last seconds of a resume point could be lost when the TV suspends the app. | P2 | Fixed |

## Navigation

| # | Finding | P | Status |
|---|---|---|---|
| N1 | ← into the sidebar landed on the item level with focus and switched screens. | P1 | Fixed |
| N2 | Menu in the sidebar on any section left the app. | P1 | Fixed (goes Home first) |

## Whole app

| # | Finding | P | Status |
|---|---|---|---|
| A1 | Interface language. | — | **Decision: stays English** (international feel). Search still understands Swedish queries. |
| A2 | Times follow the device region (24 h on a Swedish Apple TV) — correct. | — | OK |

---

Status "Done (CI)" = built and unit-tested on GitHub's Mac, screenshots
reviewed where the simulator can show it; not yet tried on a real TV.

### What was built (2026-10-31)
- Search: `.searchable` live search; grouped rows (Kanaler, På TV, Filmer,
  Serier); guide search (`CatalogDatabase.searchProgrammes`, vowel-wildcard
  `LIKE` prefilter + folded Swift match); Swedish parser vocabulary; every-word
  free text; channels for plain text queries.
- Channels play on click everywhere (`.liveChannelPlayer`), long-press for info
  and favourite (`ChannelContextMenu`); Home "Dina kanaler"; Favorites shows
  channel cards; Info-panel "Kanaler" tab while watching live.
- More Like This captions outside the focus lift.
- Swedish UI was built and then reverted at the owner's request — the app
  stays in English; only the search parser speaks Swedish too.

### Next candidates
- Live TV "För dig" order still full-sorts per page (needs schema bump).
- Trailers (TMDB `/videos`) — tvOS can't play YouTube; needs a plan.
- 2-D time grid in the guide as an alternative layout.

## Sammanfattning (svenska)

Allvarligast: sökningen hittar inte kanaler, söker inte i TV-tablån, förstår
inte svenska och visar inget förrän man tryckt Klar. Kanaler kräver två klick
för att börja titta. Appen förblir på engelska (beslut). Övrigt
åtgärdat i omgång 1–3; navigering, spelare och hemskärm är redan rättade.
