<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Scanning

## The whole job

`escl.scan(s, st)` does everything: reads the capabilities, checks the
settings, creates the job, fetches every page, and checks how the job ended.
`escl.scanToFiles(s, st, dir, stem)` writes each page as it arrives.

```jennifer
def s as escl.Scanner init escl.scanner("192.168.1.40:8080");
def st as escl.Settings init escl.settings();     # platen, RGB24, 300 dpi, JPEG
$st.resolution = 600;
def pages as list of escl.Page init escl.scan($s, $st);
fs.writeBytes("page." + escl.extension($pages[0].contentType), $pages[0].data);
```

A feeder job returns a page per side scanned:

```jennifer
$st.source = escl.FEEDER;
$st.duplex = true;
$st.format = "application/pdf";
def files as list of string init escl.scanToFiles($s, $st, "/srv/scans", "invoice");
# ["/srv/scans/invoice-001.pdf", "/srv/scans/invoice-002.pdf", ...]
```

`scanToFiles` never overwrites: it refuses before the job if the first name
is taken, and creates every file exclusively, so a name taken (or a link
planted) during the job stops it; the error then names the files already
written. `scan` holds every page in memory and returns them only when the
whole job succeeds: a paper jam on page 40 loses the 39 before it. For
feeder jobs prefer `scanToFiles` or `scanpdf.scanToPdf`, which keep the
pages already scanned, or `scanEach`, which hands each one over as it
arrives. A platen job gives one page: the deck does not ask the scanner for
a second.
A feeder job is refused before it starts when the scanner reports the feeder
empty, jammed, open or misfed (`ScannerAdfJam`, `ScannerAdfHatchOpen`, ...). Every whole-job call (`scan`, `scanEach`, `scanToFiles`,
`scanpdf.scanToPdf`) stops a job past `Options.maxPages` pages (500) or
`Options.maxJobBytes` bytes in all (1 GiB), both with `Error{kind: "limit"}`,
and each page is at most
`maxPageBytes` (256 MiB); together they bound what a scanner that never ends
a job can make the deck hold or write. A format the scanner can produce as one multi-page document (often
`application/pdf` from a feeder) may arrive as a single page.

## One PDF

`scanpdf.scanToPdf(s, st, path)` scans JPEG (or PNG) pages and binds them
into one PDF, each page as large as the area scanned (at most 200 inches a
side). Nothing is decoded: each image header is read first, and a PNG with
transparency or interlacing, which would have to be, is refused (scanners
do not send them), and so is a header too long to be a scanner's (more than
64 JPEG segments or PNG chunks before the image); `scanpdf.build(pages,
resolution)` does the binding alone. The JPEG data goes in unchanged, so a
page is no larger in the PDF than it was from the scanner.

```jennifer
import "@deckyard/escl/scanpdf.j" as scanpdf;

$st.source = escl.FEEDER;
$st.duplex = true;
scanpdf.scanToPdf($s, $st, "/srv/scans/letter.pdf");
```

This works the same on every scanner, unlike asking the scanner for
`application/pdf`, which not all offer for every input. It holds the whole
job in memory while binding, several times over: peak memory is about seven
times the job's size, so lower `maxJobBytes` (1 GiB by default) where memory
is tight. The file name is taken, as an empty file, before the scan starts,
so a wrong directory fails before any paper moves. If the job fails part way
(a paper jam, a limit) or the pages cannot be bound or written, the pages
already scanned are kept as `letter-001.jpg`, ... beside it (`letter-2-001.jpg`,
... when those names are taken) and the error names them.

## Page by page

`escl.scanEach(s, st, handler)` calls `handler(page, n)` as each page
arrives and keeps nothing, for jobs too long to hold in memory. An error the
handler throws cancels the job and reaches the caller.

```jennifer
func store(p as escl.Page, n as int) {
    fs.writeBytes("/srv/scans/p{$n}." + escl.extension($p.contentType), $p.data);
}

escl.scanEach($s, $st, store);
```

## Settings

`escl.settings()` gives the defaults; change fields from there. Every
setting is checked against the input it selects before the scanner sees a
request, and the error names what the input does offer:

| Field | Default | Checked against |
|---|---|---|
| `source` | `escl.PLATEN` | the inputs: `PLATEN` or `FEEDER` |
| `duplex` | `false` | a duplex feeder |
| `colorMode` | `"RGB24"` | `Input.colorModes` |
| `resolution` | `300` | `Input.resolutions` or one of `Input.resolutionRanges` |
| `format` | `"image/jpeg"` | `Input.formats` |
| `intent` | `""` (none sent) | `Input.intents` |
| `x`, `y`, `width`, `height` | `0` | the input's size; a 0 width or height reaches to the maximum |
| `adjust` | `{}` (scanner defaults) | `Capabilities.adjustments` |

