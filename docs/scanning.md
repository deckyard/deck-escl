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
written. `scan` holds every page in memory; for long feeder jobs prefer
`scanToFiles`. Both stop a job after `Options.maxPages` pages (500), so a
scanner that never ends a job cannot fill memory or disk. A format the scanner can produce as one multi-page document (often
`application/pdf` from a feeder) may arrive as a single page.

## One PDF

`scanpdf.scanToPdf(s, st, path)` scans JPEG (or PNG) pages and binds them
into one PDF, each page as large as the area scanned; `scanpdf.build(pages,
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
job in memory while binding.

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
| `resolution` | `300` | `Input.resolutions` or `Input.resolutionRange` |
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

## Busy scanners and slow pages

A scanner answers 503 while it is busy, warming up, or still scanning the
next page. The deck retries every `retryMs`, or after the reply's
`Retry-After` seconds when that is longer, until `busyWaitMs` has passed (1 s
and 60 s by default). A page can take a while to arrive at a high
resolution; each read may stall for `timeoutMs` (120 s). Set them with
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
missing or refused.

## HTTPS

`https://` addresses verify the certificate, which on a scanner is almost
always self-signed. Give the device's certificate in `caCert` (PEM) to trust
exactly that one, or set `skipVerify` on a network you trust.

## Image size

`escl.imageInfo(job)` reads the scanner's `ScanImageInfo` for the page last
fetched: its size in pixels and bytes per row. Not every scanner offers it;
the call then fails with a clear error.

## Devices

The job URL a scanner returns often names a host or port the client cannot
reach (`http://NPI6142D.local.:80/...`); the deck keeps only its path and
uses the address you gave. Elements are matched by local name, so a device
using a default namespace instead of the `scan:` / `pwg:` prefixes reads
the same.

The tests use capability documents shaped like an HP LaserJet M28 (flatbed)
and an Epson document scanner (feeder, simplex and duplex). Reports from
other devices are welcome.
