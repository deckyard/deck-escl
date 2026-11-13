<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# escl cheatsheet

Every export of `@deckyard/escl`. The guide is [Scanning](scanning.md).

```jennifer
import "@deckyard/escl/" as escl;
```

Lengths are in 1/300 inch. Every error the deck raises is kind `"escl"`; a `scanEach` handler's own error keeps its kind (a failed cancel is added to its message). Text from a scanner comes back with control, bidirectional-text and invisible format characters as `?`. A login belongs in `Options`; an address holding `@` is refused.

## Scanners

| Function | Returns | Does |
|---|---|---|
| `escl.discover(timeoutMs as int)` | `list of Found` | scanners answering an mDNS query for `_uscan._tcp` / `_uscans._tcp` within `timeoutMs` (1 to 60000); names with control characters as `?`; stops reading after 2000 records |
| `escl.scanner(address as string)` | `Scanner` | the scanner at `host`, `host:port` or an `http(s)://` URL, default options; the eSCL root defaults to `/eSCL` |
| `escl.scannerWith(address as string, options as Options)` | `Scanner` | the same, with options; zero fields take the defaults |
| `escl.capabilities(s as Scanner)` | `Capabilities` | `GET ScannerCapabilities` |
| `escl.status(s as Scanner)` | `Status` | `GET ScannerStatus` |
| `escl.parseCapabilities(text as string)` | `Capabilities` | parse a saved `ScannerCapabilities` document |
| `escl.parseStatus(text as string)` | `Status` | parse a saved `ScannerStatus` document |

## Settings

| Function | Returns | Does |
|---|---|---|
| `escl.settings()` | `Settings` | the defaults: platen, `RGB24`, 300 dpi, `image/jpeg`, the whole area, no intent |
| `escl.check(caps as Capabilities, st as Settings)` | `Settings` | check every setting against the selected input; fills in a 0 `width` / `height` |
| `escl.settingsXml(caps as Capabilities, st as Settings)` | `string` | the `ScanSettings` document a job sends, after `check` |
| `escl.fromMm(mm as float)` | `int` | millimetres (0 to 10000) to 1/300 inch, rounded |

## Jobs

| Function | Returns | Does |
|---|---|---|
| `escl.scanEach(s as Scanner, st as Settings, handler as func)` | `int` | the whole job, calling `handler(page as Page, n as int)` per page instead of keeping it; returns the page count |
| `escl.scan(s as Scanner, st as Settings)` | `list of Page` | the whole job, in memory; cancels it on failure; no pages, more than `maxPages` / `maxJobBytes` or an aborted job is an error; a finished job is deleted on the scanner |
| `escl.scanToFiles(s as Scanner, st as Settings, dir as string, stem as string)` | `list of string` | the whole job into `<dir>/<stem>-001.<ext>`, ... (more digits when `maxPages` needs them), the extension from the page's type or, failing that, its first bytes; files are created exclusively, never overwritten or written through a link; an error names the files already written |
| `escl.start(s as Scanner, caps as Capabilities, st as Settings)` | `Job` | check the settings and create a job; a feeder job is refused when the feeder reports empty, jammed, open or misfed |
| `escl.nextPage(job as Job)` | `Page` | the next page, or `done` at the end (404); a platen job is done after one counted page, without asking again |
| `escl.countPage(job as Job, p as Page)` | `Job` | the job with the page counted, for a loop of your own; past `maxPages` or `maxJobBytes` is an error |
| `escl.finish(job as Job)` | `null` | after the last page: fails if the status lists the job aborted or cancelled, or it gave no pages (an unreadable status does not fail it), then deletes the job on the scanner |
| `escl.cancel(job as Job)` | `null` | delete the job; one the scanner no longer knows counts as cancelled |
| `escl.imageInfo(job as Job)` | `ImageInfo` | `ScanImageInfo` of the page last fetched, where the scanner offers it |
| `escl.extension(contentType as string)` | `string` | `jpg`, `png`, `pdf`, `tif`, else `bin` |
| `escl.pageExtension(p as Page)` | `string` | the extension from the page's type or, failing that, its first bytes |

