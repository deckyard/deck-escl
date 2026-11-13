# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Bind scanned pages into one PDF: each JPEG or PNG page becomes a PDF page
 * of its physical size, the image embedded as it came (nothing is decoded or
 * re-encoded). Image headers are checked first: PNGs with transparency or
 * interlacing, which would have to be decoded, are refused. A separate module
 * so that `escl` alone does not load `pdf.j`.
 *
 * @module scanpdf
 */
use convert;
use fs;
use math;
use regex;
use strings;

import "./escl.j" as escl;
import "pdf.j" as pdf;

/** The largest PDF page side, in points (200 inches), that viewers accept. */
def const MAX_POINTS as int init 14400;

/** The most JPEG segments before the frame header; scanners write a handful. */
def const MAX_SEGMENTS as int init 64;

/** The most PNG chunks before the image data; scanners write a handful. */
def const MAX_CHUNKS as int init 64;

/** The most names `keep` tries for the pages of a failed PDF: `-2`, `-3`, ... */
def const MAX_STEMS as int init 99;

# the characters `clip` replaces: the same set as escl's
def const CONTROLS as string init '[\x00-\x1f\x7f-\x9f\x{061c}\x{180e}\x{200b}-\x{200f}' +
    '\x{2028}-\x{202e}\x{2060}-\x{2069}\x{feff}]';

def const PNG as bytes init convert.bytesFromString("utf-8", "PNG");
def const IHDR_BYTES as bytes init convert.bytesFromString("utf-8", "IHDR");

# PNG chunk types, as the big-endian numbers their four letters make
def const IHDR as int init 1229472850;
def const IDAT as int init 1229209940;
def const IEND as int init 1229278788;
def const TRNS as int init 1951551059;
def const PLTE as int init 1347179589;

/**
 * Throw an escl error.
 *
 * @param message {string} what went wrong, without the `escl: ` prefix
 * @throws {Error} kind "escl", always
 */
func fail(message as string) {
    throw Error{kind: "escl", message: "escl: " + $message};
}

/**
 * An image's size, from its header.
 *
 * @field width {int} pixels
 * @field height {int} pixels
 */
def struct Size {
    width as int,
    height as int
};

/**
 * A big-endian number of `count` bytes.
 *
 * @param data {bytes} the image
 * @param at {int} where it starts
 * @param count {int} 2 or 4
 * @param n {int} the page number, for the error
 * @return {int} the number
 * @throws {Error} kind "escl" if it runs past the end
 */
func be(data as bytes, at as int, count as int, n as int) {
    if ($at < 0 or $at + $count > len($data)) {
        fail("page {$n} is a truncated image");
    }
    def v as int init 0;
    for (def i in 0..$count) {
        $v = $v * 256 + $data[$at + $i];
    }
    return $v;
}

/**
 * Text for an error message: at most 80 characters, control, bidirectional-text
 * and invisible format characters as `?`, as `escl` shows device text.
 *
 * @param s {string} the text
 * @return {string} the text, clipped
 */
func clip(s as string) {
    def t as string init $s;
    if (len($t) > 80) {
        $t = strings.substring($t, 0, 80) + "...";
    }
    return regex.replace(CONTROLS, $t, "?");
}

/**
 * Whether `data` holds these bytes at `at`.
 *
 * @param data {bytes} the image
 * @param at {int} where to look
 * @param want {bytes} the bytes
 * @return {bool} whether they are there
 */
func has(data as bytes, at as int, want as bytes) {
    if ($at < 0 or $at + len($want) > len($data)) {
        return false;
    }
    for (def i in 0..len($want)) {
        if ($data[$at + $i] != $want[$i]) {
            return false;
        }
    }
    return true;
}

/**
 * The size of a JPEG or PNG page, read from its header before anything
 * decodes it. Only the kinds `pdf.j` embeds without decoding pass: JPEG, and
 * PNG without transparency or interlacing (what scanners send). `pdf.j`
 * would decode the others and split off their alpha, so a page that is not
 * what a scanner sends is refused before it costs a decode.
 *
 * @param data {bytes} the page
 * @param n {int} the page number, for errors
 * @return {Size} its size in pixels
 * @throws {Error} kind "escl" if it is not such an image or its header is malformed
 */
