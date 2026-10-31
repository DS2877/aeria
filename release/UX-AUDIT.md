# Aeria+ — UX audit (2026-10-31)

A feature-by-feature review from a viewer's point of view: code read-through
plus the CI screenshot tour (`Tests/AeriaUITests`). Each finding has a
priority (P1 = hurts every user, P2 = noticeable, P3 = polish) and a status.
Swedish summary for the owner at the bottom.

## Search

| # | Finding | P | Status |
|---|---|---|---|
| S1 | **Channels never appear in results** unless the query says "channel"/"live" — searching "SVT1" finds nothing. (`SQLiteCatalogRepository.search` only adds channels when `kinds` contains `.liveChannel`.) | P1 | Batch 1 |
| S2 | **No live search.** Results only appear after pressing Done on the full-screen keyboard; you type blind. Apple TV apps update results as you type. | P1 | Batch 1 |
| S3 | **Can't search the TV guide.** "Rapport", "Allsvenskan", "Melodifestivalen" — the programmes on air today — return nothing. | P1 | Batch 1 |
| S4 | **Doesn't understand Swedish.** The on-device parser only knows English ("scary", "swedish subtitles"); "skräck med svenska undertexter", "komedi under 2 timmar", "efter 2015" fall through to a literal title match and return nothing. | P1 | Batch 1 |
| S5 | Free text must match as one exact phrase — "thrones game" or "ove man" miss. | P2 | Batch 1 |
| S6 | All results in one mixed poster grid; channels drawn as 2:3 posters with a logo in them. Group by kind: Channels (wide cards with what's on), On TV, Movies, Series. | P2 | Batch 1 |
| S7 | Recent searches are only remembered on Done. | P3 | Batch 1 |

## Home

| # | Finding | P | Status |
|---|---|---|---|
| H1 | Launched with focus in the sidebar → dimmed screen. | P1 | Fixed |
| H2 | Tonight sat above Continue Watching. | P2 | Fixed |
| H3 | No row for **your favourite channels** — the thing an IPTV viewer opens the app for. | P2 | Batch 2 |
| H4 | Live Now / channel cards open a channel *info* page; you then press Play. A TV app should play on click (info via long-press). | P1 | Batch 2 |

## Live TV & Guide

| # | Finding | P | Status |
|---|---|---|---|
| L1 | Clicking a channel opens its info page instead of playing it (same as H4) — two clicks to watch TV. | P1 | Batch 2 |
| L2 | Guide: no way to watch without leaving the guide. | P1 | Fixed (preview + full screen) |
| L3 | While watching live TV, changing channel needs the transport-bar menu; no "channel list" on the remote's swipe-down Info panel. | P2 | Batch 3 |

## Detail screens

| # | Finding | P | Status |
|---|---|---|---|
| D1 | "More Like This": the title sits inside the focusable card, so it's clipped when the card lifts ("he Last Man on Earth"), and the first card is clipped at the left edge. | P2 | Batch 2 |
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
| A1 | **The interface is in English** while the product is Swedish-market only. Every label, button, empty state and error should be in Swedish. | P1 | Batch 4 |
| A2 | Times follow the device region (24 h on a Swedish Apple TV) — correct. | — | OK |

---

## Sammanfattning (svenska)

Allvarligast: sökningen hittar inte kanaler, söker inte i TV-tablån, förstår
inte svenska och visar inget förrän man tryckt Klar. Kanaler kräver två klick
för att börja titta. Appen är på engelska trots svensk marknad. Allt detta
åtgärdas i omgång 1–4; navigering, spelare och hemskärm är redan rättade.
