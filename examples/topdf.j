#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Scan the feeder, both sides, into one PDF:
 *
 *   jennifer run examples/topdf.j 192.168.1.40 letter.pdf
 *
 * CI only parses this example: it needs a scanner on the network.
 */
use io;
use os;

import "../src/escl.j" as escl;
import "../src/scanpdf.j" as scanpdf;

def args as list of string init os.ARGS;
if (len($args) != 3) {
    io.printf("usage: jennifer run examples/topdf.j <scanner> <file.pdf>\n");
    exit 2;
}
def s as escl.Scanner init escl.scanner($args[1]);
def st as escl.Settings init escl.settings();
$st.source = escl.FEEDER;
$st.duplex = true;
$st.resolution = 200;
def n as int init scanpdf.scanToPdf($s, $st, $args[2]);
io.printf("%d pages in %s\n", $n, $args[2]);