func imageSize(data as bytes, n as int) {
    if (len($data) >= 8 and $data[0] == 137 and has($data, 1, PNG)) {
        return pngSize($data, $n);
    }
    if (len($data) >= 3 and $data[0] == 255 and $data[1] == 216 and $data[2] == 255) {
        return jpegSize($data, $n);
    }
    fail("page {$n} is not a JPEG or PNG image");
    return Size{width: 0, height: 0};
}

/**
 * A PNG's size; refuses transparency and interlacing. Every chunk is walked:
 * a second header or a transparency chunk after the image data would still
 * make `pdf.j` decode it.
 *
 * @param data {bytes} the PNG
 * @param n {int} the page number
 * @return {Size} its size
 * @throws {Error} kind "escl" for a PNG `pdf.j` would have to decode
 */
func pngSize(data as bytes, n as int) {
    if (not has($data, 12, IHDR_BYTES) or len($data) < 33) {
        fail("page {$n} is a PNG without a header");
    }
    def size as Size init Size{width: be($data, 16, 4, $n), height: be($data, 20, 4, $n)};
    def kind as int init $data[25];
    if ($kind == 4 or $kind == 6) {
        fail("page {$n} is a PNG with transparency; scanners do not send those");
    }
    if ($data[28] != 0) {
        fail("page {$n} is an interlaced PNG; scanners do not send those");
    }
    # the chunk after IHDR; a tRNS chunk is transparency too. The walk is
    # bounded: encoders write image data in chunks of kilobytes, so a file
    # averaging under 1 KiB a chunk is a flood
    def limit as int init MAX_CHUNKS + len($data) // 1024;
    def at as int init 33;
    def chunks as int init 0;
    def before as int init 0;
    def seenData as bool init false;
    while (true) {
        def chunk as int init be($data, $at + 4, 4, $n);
        if ($chunk == IEND) {
            break;
        }
        if ($chunk == TRNS) {
            fail("page {$n} is a PNG with transparency; scanners do not send those");
        }
        if ($chunk == IHDR or ($seenData and $chunk == PLTE)) {
            fail("page {$n} is a malformed PNG");
        }
        if ($chunk == IDAT) {
            $seenData = true;
        } elseif (not $seenData) {
            $before = $before + 1;
            if ($before > MAX_CHUNKS) {
                fail("page {$n} is a PNG with more than {MAX_CHUNKS} chunks before its image data");
            }
        }
        $chunks = $chunks + 1;
        if ($chunks > $limit) {
            fail("page {$n} is a PNG of more than {$limit} chunks");
        }
        def next as int init $at + 12 + be($data, $at, 4, $n);
        if ($next > len($data)) {
            fail("page {$n} is a truncated PNG");
        }
        $at = $next;
    }
    if (not $seenData) {
        fail("page {$n} is a PNG without image data");
    }
    return $size;
}

/**
 * A JPEG's size, from its first frame header.
 *
 * @param data {bytes} the JPEG
 * @param n {int} the page number
 * @return {Size} its size
 * @throws {Error} kind "escl" if no frame header comes before the image data
 */
func jpegSize(data as bytes, n as int) {
    def at as int init 2;
    def segments as int init 0;
    while (true) {
        $segments = $segments + 1;
        if ($segments > MAX_SEGMENTS) {
            fail("page {$n} is a JPEG with more than {MAX_SEGMENTS} segments before its frame header");
        }
        if ($at + 4 > len($data) or $data[$at] != 255) {
            fail("page {$n} is a malformed JPEG");
        }
        def marker as int init $data[$at + 1];
        if ($marker == 255) {
            $at = $at + 1;
            continue;
        }
        if ($marker >= 192 and $marker <= 207 and $marker != 196 and $marker != 200 and
            $marker != 204) {
            return Size{width: be($data, $at + 7, 2, $n), height: be($data, $at + 5, 2, $n)};
        }
        if ($marker == 217 or $marker == 218) {
            fail("page {$n} is a JPEG without a frame header");
        }
        if ($marker == 1 or ($marker >= 208 and $marker <= 215)) {
            $at = $at + 2;
            continue;
        }
        def length as int init be($data, $at + 2, 2, $n);
        if ($length < 2) {
            fail("page {$n} is a malformed JPEG");
        }
        $at = $at + 2 + $length;
    }
    return Size{width: 0, height: 0};
}