## PDF

```jennifer
import "@deckyard/escl/scanpdf.j" as scanpdf;
```

| Function | Returns | Does |
|---|---|---|
| `scanpdf.build(pages as list of escl.Page, resolution as int)` | `bytes` | one PDF of JPEG / PNG pages, each page the size scanned at `resolution` dpi; images embedded unchanged; PNGs with transparency or interlacing refused |
| `scanpdf.scanToPdf(s as escl.Scanner, st as escl.Settings, path as string)` | `int` | scan (format `image/jpeg` or `image/png`) and write one PDF, created exclusively; the name is taken before the scan, and the pages of a failed job, or pages that cannot be bound or written, are kept as `<path without .pdf>-001.<ext>`, ... (`-2-001`, ... when taken); peak memory about seven times the job's size; returns the page count |

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `escl.PLATEN` | `"Platen"` | the flatbed glass |
| `escl.ADJUSTMENTS` | `["Threshold", "Sharpen", "Contrast", "Brightness"]` | the image adjustments, in the order a request sends them |
| `escl.FEEDER` | `"Feeder"` | the automatic document feeder |
| `escl.DEFAULT_TIMEOUT_MS` | `120000` | how long one read may stall |
| `escl.DEFAULT_BUSY_WAIT_MS` | `60000` | how long a 503 is retried |
| `escl.DEFAULT_RETRY_MS` | `1000` | the pause between retries |
| `escl.DEFAULT_MAX_PAGE_BYTES` | `268435456` | the largest page accepted (256 MiB) |
| `escl.DEFAULT_MAX_PAGES` | `500` | the most pages one job may give |
| `escl.DEFAULT_MAX_JOB_BYTES` | `1073741824` | the most bytes one job may give (1 GiB) |

## Types

### `Options`

| Field | Meaning |
|---|---|
| `skipVerify as bool` | accept any HTTPS certificate |
| `caCert as bytes` | a PEM certificate to trust for HTTPS |
| `timeoutMs as int` | how long one read may stall (0 = `DEFAULT_TIMEOUT_MS`) |
| `busyWaitMs as int` | how long to retry a 503 (0 = `DEFAULT_BUSY_WAIT_MS`) |
| `retryMs as int` | the pause between retries (0 = `DEFAULT_RETRY_MS`) |
| `maxPageBytes as int` | the largest page accepted (0 = `DEFAULT_MAX_PAGE_BYTES`) |
| `maxJobBytes as int` | the most bytes one job's pages may add up to (0 = `DEFAULT_MAX_JOB_BYTES`) |
| `deadlineMs as int` | the longest one request may take as a whole (0 = no limit beyond `timeoutMs` per read) |
| `maxPages as int` | the most pages one job may give in any whole-job call (0 = `DEFAULT_MAX_PAGES`) |
| `username as string` | an HTTP Basic login, `""` for none |
| `password as string` | its password |
| `allowPlainAuth as bool` | allow the login over plain `http` or with `skipVerify`; otherwise a login needs `https` with a verified (or `caCert`-pinned) certificate |

### `Scanner`

| Field | Meaning |
|---|---|
| `origin as string` | `scheme://host[:port]` |
| `base as string` | the eSCL root URL |
| `options as Options` | the options, defaults filled in |

### `Capabilities`

| Field | Meaning |
|---|---|
| `version as string` | the eSCL version |
| `makeAndModel as string` | the device's name |
| `serialNumber as string` | `""` if not given |
| `uuid as string` | `""` if not given |
| `adminUri as string` | the device's web page, `""` if not given |
| `iconUri as string` | `""` if not given |
| `inputs as list of Input` | the platen, the feeder, the duplex feeder |
| `feederOptions as list of string` | `AdfOption`s, e.g. `DetectPaperLoaded`, `Duplex` |
| `formatExt as bool` | the device lists `DocumentFormatExt` |
| `adjustments as map of string to Adjustment` | the adjustments offered, keyed by a name in `ADJUSTMENTS` |