Brightness, contrast, sharpen and threshold are sent only when set in
`adjust`, and only if the scanner lists their `*Support` range; each value
must lie on that range's steps:

```jennifer
def caps as escl.Capabilities init escl.capabilities($s);
if (maps.has($caps.adjustments, "Brightness")) {
    $st.adjust["Brightness"] = $caps.adjustments["Brightness"].normal + 100;
}
```

`escl.check(caps, st)` runs the checks alone and returns the settings with
the scan area filled in; `escl.settingsXml(caps, st)` shows the
`ScanSettings` document a job would send.

## What a scanner offers

```jennifer
def caps as escl.Capabilities init escl.capabilities($s);
for (def in2 in $caps.inputs) {
    io.printf("%s duplex=%v %v dpi %v\n", $in2.source, $in2.duplex, $in2.resolutions, $in2.formats);
}
```

Each input (the platen, the feeder, the feeder in duplex) is an
`escl.Input`. Its setting profiles are merged. Only resolutions equal in X
and Y are listed. A device that lists the feeder's `Duplex` option but no
duplex capabilities gets a duplex input with the simplex ones.
`escl.status(s)` gives the scanner's state, the feeder's (`ScannerAdfLoaded`,
`ScannerAdfEmpty`, `ScannerAdfJam`, ...) and the jobs it remembers.

## Step by step

`escl.start(s, caps, st)` creates a job, `escl.nextPage(job)` fetches one
page (`done` when there are no more) and `escl.cancel(job)` deletes it.
Cancel a job you stop early, or the scanner may stay busy with it:

```jennifer
def job as escl.Job init escl.start($s, $caps, $st);
def first as escl.Page init escl.nextPage($job);
escl.cancel($job);
```

A loop of your own counts each page with `escl.countPage(job, page)`, which
applies `maxPages` and `maxJobBytes`, and ends with `escl.finish(job)`: it
fails if the scanner's status lists the job as aborted (a paper jam) or it
gave no pages, then deletes the finished job on the scanner, as `scan` does.
A status that cannot be read after the last page does not fail the job, so
pages already received are not lost to it.

```jennifer
def job as escl.Job init escl.start($s, $caps, $st);
while (true) {
    def p as escl.Page init escl.nextPage($job);
    if ($p.done) {
        break;
    }
    $job = escl.countPage($job, $p);
    # use $p
}
escl.finish($job);
```

## Busy scanners and slow pages

A scanner answers 503 while it is busy, warming up, or still scanning the
next page. The deck retries every `retryMs`, or after the reply's
`Retry-After` seconds when that is longer, until `busyWaitMs` has passed (1 s
and 60 s by default). A page can take a while to arrive at a high
resolution; each read may stall for `timeoutMs` (120 s). That bounds a
silent scanner, not a slow one: a device sending a byte at a time can stretch
a transfer indefinitely, so set `deadlineMs` to bound each request as a
whole. Set them with
`escl.scannerWith`:

```jennifer
def o as escl.Options;
$o.busyWaitMs = 120000;
def s as escl.Scanner init escl.scannerWith("https://scanner.lan", $o);
```

## Logins

A scanner that protects scanning with a password (HTTP Basic) takes
`Options.username` and `password`. The login is refused where it is not
protected: on a plain `http` address, where anyone on the network can read
it, and with `skipVerify`, where anyone can pose as the scanner. Use the
scanner's `https` address with its certificate pinned in `caCert`, or set
`allowPlainAuth` to accept the risk. A 401 says whether a login was
missing or refused. A login written into the address (`user:pass@host`) is
refused, and never echoed in the error.

## HTTPS

`https://` addresses verify the certificate, which on a scanner is almost
always self-signed. Give the device's certificate in `caCert` (PEM) to trust
exactly that one, or set `skipVerify` on a network you trust. A certificate in
`caCert` must still name the host in the address: one issued to
`EPSON123456.local` does not verify for `https://192.168.1.50`. Use the name
the certificate carries, as the scanner announces it (`escl.discover`, a
`.local` name), or make the device a certificate that lists its address.

## Image size

`escl.imageInfo(job)` reads the scanner's `ScanImageInfo` for the page last
fetched: its size in pixels and bytes per row. Not every scanner offers it;
the call then fails with a clear error.

## Devices

Every request names the scanner in its `Host` header with the port written
out (`192.168.1.50:80`): Epson devices refuse a request without it, and the
others accept it. This needs an interpreter whose `http.j` sends a `Host`
naming the URL's own host and port as written.

The job URL a scanner returns often names a host or port the client cannot
reach (`http://NPI6142D.local.:80/...`); the deck keeps only its path and
uses the address you gave. Elements are matched by local name, so a device
using a default namespace instead of the `scan:` / `pwg:` prefixes reads
the same.

The tests use capability documents shaped like an HP LaserJet M28 (flatbed)
and an Epson document scanner (feeder, simplex and duplex). Reports from
other devices are welcome.