/**
 * Pixels at a resolution as PDF points, at least 1.
 *
 * @param pixels {int} the length in pixels
 * @param resolution {int} dpi
 * @return {int} the length in points (1/72 inch)
 */
func points(pixels as int, resolution as int) {
    def p as int init math.round($pixels * 72.0 / $resolution);
    if ($p < 1) {
        return 1;
    }
    return $p;
}

/**
 * One PDF of these pages, in order, each page as large as the area scanned.
 *
 * @param pages {list of escl.Page} JPEG or PNG pages, as `escl.scan` returns them
 * @param resolution {int} the dpi they were scanned at, 1 to 10000
 * @return {bytes} the PDF file
 * @throws {Error} kind "escl" if there are no pages, a page is not JPEG or PNG, or the PDF cannot be built
 * @example
 *   def doc as bytes init scanpdf.build(escl.scan($s, $st), $st.resolution);
 */
export func build(pages as list of escl.Page, resolution as int) {
    if ($resolution < 1 or $resolution > 10000) {
        fail("the resolution must be 1 to 10000 dpi, got {$resolution}");
    }
    if (len($pages) == 0) {
        fail("there are no pages to bind");
    }
    def doc as pdf.Document init pdf.document();
    for (def i in 0..len($pages)) {
        def n as int init $i + 1;
        if ($pages[$i].done) {
            fail("page {$n} is the end-of-job marker, not a page");
        }
        if ($pages[$i].contentType == "application/pdf") {
            fail("page {$n} is a PDF already; scan JPEG or PNG pages to bind them");
        }
        def size as Size init imageSize($pages[$i].data, $n);
        if ($size.width == 0 or $size.height == 0) {
            fail("page {$n} is an empty image");
        }
        def w as int init points($size.width, $resolution);
        def h as int init points($size.height, $resolution);
        if ($w > MAX_POINTS or $h > MAX_POINTS) {
            fail("page {$n} would be {$w} x {$h} points; a PDF page is at most {MAX_POINTS}");
        }
        def img as pdf.Image;
        try {
            $img = pdf.loadImage("P{$n}", $pages[$i].data);
        } catch (e) {
            fail("page {$n} cannot go into a PDF: " + clip($e.message));
        }
        # straight into the document: a list set at the end would hold every
        # image twice; pdf.addImage / addPage would copy the document per page
        $doc.pages[] = pdf.drawImage(pdf.page($w, $h), $img, 0, 0, $w, $h);
        $doc.images[] = $img;
    }
    def out as bytes;
    try {
        $out = pdf.render($doc);
    } catch (e) {
        fail("cannot render the PDF: " + clip($e.message));
    }
    return $out;
}

/**
 * Scan and write the pages as one PDF file. The settings' format must be
 * `image/jpeg` or `image/png`: the deck binds the pages itself, so the result
 * does not depend on the scanner's own PDF support. The file is created
 * exclusively and never replaces one: its name is taken, as an empty file,
 * before the scan starts, so an unusable path fails before any paper moves.
 * If the job fails part way (a paper jam, a limit) or the pages cannot be
 * bound or written, the pages already scanned are kept as
 * `<path without .pdf>-001.<ext>`, ... (`<path without .pdf>-2-001.<ext>`
 * and so on when those names are taken) and the error names them. Binding
 * holds the pages several times over: peak memory is about seven times the
 * job's size, so lower `Options.maxJobBytes` where memory is tight.
 *
 * @param s {escl.Scanner} the scanner
 * @param st {escl.Settings} what to scan
 * @param path {string} the PDF file to create
 * @return {int} the number of pages
 * @throws {Error} kind "escl" as `escl.scan` and `build`, or if the file exists or cannot be written
 */
