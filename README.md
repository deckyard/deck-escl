# @deckyard/escl

[![test](https://github.com/deckyard/deck-escl/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-escl/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-escl/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-escl)](https://github.com/deckyard/deck-escl/releases/latest)

A [Jennifer](https://jennifer-lang.dev/) client for eSCL, the driverless scan
protocol behind AirScan (AirPrint scanning) and Mopria Scan: read what a
network scanner can do, check settings against it, scan from the glass or the
feeder (duplex too) and get the pages back or written to files.

**[Documentation](https://deckyard.github.io/deck-escl/)**

## Install

```sh
jvc add @deckyard/escl
```

This vendors the deck to `vendor/<scope>/escl/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-escl-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/escl/" as escl;

def s as escl.Scanner init escl.scanner("192.168.1.40:8080");
def st as escl.Settings init escl.settings();
$st.source = escl.FEEDER;
$st.duplex = true;
escl.scanToFiles($s, $st, "/srv/scans", "letter");
```

## Requirements

Jennifer 0.26.0 or newer, the default binary (the deck needs `net`; it does
not run on `jennifer-tiny`), and a scanner that speaks eSCL on the network.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/escl_test.j      # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
