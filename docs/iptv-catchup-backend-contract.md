# Catch Up (TV Archive) — backend findings

Corrected after reading `voltixstudio/server/iptvProxy.ts` directly. An
earlier version of this file assumed endpoints were missing; most already
exist. What follows is what is actually there.

## Already implemented — no backend work needed

| Need | Where |
|---|---|
| `tv_archive` → `hasArchive` | `/api/iptv/content`, iptvProxy.ts:4329 — also emits `archiveDurationHours` |
| `get_simple_data_table` | `/api/iptv/epg/simple`, iptvProxy.ts:4636 (fallback branch) |
| Base64 title/description decode | same handler, iptvProxy.ts:~4655 |
| Timeshift URL construction | **`/api/iptv/replay-url`**, iptvProxy.ts:4937 |
| Virtual "DSTV - South Africa" folder | `/api/iptv/categories`, id `dstv-za`, iptvProxy.ts:3708 |

`/api/iptv/replay-url?streamId=&start=&durationMinutes=&containerExtension=ts`
returns `{ "url": "..." }`. The client now calls this instead of building a
URL itself.

## Real gap 1 — `has_archive` is dropped per programme

`/api/iptv/epg/simple` maps the reseller's `epg_listings` at iptvProxy.ts:4652
but does not carry `has_archive` through. Xtream reports it **per programme**,
not just per channel, so the client cannot tell which past programmes are
actually replayable and will offer some that fail.

Fix: add `hasArchive: String(entry.has_archive ?? "0") === "1"` to that mapped
object. The client already tolerates the field being absent.

## Real gap 2 — the guide prefers XMLTV, which may hide past programmes

Same handler, iptvProxy.ts:4622: it uses the XMLTV fallback guide whenever
that has any listing ending in the future, and only falls through to the
reseller's `get_simple_data_table` otherwise. Catch-up needs *past*
programmes, so on channels where XMLTV wins, the archive listing is whatever
XMLTV happens to hold rather than the provider's actual archive.

Fix: either have catch-up call the reseller branch explicitly (e.g. a
`source=archive` query flag), or merge both.

## Suspected cause of the short channel count (35 vs ~164)

`/api/iptv/content` filters live channels by the account's IPTV package
(iptvProxy.ts:2420 `PACKAGE_ALLOWED_QUALITIES`, applied ~4150).

`detectQuality()` reads the tier from the channel *name*: `4K`/`UHD` → 4k,
`FHD`/`FULL HD` → fhd, word-boundary `HD` → hd, **everything else → sd**.

An exact-tier package (`hd`, `fhd`, `sd`, `uhd`) therefore returns only
channels whose name carries that marker. A reference app talking straight to
the provider applies no such filter, which is why it sees the full set.

This is entitlement behaviour, not a bug — but it means the count difference
may be configuration, not code. To confirm: the handler logs
`[IPTV Proxy] Quality filter active — package: ...` whenever it is filtering.
If that line is absent from the server log, quality filtering is not the
cause. If present, check the account's package in the Admin portal.

Product question worth settling: should catch-up be quality-tiered at all?
