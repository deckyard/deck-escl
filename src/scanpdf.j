# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Bind scanned pages into one PDF: each JPEG or PNG page becomes a PDF page
 * of its physical size, the image embedded as it came (a JPEG is not
 * re-encoded). A separate module so that `escl` alone does not load `pdf.j`.
 *
 * @module scanpdf
 */
use fs;
use math;

import "./escl.j" as escl;
import "pdf.j" as pdf;

/** The largest PDF page side, in points (200 inches), that viewers accept. */
def const MAX_POINTS as int init 14400;

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
    def imgs as list of pdf.Image init [];
    def pgs as list of pdf.Page init [];
    for (def i in 0..len($pages)) {
        def n as int init $i + 1;
        if ($pages[$i].done) {
            fail("page {$n} is the end-of-job marker, not a page");
        }
        if ($pages[$i].contentType == "application/pdf") {
            fail("page {$n} is a PDF already; scan JPEG or PNG pages to bind them");
        }
        def img as pdf.Image;
        try {
            $img = pdf.loadImage("P{$n}", $pages[$i].data);
        } catch (e) {
            fail("page {$n} cannot go into a PDF: " + $e.message);
        }
        def w as int init points($img.width, $resolution);
        def h as int init points($img.height, $resolution);
        if ($w > MAX_POINTS or $h > MAX_POINTS) {
            fail("page {$n} would be {$w} x {$h} points; a PDF page is at most {MAX_POINTS}");
        }
        $imgs[] = $img;
        $pgs[] = pdf.drawImage(pdf.page($w, $h), $img, 0, 0, $w, $h);
    }
    # set once: pdf.addImage / addPage would copy the growing document per page
    $doc.images = $imgs;
    $doc.pages = $pgs;
    def out as bytes;
    try {
        $out = pdf.render($doc);
    } catch (e) {
        fail("cannot render the PDF: " + $e.message);
    }
    return $out;
}

/**
 * Scan and write the pages as one PDF file. The settings' format must be
 * `image/jpeg` or `image/png`: the deck binds the pages itself, so the result
 * does not depend on the scanner's own PDF support. The file is created
 * exclusively and never replaces one.
 *
 * @param s {escl.Scanner} the scanner
 * @param st {escl.Settings} what to scan
 * @param path {string} the PDF file to create
 * @return {int} the number of pages
 * @throws {Error} kind "escl" as `escl.scan` and `build`, or if the file exists or cannot be written
 */
export func scanToPdf(s as escl.Scanner, st as escl.Settings, path as string) {
    if ($st.format != "image/jpeg" and $st.format != "image/png") {
        fail("scanToPdf scans JPEG or PNG pages and binds them; set the format to image/jpeg, got \"" +
            $st.format + "\"");
    }
    if (fs.exists($path)) {
        fail("will not overwrite " + $path);
    }
    def pages as list of escl.Page init escl.scan($s, $st);
    def data as bytes init build($pages, $st.resolution);
    try {
        fs.writeNew($path, "");
    } catch (e) {
        fail("cannot create " + $path + ": " + $e.message);
    }
    try {
        fs.writeBytes($path, $data);
    } catch (e) {
        fs.remove($path);
        fail("cannot write " + $path + ": " + $e.message);
    }
    return len($pages);
}
