<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/escl

A client for eSCL, the driverless scan protocol behind AirScan (AirPrint
scanning) and Mopria Scan. Most network scanners and multifunction printers
made in the last decade speak it: XML documents and image data over HTTP or
HTTPS, no driver. The deck reads what a scanner can do, checks your settings
against it, runs the job and hands back the pages, or writes them to files.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/escl/" as escl;
```

The deck needs the `net` capability, so it runs on the default `jennifer`
binary, not `jennifer-tiny`.

Lengths are in the protocol's unit, 1/300 inch: A4 is 2480 x 3508, US Letter
2550 x 3300. `escl.fromMm(210.0)` converts.

Errors: every failure the deck raises has a message that starts with
`escl: `. Most are an `escl.EsclError` of kind `"escl"`: a setting the scanner
does not offer (named, with what it does offer), an empty feeder, a refused
or aborted job (with the scanner's reasons, e.g. a paper jam), an unreachable
scanner, a malformed reply. Its `status` is the HTTP status of a refused
request (0 otherwise) and `retryAfterMs` the scanner's `Retry-After` (-1 when
it gave none), so a busy scanner (503) says how long to wait. A reached cap is
`Error{kind: "limit"}`: an oversized reply or document, a job past its page
or byte limit, an image with too many PNG chunks or JPEG segments. An error
your own `scanEach` handler throws reaches you with its own kind, and if
cancelling the job then fails too, that is added to its message.

Text the deck returns from a scanner (`makeAndModel`, `state`, job reasons,
a page's `contentType`, discovered names, ...) has every control character
replaced by `?`, so printing it cannot drive a terminal, and every
bidirectional-text control and invisible format character too (zero-width
spaces, line separators, the byte order mark), so a name cannot display
reversed or hide text; text quoted in an error is cut to 80 characters. A
text element over 1024 characters, a document over 1 MiB or 10,000
elements (refused before it is parsed), or a page whose `Content-Type` is
not a plain `type/subtype`, is an error.

```jennifer
try {
    escl.scan($s, $st);
} catch (e) {
    io.printf("%s\n", $e.message);
}
```

## Finding the scanner

`escl.discover(2000)` asks the network once over mDNS and returns every
scanner that answers within two seconds, with a ready `url`:

```jennifer
for (def f in escl.discover(2000)) {
    io.printf("%s  %s\n", $f.name, $f.url);
}
```

Answers are not authenticated (mDNS has no way to): any host on the network
can announce a scanner, so check `name` and `url` before scanning anything
sensitive. Names come back with control characters as `?`. Only answers
from port 5353 with no error code count. The query leaves
by the default route's interface, and only IPv4 addresses are read; a scanner on another subnet or VLAN, or behind Wi-Fi client
isolation, does not answer. Then give the address yourself. A scanner
announces itself as `_uscan._tcp` (`_uscans._tcp` for HTTPS), with its port
and, in the TXT record `rs`, its eSCL root (almost always `eSCL`):

```sh
avahi-browse -rt _uscan._tcp
curl -s http://192.168.1.40:8080/eSCL/ScannerCapabilities | head
```

Many devices use port 80; the HP LaserJet M28 series uses 8080. When the
second command prints a `ScannerCapabilities` document, the deck can drive
the scanner.
