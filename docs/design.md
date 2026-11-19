<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

A client for eSCL, the driverless scan protocol behind AirScan (AirPrint
scanning) and Mopria Scan: XML documents and image data over HTTP or HTTPS.
It finds scanners by mDNS, reads their capabilities and status, checks
settings against them, runs scan jobs page by page, and writes the pages as
files or binds them into one PDF.

Two modules:

- `escl`: discovery, capabilities, status, settings, jobs, pages and files.
- `scanpdf`: binds JPEG and PNG pages into a PDF without decoding them. It is
  separate so that a program that only scans does not load the bundled
  `pdf.j`.

Out of scope:

- Image processing. Pages are passed on as the scanner sent them; PNGs that
  would need decoding to embed (transparency, interlacing) are refused by
  `scanpdf` rather than converted.
- Adjustments other than brightness, contrast, sharpen and threshold.
  Blank-page removal, compression and gamma are left out because their
  element names are not confirmed by a source.
- Push scanning (scan-to-computer started at the device) and the WS-Scan
  protocol.

## Decisions

- **Elements are matched by local name**, not by namespace. Devices differ
  in prefixes and in their default namespace, and the content is the same.
- **Only the path of a job's `Location` is kept.** Scanners name themselves
  in absolute URLs by hosts the client often cannot resolve (an mDNS
  `.local.` name), so the job URL is rebuilt on the address the client used.
- **Strict.** Every setting is checked against the selected input before a
  request is sent (`check`): source, colour mode, resolution, format, area
  and adjustments. Zero pages, and a job the scanner lists as aborted or
  cancelled, are errors. A feeder job checks the feeder state first and
  reports a jam or an empty tray by name.
- **Busy is retried, nothing else is.** A 503 (busy, warming up, page not
  ready) is retried on every GET and on job creation for up to `busyWaitMs`,
  pausing `retryMs` or the scanner's `Retry-After`. A 409 on job creation is
  not retried, and `DELETE` never is.
- **A failed job is cancelled.** `scan`, `scanEach` and `scanToFiles` cancel
  the job on any failure; a failed cancel is appended to the original error,
  never replaces it.
- **A platen job has one page.** `nextPage` ends a platen job after one
  counted page without asking the scanner for another.
- **`Host` names the port.** Requests always send `Host: host:port`; some
  scanners refuse a Host without the port.
- **Files are written fresh.** Each page goes out with one `fs.writeNew`,
  which refuses an existing file or a planted link and leaves no partial
  file. `scanToPdf` claims the PDF's name before scanning, releases the claim
  only while it is still an empty regular file, and keeps the raw pages next
  to it when binding or writing fails, so a long scan is never lost.
- **Discovery uses legacy unicast.** `discover` sends one PTR query for
  `_uscan._tcp` and `_uscans._tcp` with the unicast-response bit from an
  ephemeral port. Responders answer by unicast, so no multicast group join is
  needed.
- **`scanpdf` builds the document in place.** It appends images and pages to
  the document directly instead of through `pdf.addImage` and `addPage`,
  which copy the document on each call.
- **`ImageInfo` names come from the Mopria specification**; the adjustment
  names follow what sane-airscan reads and sends.

## Errors

Every error of kind `"escl"` is an `EsclError{kind, message, status,
retryAfterMs}`:

- `status`: the HTTP status the scanner answered (401, 409, 503, ...), 0 when
  the failure is not a refused request.
- `retryAfterMs`: the reply's `Retry-After` in ms when it gave one in
  seconds, else -1.

A reached cap is kind `"limit"`: the element, text and item caps of the XML
reader, `maxPages`, `maxJobBytes`, a body over its cap, and the PNG chunk and
JPEG segment caps in `scanpdf`, and a cap the `pdf` module reports while
`scanpdf` binds or renders the pages (with the page in front of its message).
A `"timeout"`, `"closed"` or `"cancelled"` from `pdf` goes on unchanged; only
its own `"pdf"` errors become `"escl"`. Malformed mDNS names stay `"escl"`.

A network failure (refused, reset, unreachable, DNS, TLS) is the
`net.NetError` (kind `"net"`) that `net` threw, with its `op`, `reason`,
`sent` and `replied`. When a job fails that way, what the deck adds (a cancel
that failed too, the pages written or kept) is appended to its message and
its fields are kept. The deck does not retry it. A read that stalls past
`timeoutMs`, or a request past `deadlineMs`, is kind `"timeout"`; a
connection closed mid-reply `"closed"`; a cancelled task `"cancelled"`. Any
other failure of a request is an `EsclError` with status 0 and the cause in
its message. A scanner that still answers 503 when `busyWaitMs` runs out is
an `EsclError` with status 503 and its `Retry-After`, not a timeout: it
answered.

`scanpdf` rethrows an `EsclError` by rebuilding it from its fields, so it
works on interpreters where a caught struct from another module loses its
identity (fixed in M28.56).

## Security and limits

Scanners are network devices with long-lived firmware; their replies are
treated as untrusted.

- XML documents are capped at 1 MiB, 10,000 elements, 256 items per list and
  1024 characters per text, and a document with more than twice the element
  cap in `<` characters is refused before parsing: a 4 MB flood of empty
  elements cost about 1 GB in the XML decoder.
- Pages: `DEFAULT_MAX_PAGE_BYTES` (256 MiB) per page, `DEFAULT_MAX_PAGES`
  (500) and `DEFAULT_MAX_JOB_BYTES` (1 GiB) per job. `deadlineMs` bounds a
  whole request when a scanner sends a byte at a time; otherwise only the
  per-read `timeoutMs` (`DEFAULT_TIMEOUT_MS`, 2 min) applies.
- mDNS answers are parsed with bounds checks, a limit of 16 compression
  jumps, 255-byte names, at most 2000 records and 512 name labels per answer;
  a bad packet is skipped.
- Scan-area checks subtract instead of add, so caller values cannot
  overflow.
- Device text in error messages is clipped to 80 characters with control
  and invisible formatting characters shown as `?`.
- A login (HTTP Basic) is sent only over HTTPS with a verified certificate,
  unless `allowPlainAuth` is set. Most scanners have a self-signed
  certificate: pin it with `caCert` rather than `skipVerify`.

## Testing and validation

- The overlays run whole jobs against an `httpd` fake scanner on loopback,
  which answers one canned reply per request and fails when a reply was
  never asked for, so a broken flow fails instead of hanging. Discovery is
  tested against a loopback UDP responder.
- The fixtures imitate an HP LaserJet M28 (platen) and an Epson ES-C380W
  (feeder, duplex, default namespace). They were written from documentation
  and sane-airscan's notes, not captured from devices.
- Memory: a page costs about six times its size transiently inside `http`
  (a 64 MiB page about 450 MB); `scanToPdf` peaks at about 6.7 times the job
  (72 MB of JPEG, 486 MB resident), mostly in `pdf`'s rendering.
- Not tested against a real scanner.

## Known limitations and open questions

- Fixtures should be replaced with captures from real devices.
- Pages are held in memory; streaming them to disk waits for streaming
  responses in `http` (M30.9).
- Only four adjustments are offered.

## Dependencies on the interpreter

Floor `>=0.26.0`, capability `net`. It relies on changes on `jennifer`'s
main branch that ship with 0.26.0: `convert.bytesFromString` and
`stringFromBytes` taking the codec first, `fs.writeNew` taking bytes and
refusing links, and `http` sending a caller's `Host` header. From the
milestones: M28.56 (a thrown module struct keeps its identity, found by this
deck), M28.57 (the error conventions) and M28.65 (transport failures as
`net.NetError`, passed on).