### `Input`

| Field | Meaning |
|---|---|
| `source as string` | `PLATEN` or `FEEDER` |
| `duplex as bool` | the feeder's two-sided capabilities |
| `minWidth as int` | 1/300 inch |
| `maxWidth as int` | 1/300 inch |
| `minHeight as int` | 1/300 inch |
| `maxHeight as int` | 1/300 inch |
| `colorModes as list of string` | e.g. `BlackAndWhite1`, `Grayscale8`, `RGB24` |
| `formats as list of string` | MIME types |
| `resolutions as list of int` | discrete dpi with X = Y, ascending |
| `resolutionRanges as list of Range` | the continuous ranges, one per setting profile listing one |
| `intents as list of string` | e.g. `Document`, `Photo` |

### `Adjustment`

| Field | Meaning |
|---|---|
| `min as int` | the lowest value |
| `max as int` | the highest value |
| `normal as int` | the scanner's default |
| `step as int` | the step from `min` |

### `Found`

| Field | Meaning |
|---|---|
| `name as string` | the announced name |
| `host as string` | the mDNS host name |
| `address as string` | the IPv4 address, `""` if not in the answer |
| `port as int` | the eSCL port |
| `secure as bool` | announced as `_uscans` (HTTPS) |
| `root as string` | the eSCL root, from TXT `rs` |
| `model as string` | TXT `ty` |
| `uuid as string` | TXT `UUID` |
| `url as string` | the address to give `escl.scanner` |

### `ImageInfo`

| Field | Meaning |
|---|---|
| `width as int` | pixels |
| `height as int` | pixels |
| `bytesPerLine as int` | bytes per row, 0 if not given |

### `Range`

| Field | Meaning |
|---|---|
| `min as int` | the lowest dpi; 0 when there is no range |
| `max as int` | the highest dpi |
| `step as int` | the step from `min` |

### `Status`

| Field | Meaning |
|---|---|
| `version as string` | the eSCL version |
| `state as string` | `Idle`, `Processing`, `Testing`, `Stopped`, `Down` |
| `adfState as string` | e.g. `ScannerAdfLoaded`, `ScannerAdfEmpty`, `ScannerAdfJam`; `""` if not given |
| `jobs as list of JobInfo` | the jobs the scanner remembers |

### `JobInfo`

| Field | Meaning |
|---|---|
| `uri as string` | the job's path |
| `uuid as string` | `""` if not given |
| `age as int` | seconds since its last change |
| `imagesCompleted as int` | pages scanned |
| `imagesToTransfer as int` | pages not yet fetched |
| `state as string` | `Pending`, `Processing`, `Completed`, `Canceled`, `Aborted` |
| `reasons as list of string` | e.g. `JobCompletedSuccessfully` |

### `Settings`

| Field | Meaning |
|---|---|
| `source as string` | `PLATEN` or `FEEDER` |
| `duplex as bool` | both sides (the feeder only) |
| `colorMode as string` | one of the input's `colorModes` |
| `resolution as int` | dpi, X and Y |
| `format as string` | one of the input's `formats` |
| `intent as string` | one of the input's `intents`, `""` for none |
| `x as int` | left edge |
| `y as int` | top edge |
| `width as int` | 0 = to the maximum |
| `height as int` | 0 = to the maximum |
| `adjust as map of string to int` | adjustments to send, keyed by a name in `ADJUSTMENTS`; unset ones keep the scanner's default |

### `Job`

| Field | Meaning |
|---|---|
| `scanner as Scanner` | the scanner |
| `url as string` | the job's absolute URL |
| `pages as int` | pages fetched, as `scan` counts them |
| `bytes as int` | the bytes those pages hold |
| `platen as bool` | a platen job: `nextPage` ends it after one counted page |

### `Page`

| Field | Meaning |
|---|---|
| `done as bool` | no more pages; the other fields are empty |
| `contentType as string` | the page's MIME type |
| `data as bytes` | the page as sent |