export func scanToPdf(s as escl.Scanner, st as escl.Settings, path as string) {
    if ($st.format != "image/jpeg" and $st.format != "image/png") {
        fail("scanToPdf scans JPEG or PNG pages and binds them; set the format to image/jpeg or image/png, got " +
            quoted($st.format));
    }
    claim($path);
    def job as escl.Job;
    try {
        $job = escl.start($s, escl.capabilities($s), $st);
    } catch (e) {
        throw releasing($path, $e);
    }
    def pages as list of escl.Page init [];
    try {
        while (true) {
            def p as escl.Page init escl.nextPage($job);
            if ($p.done) {
                break;
            }
            $job = escl.countPage($job, $p);
            $pages[] = $p;
        }
        escl.finish($job);
    } catch (e) {
        throw keep(releasing($path, stopJob($job, $e)), $pages, $path);
    }
    def data as bytes;
    try {
        $data = build($pages, $st.resolution);
    } catch (e) {
        throw keep(releasing($path, $e), $pages, $path);
    }
    # the empty claim goes, then one exclusive create: a file or link that
    # appeared meanwhile is refused
    try {
        release($path);
        fs.writeNew($path, $data);
    } catch (e) {
        throw keep(
            Error{
                kind: "escl",
                message: "escl: cannot write " + quoted($path) + ": " + clip($e.message)
            },
            $pages,
            $path);
    }
    return len($pages);
}

/**
 * Cancel a job that failed, as `escl.scan` does: the error keeps its kind,
 * and a failure to cancel is added to its message.
 *
 * @param job {escl.Job} the job
 * @param err {Error} why it stopped
 * @return {Error} the error to report
 */
func stopJob(job as escl.Job, err as Error) {
    try {
        escl.cancel($job);
    } catch (e) {
        $err.message = $err.message + "; cancelling the job failed too: " + $e.message;
    }
    return $err;
}

/**
 * Take a file name by creating it empty and exclusively.
 *
 * @param path {string} the file
 * @throws {Error} kind "escl" if the name is taken or cannot be created
 */
func claim(path as string) {
    if (fs.exists($path) or isLink($path)) {
        fail("will not overwrite " + quoted($path));
    }
    try {
        fs.writeNew($path, "");
    } catch (e) {
        if (fs.exists($path) or isLink($path)) {
            fail("will not overwrite " + quoted($path));
        }
        fail("cannot write " + quoted($path) + ": " + clip($e.message));
    }
}

/**
 * Give back a name `claim` took: removed while it is still an empty file,
 * left alone if anything else has replaced it.
 *
 * @param path {string} the file
 * @throws {Error} kind "escl" if it cannot be removed
 */
func release(path as string) {
    if (isLink($path) or not fs.isFile($path) or fs.stat($path).size != 0) {
        return;
    }
    try {
        fs.remove($path);
    } catch (e) {
        fail("cannot remove the empty " + quoted($path) + ": " + clip($e.message));
    }
}

/**
 * `release` after a failure: the failure stays the error to report, and a
 * name that cannot be given back is added to its message.
 *
 * @param path {string} the file
 * @param err {Error} the failure
 * @return {Error} the error to report
 */
func releasing(path as string, err as Error) {
    try {
        release($path);
    } catch (e) {
        def why as string init $e.message;
        if (strings.startsWith($why, "escl: ")) {
            $why = strings.substring($why, 6);
        }
        $err.message = $err.message + "; " + $why;
    }
    return $err;
}

/**
 * Save the scanned pages beside the PDF that could not be made, so a long
 * scan is not lost, and say so in the error. The names are
 * `<path without .pdf>-NNN.<ext>`, or `-2-NNN`, `-3-NNN`, ... when one of
 * those is taken; a page that cannot be written does not stop the others.
 *
 * @param err {Error} why the PDF could not be made
 * @param pages {list of escl.Page} the pages
 * @param path {string} the PDF file
 * @return {Error} the error, naming the pages kept
 */
