#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Find scanners, or scan from one into the current directory:
 *
 *   jennifer run examples/scan.j                     # list the scanners that answer
 *   jennifer run examples/scan.j 192.168.1.40:8080   # scan
 *
 * Scans the feeder if the scanner has one, else the glass. CI only parses
 * this example: it needs a scanner on the network.
 */
use io;
use os;

import "../src/escl.j" as escl;

def args as list of string init os.ARGS;
if (len($args) == 1) {
    for (def f in escl.discover(2000)) {
        io.printf("%s  %s  %s\n", $f.name, $f.model, $f.url);
    }
    exit 0;
}
if (len($args) != 2) {
    io.printf("usage: jennifer run examples/scan.j [host[:port] or URL]\n");
    exit 2;
}
def s as escl.Scanner init escl.scanner($args[1]);
def caps as escl.Capabilities init escl.capabilities($s);
io.printf("%s, eSCL %s\n", $caps.makeAndModel, $caps.version);
def st as escl.Settings init escl.settings();
for (def in2 in $caps.inputs) {
    io.printf(
        "  %s duplex=%v: %v dpi, %v\n",
        $in2.source,
        $in2.duplex,
        $in2.resolutions,
        $in2.colorModes);
    if ($in2.source == escl.FEEDER) {
        $st.source = escl.FEEDER;
    }
}
def files as list of string init escl.scanToFiles($s, $st, ".", "scan");
for (def f in $files) {
    io.printf("wrote %s\n", $f);
}