func keep(err as Error, pages as list of escl.Page, path as string) {
    if (len($pages) == 0) {
        return $err;
    }
    def base as string init $path;
    if (strings.endsWith(strings.lower($base), ".pdf")) {
        $base = strings.substring($base, 0, len($base) - 4);
    }
    def width as int init len(convert.toString(len($pages)));
    if ($width < 3) {
        $width = 3;
    }
    def stem as string init freeStem($base, $pages, $width);
    if ($stem == "") {
        $err.message = $err.message + "; the scanned pages could not be kept: the names " +
            quoted(keptName($base, 1, $width, $pages[0])) + " to " +
            quoted(keptName($base + "-{MAX_STEMS}", 1, $width, $pages[0])) + " are taken";
        return $err;
    }
    def kept as list of string init [];
    def failed as int init 0;
    def firstFailure as string init "";
    for (def i in 0..len($pages)) {
        def name as string init keptName($stem, $i + 1, $width, $pages[$i]);
        try {
            fs.writeNew($name, $pages[$i].data);
            $kept[] = $name;
        } catch (e) {
            if ($failed == 0) {
                $firstFailure = quoted($name) + ": " + clip($e.message);
            }
            $failed = $failed + 1;
        }
    }
    if (len($kept) > 0) {
        $err.message = $err.message + "; " + convert.toString(len($kept)) + " of the " +
            convert.toString(len($pages)) + " scanned page(s) were kept as " + quoted($kept[0]) +
            " to " + quoted($kept[len($kept) - 1]);
    }
    if ($failed > 0) {
        $err.message = $err.message + "; " + convert.toString($failed) +
            " page(s) could not be kept, the first at " + $firstFailure;
    }
    return $err;
}

/**
 * The first of `base`, `base-2`, ... `base-MAX_STEMS` under which no page's
 * name is taken, or `""` if there is none.
 *
 * @param base {string} the path without `.pdf`
 * @param pages {list of escl.Page} the pages
 * @param width {int} the digits a page number is padded to
 * @return {string} the stem
 */
func freeStem(base as string, pages as list of escl.Page, width as int) {
    for (def k in 1..MAX_STEMS + 1) {
        def stem as string init $base;
        if ($k > 1) {
            $stem = $base + "-{$k}";
        }
        if (namesFree($stem, $pages, $width)) {
            return $stem;
        }
    }
    return "";
}

/**
 * Whether no page's name under `stem` is taken, by a file or a link.
 *
 * @param stem {string} the stem
 * @param pages {list of escl.Page} the pages
 * @param width {int} the digits a page number is padded to
 * @return {bool} whether all are free
 */
func namesFree(stem as string, pages as list of escl.Page, width as int) {
    for (def i in 0..len($pages)) {
        def name as string init keptName($stem, $i + 1, $width, $pages[$i]);
        if (fs.exists($name) or isLink($name)) {
            return false;
        }
    }
    return true;
}

/**
 * The name a kept page is written to: `<stem>-NNN.<ext>`, the extension
 * from the page's type or, failing that, its first bytes.
 *
 * @param stem {string} the stem
 * @param n {int} the page number, from 1
 * @param width {int} the digits it is padded to
 * @param p {escl.Page} the page
 * @return {string} the path
 */
func keptName(stem as string, n as int, width as int, p as escl.Page) {
    def num as string init convert.toString($n);
    while (len($num) < $width) {
        $num = "0" + $num;
    }
    return $stem + "-" + $num + "." + escl.pageExtension($p);
}

/**
 * Text quoted for an error message, clipped.
 *
 * @param s {string} the text
 * @return {string} the text in quotes
 */
func quoted(s as string) {
    return "\"" + clip($s) + "\"";
}

/**
 * Whether a path is a symbolic link (`fs.exists` follows links).
 *
 * @param path {string} the path
 * @return {bool} whether it is a link
 */
func isLink(path as string) {
    try {
        fs.readlink($path);
    } catch (e) {
        return false;
    }
    return true;
}
