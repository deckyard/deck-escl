# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A client for eSCL, the driverless scan protocol behind AirScan (AirPrint
 * scanning) and Mopria Scan: XML documents and image data over HTTP or HTTPS.
 *
 * `scanner` names the device, `capabilities` and `status` read it, and `scan`
 * runs a whole job: it checks the settings against the capabilities, creates
 * the job, fetches every page, and cancels the job if anything fails.
 * `start`, `nextPage` and `cancel` are the same steps one at a time.
 *
 * Lengths are in the protocol's unit, 1/300 inch; `fromMm` converts.
 * Elements are matched by local name, so any namespace prefix a device uses
 * reads the same.
 *
 * @module escl
 */
use convert;
use fs;
use lists;
use maps;
use math;
use net;
use strings;
use task;
use time;
use xml;

import "http.j" as http;

/** The flatbed glass, the `source` of a `Settings`. */
export def const PLATEN as string init "Platen";
/** The automatic document feeder, the `source` of a `Settings`. */
export def const FEEDER as string init "Feeder";

/** How long one read may stall, in ms, when `Options.timeoutMs` is 0. */
export def const DEFAULT_TIMEOUT_MS as int init 120000;
/** How long a busy scanner is retried, in ms, when `Options.busyWaitMs` is 0. */
export def const DEFAULT_BUSY_WAIT_MS as int init 60000;
/** The pause between retries, in ms, when `Options.retryMs` is 0. */
export def const DEFAULT_RETRY_MS as int init 1000;
/** The largest page accepted, in bytes, when `Options.maxPageBytes` is 0. */
export def const DEFAULT_MAX_PAGE_BYTES as int init 268435456;
/** The most pages one job may give when `Options.maxPages` is 0. */
export def const DEFAULT_MAX_PAGES as int init 500;
/** The most bytes one job's pages may add up to when `Options.maxJobBytes` is 0 (1 GiB). */
export def const DEFAULT_MAX_JOB_BYTES as int init 1073741824;

/**
 * The image adjustments a scanner may offer, in the order a request sends
 * them: the keys of `Capabilities.adjustments` and `Settings.adjust`.
 */
export def const ADJUSTMENTS as list of string init [
    "Threshold",
    "Sharpen",
    "Contrast",
    "Brightness"
];

# mDNS: the group, and the services eSCL scanners announce.
def const MDNS_GROUP as string init "224.0.0.251:5353";
def const USCAN as string init "_uscan._tcp.local";
def const USCANS as string init "_uscans._tcp.local";
# More mDNS records than any real network has: discovery stops reading there.
def const MAX_RECORDS as int init 2000;

def const SCAN_NS as string init "http://schemas.hp.com/imaging/escl/2011/05/03";
def const PWG_NS as string init "http://www.pwg.org/schemas/2010/12/sm";
# Capability and status documents are small; a larger one is not eSCL.
def const MAX_DOC_BYTES as int init 4194304;
# Real capability documents have a few hundred elements and lists of a few
# dozen entries; these bounds keep a hostile document's parse short.
def const MAX_ELEMENTS as int init 10000;
def const MAX_ITEMS as int init 256;
def const LETTERS as string init "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/**
 * How to talk to a scanner. The zero value is the default for every field.
 *
 * @field skipVerify {bool} accept any HTTPS certificate (the self-signed one most scanners have); only for a scanner on a network you trust
 * @field caCert {bytes} a PEM certificate to trust for HTTPS, the scanner's own or its CA; safer than `skipVerify`
 * @field timeoutMs {int} how long one read may stall, in ms (0 = `DEFAULT_TIMEOUT_MS`); a page at a high resolution can take a while to arrive
 * @field busyWaitMs {int} how long to keep retrying a scanner that answers 503 (busy, warming up, page not ready), in ms (0 = `DEFAULT_BUSY_WAIT_MS`)
 * @field retryMs {int} the pause between those retries, in ms (0 = `DEFAULT_RETRY_MS`)
 * @field maxPageBytes {int} the largest page accepted, in bytes (0 = `DEFAULT_MAX_PAGE_BYTES`)
 * @field maxJobBytes {int} the most bytes one job's pages may add up to (0 = `DEFAULT_MAX_JOB_BYTES`); with `maxPages` it bounds what `scan`, `scanEach`, `scanToFiles` and `scanpdf.scanToPdf` hold or write
 * @field deadlineMs {int} the longest one request may take as a whole, in ms (0 = no limit: only `timeoutMs` per read applies, so a scanner sending a byte at a time can stretch a transfer)
 * @field maxPages {int} the most pages one job may give in `scan`, `scanEach`, `scanToFiles` and `scanpdf.scanToPdf` (0 = `DEFAULT_MAX_PAGES`)
 * @field username {string} a login for scanners that want one (HTTP Basic); `""` for none
 * @field password {string} the password for `username`
 * @field allowPlainAuth {bool} allow sending the login where it is not protected: over plain `http`, or over `https` with `skipVerify`; without it a login needs `https` with a verified certificate
 */
export def struct Options {
    skipVerify as bool,
    caCert as bytes,
    timeoutMs as int,
    busyWaitMs as int,
    retryMs as int,
    maxPageBytes as int,
    maxJobBytes as int,
    deadlineMs as int,
    maxPages as int,
    username as string,
    password as string,
    allowPlainAuth as bool
};

/**
 * A scanner, as `scanner` or `scannerWith` builds it. Nothing is sent until
 * it is used.
 *
 * @field origin {string} `scheme://host[:port]`, no trailing slash
 * @field base {string} the eSCL root, `origin` plus the path (`/eSCL` by default)
 * @field options {Options} the options, with every default filled in
 */
export def struct Scanner {
    origin as string,
    base as string,
    options as Options
};

/**
 * An inclusive range of resolutions in steps.
 *
 * @field min {int} the lowest, in dpi (0 when the input lists no range)
 * @field max {int} the highest, in dpi
 * @field step {int} the step from `min`, in dpi
 */
export def struct Range {
    min as int,
    max as int,
    step as int
};

/**
 * The range of one image adjustment, from its `<name>Support` element.
 *
 * @field min {int} the lowest value
 * @field max {int} the highest value
 * @field normal {int} the scanner's default
 * @field step {int} the step from `min`
 */
export def struct Adjustment {
    min as int,
    max as int,
    normal as int,
    step as int
};

/**
 * What one input can do: the platen, the feeder, or the feeder in duplex.
 *
 * @field source {string} `PLATEN` or `FEEDER`
 * @field duplex {bool} true for the feeder's two-sided capabilities
 * @field minWidth {int} the narrowest scan area, 1/300 inch
 * @field maxWidth {int} the widest scan area, 1/300 inch
 * @field minHeight {int} the shortest scan area, 1/300 inch
 * @field maxHeight {int} the tallest scan area, 1/300 inch
 * @field colorModes {list of string} e.g. `BlackAndWhite1`, `Grayscale8`, `RGB24`
 * @field formats {list of string} MIME types, e.g. `image/jpeg`, `application/pdf`
 * @field resolutions {list of int} the discrete resolutions offered with X = Y, ascending
 * @field resolutionRanges {list of Range} the continuous ranges offered with X = Y, one per setting profile that lists one
 * @field intents {list of string} e.g. `Document`, `Photo`, `TextAndGraphic`
 */
export def struct Input {
    source as string,
    duplex as bool,
    minWidth as int,
    maxWidth as int,
    minHeight as int,
    maxHeight as int,
    colorModes as list of string,
    formats as list of string,
    resolutions as list of int,
    resolutionRanges as list of Range,
    intents as list of string
};

/**
 * A scanner's `ScannerCapabilities` document.
 *
 * @field version {string} the eSCL version, e.g. `2.63`
 * @field makeAndModel {string} the device's name for itself
 * @field serialNumber {string} the serial number, `""` if not given
 * @field uuid {string} the device UUID, `""` if not given
 * @field adminUri {string} the device's web page, `""` if not given
 * @field iconUri {string} an icon URL, `""` if not given
 * @field inputs {list of Input} each input the device has
 * @field feederOptions {list of string} the feeder's `AdfOption`s, e.g. `DetectPaperLoaded`, `Duplex`
 * @field formatExt {bool} the device lists `DocumentFormatExt`, so a request names its format that way too
 * @field adjustments {map of string to Adjustment} the image adjustments offered, keyed by a name in `ADJUSTMENTS` (`Brightness`, ...)
 */
export def struct Capabilities {
    version as string,
    makeAndModel as string,
    serialNumber as string,
    uuid as string,
    adminUri as string,
    iconUri as string,
    inputs as list of Input,
    feederOptions as list of string,
    formatExt as bool,
    adjustments as map of string to Adjustment
};

/**
 * One job in a `Status`.
 *
 * @field uri {string} the job's path, e.g. `/eSCL/ScanJobs/1234`
 * @field uuid {string} the job UUID, `""` if not given
 * @field age {int} seconds since the job changed state
 * @field imagesCompleted {int} pages scanned so far
 * @field imagesToTransfer {int} pages scanned and not yet fetched
 * @field state {string} `Pending`, `Processing`, `Completed`, `Canceled` or `Aborted`
 * @field reasons {list of string} the job state reasons, e.g. `JobCompletedSuccessfully`
 */
export def struct JobInfo {
    uri as string,
    uuid as string,
    age as int,
    imagesCompleted as int,
    imagesToTransfer as int,
    state as string,
    reasons as list of string
};

/**
 * A scanner's `ScannerStatus` document.
 *
 * @field version {string} the eSCL version
 * @field state {string} `Idle`, `Processing`, `Testing`, `Stopped` or `Down`
 * @field adfState {string} the feeder's state, e.g. `ScannerAdfLoaded`, `ScannerAdfEmpty`, `ScannerAdfJam`; `""` if not given
 * @field jobs {list of JobInfo} the jobs the scanner remembers
 */
export def struct Status {
    version as string,
    state as string,
    adfState as string,
    jobs as list of JobInfo
};

/**
 * What to scan. `settings()` gives the defaults; change fields from there.
 * `x`, `y`, `width` and `height` place the scan area on the input; a
 * `width` or `height` of 0 reaches to the input's maximum.
 *
 * @field source {string} `PLATEN` or `FEEDER`
 * @field duplex {bool} scan both sides (the feeder only)
 * @field colorMode {string} one of the input's `colorModes`
 * @field resolution {int} dpi, the same for X and Y
 * @field format {string} one of the input's `formats`
 * @field intent {string} one of the input's `intents`, or `""` to send none
 * @field x {int} the left edge of the scan area, 1/300 inch
 * @field y {int} the top edge of the scan area, 1/300 inch
 * @field width {int} the scan area's width, 1/300 inch (0 = to the maximum)
 * @field height {int} the scan area's height, 1/300 inch (0 = to the maximum)
 * @field adjust {map of string to int} image adjustments to send, keyed by a name in `ADJUSTMENTS`; one not set keeps the scanner's default
 */
export def struct Settings {
    source as string,
    duplex as bool,
    colorMode as string,
    resolution as int,
    format as string,
    intent as string,
    x as int,
    y as int,
    width as int,
    height as int,
    adjust as map of string to int
};

/**
 * A scan job the scanner has accepted.
 *
 * @field scanner {Scanner} the scanner it runs on
 * @field url {string} the job's absolute URL, no trailing slash
 * @field pages {int} how many pages have been fetched; `scan` counts them, a caller of `nextPage` may too
 * @field bytes {int} how many bytes those pages hold
 */
export def struct Job {
    scanner as Scanner,
    url as string,
    pages as int,
    bytes as int
};

/**
 * One page from `nextPage`, or the end of the job.
 *
 * @field done {bool} true when the job has no more pages; the other fields are then empty
 * @field contentType {string} the page's MIME type, e.g. `image/jpeg`
 * @field data {bytes} the page, exactly as the scanner sent it
 */
export def struct Page {
    done as bool,
    contentType as string,
    data as bytes
};

/**
 * A scanner found by `discover`.
 *
 * @field name {string} the name it announces, e.g. `EPSON ES-C380W`
 * @field host {string} its mDNS host name, e.g. `EPSON1A2B3C.local`
 * @field address {string} its IPv4 address, `""` if the answer carried none
 * @field port {int} the eSCL port
 * @field secure {bool} announced as `_uscans` (HTTPS)
 * @field root {string} the eSCL root path, from TXT `rs` (`eSCL` when absent)
 * @field model {string} TXT `ty`, the make and model, `""` if absent
 * @field uuid {string} TXT `UUID`, `""` if absent
 * @field url {string} the address to give `scanner`: the IPv4 address when known, else the host name
 */
export def struct Found {
    name as string,
    host as string,
    address as string,
    port as int,
    secure as bool,
    root as string,
    model as string,
    uuid as string,
    url as string
};

/**
 * A page's `ScanImageInfo`.
 *
 * @field width {int} the image width in pixels
 * @field height {int} the image height in pixels
 * @field bytesPerLine {int} bytes per image row, 0 if not given
 */
export def struct ImageInfo {
    width as int,
    height as int,
    bytesPerLine as int
};

/**
 * An SRV answer.
 *
 * @field target {string} the host, lowercased
 * @field port {int} the port
 */
def struct Srv {
    target as string,
    port as int
};

/**
 * The mDNS answers gathered so far, keyed by lowercased owner name.
 *
 * @field ptrs {list of string} `service<TAB>instance` pairs
 * @field srvs {map of string to Srv} SRV records
 * @field txts {map of string to string} TXT records, as `key=value` lines with lowercased keys
 * @field addrs {map of string to string} IPv4 addresses
 * @field count {int} how many records have been kept, of every type
 */
def struct Records {
    ptrs as list of string,
    srvs as map of string to Srv,
    txts as map of string to string,
    addrs as map of string to string,
    count as int
};

/**
 * A name read from a DNS message.
 *
 * @field name {string} the dotted name, no trailing dot
 * @field next {int} the offset after the name where it is stored
 */
def struct NameAt {
    name as string,
    next as int
};

/**
 * A response read as raw bytes.
 *
 * @field status {int} the HTTP status
 * @field location {string} the `Location` header, `""` if none
 * @field contentType {string} the `Content-Type` header, `""` if none
 * @field retryAfterMs {int} a `Retry-After` given in seconds, in ms; -1 if none
 * @field body {bytes} the body
 */
def struct Reply {
    status as int,
    location as string,
    contentType as string,
    retryAfterMs as int,
    body as bytes
};

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
 * Text from a device, cut to 80 characters with anything unprintable as `?`,
 * fit for an error message.
 *
 * @param s {string} the text
 * @return {string} the text, clipped
 */
func clip(s as string) {
    def out as string init "";
    def n as int init 0;
    for (def c in strings.chars($s)) {
        if ($n == 80) {
            $out = $out + "...";
            break;
        }
        def cp as int init convert.toCodepoint($c);
        if ($cp < 32 or ($cp >= 127 and $cp < 160)) {
            $out = $out + "?";
        } else {
            $out = $out + $c;
        }
        $n = $n + 1;
    }
    return $out;
}

/**
 * Text from the network with every control character as `?`, so printing it
 * cannot drive a terminal. Unlike `clip` it keeps the whole text.
 *
 * @param s {string} the text
 * @return {string} the text, printable
 */
func printable(s as string) {
    for (def c in strings.chars($s)) {
        def cp as int init convert.toCodepoint($c);
        if ($cp < 32 or ($cp >= 127 and $cp < 160)) {
            return replaceControls($s);
        }
    }
    return $s;
}

/**
 * `printable`'s slow path.
 *
 * @param s {string} text holding a control character
 * @return {string} the text, each control character as `?`
 */
func replaceControls(s as string) {
    def out as list of string init [];
    for (def c in strings.chars($s)) {
        def cp as int init convert.toCodepoint($c);
        if ($cp < 32 or ($cp >= 127 and $cp < 160)) {
            $out[] = "?";
        } else {
            $out[] = $c;
        }
    }
    return strings.join($out, "");
}

/**
 * Text from a device or a caller, clipped as `clip` does and quoted.
 *
 * @param s {string} the text
 * @return {string} the text, quoted
 */
func shown(s as string) {
    return "\"" + clip($s) + "\"";
}

# --- addresses ------------------------------------------------------------

/**
 * Whether `s` is non-empty and every character is in `allowed`.
 *
 * @param s {string} the text
 * @param allowed {string} the allowed characters
 * @return {bool} whether it is
 */
func onlyOf(s as string, allowed as string) {
    if ($s == "") {
        return false;
    }
    for (def c in strings.chars($s)) {
        if (not strings.contains($allowed, $c)) {
            return false;
        }
    }
    return true;
}

/**
 * Parse a decimal number made only of digits.
 *
 * @param s {string} the text
 * @param what {string} what it is, for the error
 * @return {int} the number
 * @throws {Error} kind "escl" if `s` is not digits or is too long
 */
func digits(s as string, what as string) {
    if (not onlyOf($s, "0123456789") or len($s) > 9) {
        fail("{$what} must be a number, got " + shown($s));
    }
    return convert.toInt($s, 10);
}

/**
 * A path without leading and trailing slashes.
 *
 * @param path {string} the path
 * @return {string} the path, bare
 */
func bare(path as string) {
    def p as string init $path;
    while (strings.startsWith($p, "/")) {
        $p = strings.substring($p, 1);
    }
    while (strings.endsWith($p, "/")) {
        $p = strings.substring($p, 0, len($p) - 1);
    }
    return $p;
}

/**
 * The scanner at `address`, with default options. See `scannerWith`.
 *
 * @param address {string} `host`, `host:port`, or a URL
 * @return {Scanner} the scanner
 * @throws {Error} kind "escl" if the address is malformed
 * @example
 *   def hp as escl.Scanner init escl.scanner("192.168.1.40:8080");
 */
export func scanner(address as string) {
    def o as Options;
    return scannerWith($address, $o);
}

/**
 * The scanner at `address`: `host`, `host:port`, or a URL
 * `http://host[:port][/path]` or `https://...`. Without a scheme it is
 * `http`; without a path the eSCL root is `/eSCL`. A device announces its
 * port and root over mDNS (`_uscan._tcp`, TXT `rs`); many use port 80, some
 * (the HP LaserJet M28 series) 8080. An IPv6 host is written in brackets.
 *
 * @param address {string} where the scanner is
 * @param options {Options} the options (zero fields take the defaults)
 * @return {Scanner} the scanner
 * @throws {Error} kind "escl" if the address is malformed or an option is negative
 */
export func scannerWith(address as string, options as Options) {
    def rest as string init strings.trim($address);
    def scheme as string init "http";
    if (strings.startsWith(strings.lower($rest), "https://")) {
        $scheme = "https";
        $rest = strings.substring($rest, 8);
    } elseif (strings.startsWith(strings.lower($rest), "http://")) {
        $rest = strings.substring($rest, 7);
    } elseif (strings.contains($rest, "://")) {
        fail("the address must be http or https, got " + shown($address));
    }
    def path as string init "/eSCL";
    def hostPort as string init $rest;
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $hostPort = strings.substring($rest, 0, $slash);
        def p as string init bare(strings.substring($rest, $slash));
        if ($p != "") {
            $path = "/" + $p;
        }
    }
    for (def seg in strings.split(bare($path), "/")) {
        if ($seg == "." or $seg == ".." or not onlyOf($seg, LETTERS + "-._~")) {
            fail("the path must be plain segments, got " + shown($path));
        }
    }
    def host as string init $hostPort;
    def port as string init "";
    if (strings.startsWith($hostPort, "[")) {
        def close as int init strings.indexOf($hostPort, "]");
        if ($close < 0) {
            fail("unclosed [ in " + shown($address));
        }
        $host = strings.substring($hostPort, 0, $close + 1);
        def after as string init strings.substring($hostPort, $close + 1);
        if ($after != "") {
            if (not strings.startsWith($after, ":")) {
                fail("unexpected text after ] in " + shown($address));
            }
            $port = strings.substring($after, 1);
        }
        if (not onlyOf(strings.substring($host, 1, len($host) - 1), "0123456789abcdefABCDEF:.")) {
            fail("malformed IPv6 host in " + shown($address));
        }
    } else {
        def colon as int init strings.indexOf($hostPort, ":");
        if ($colon >= 0) {
            $host = strings.substring($hostPort, 0, $colon);
            $port = strings.substring($hostPort, $colon + 1);
        }
        if (not onlyOf($host, LETTERS + "-.")) {
            fail("malformed host in " + shown($address));
        }
    }
    def origin as string init $scheme + "://" + $host;
    if ($port != "" or strings.endsWith($hostPort, ":")) {
        def p as int init digits($port, "the port");
        if ($p < 1 or $p > 65535) {
            fail("the port must be 1 to 65535, got {$p}");
        }
        $origin = $origin + ":{$p}";
    }
    if ($options.username != "" or $options.password != "") {
        checkLogin($options, $scheme);
    }
    return Scanner{origin: $origin, base: $origin + $path, options: withDefaults($options)};
}

/**
 * Check a login before it is ever sent.
 *
 * @param o {Options} the options holding it
 * @param scheme {string} `http` or `https`
 * @throws {Error} kind "escl" if the login is malformed or would travel in the clear
 */
func checkLogin(o as Options, scheme as string) {
    if ($o.username == "") {
        fail("a password needs a username");
    }
    if (strings.contains($o.username, ":")) {
        fail("a username for HTTP Basic cannot contain ':'");
    }
    for (def c in strings.chars($o.username + $o.password)) {
        if (convert.toCodepoint($c) < 32 or convert.toCodepoint($c) == 127) {
            fail("the login contains a control character");
        }
    }
    if ($scheme == "http" and not $o.allowPlainAuth) {
        fail("refusing to send a login over plain http: use an https address, or set Options.allowPlainAuth");
    }
    if ($o.skipVerify and not $o.allowPlainAuth) {
        fail("refusing to send a login to an unverified certificate: pin the scanner's in Options.caCert, or set Options.allowPlainAuth");
    }
}

/**
 * The options with every zero field set to its default.
 *
 * @param o {Options} the options
 * @return {Options} the options, filled in
 * @throws {Error} kind "escl" if a field is negative
 */
func withDefaults(o as Options) {
    if ($o.timeoutMs < 0 or $o.busyWaitMs < 0 or $o.retryMs < 0 or $o.maxPageBytes < 0 or
        $o.maxPages < 0 or $o.maxJobBytes < 0 or $o.deadlineMs < 0) {
        fail("options must not be negative");
    }
    if ($o.timeoutMs == 0) {
        $o.timeoutMs = DEFAULT_TIMEOUT_MS;
    }
    if ($o.busyWaitMs == 0) {
        $o.busyWaitMs = DEFAULT_BUSY_WAIT_MS;
    }
    if ($o.retryMs == 0) {
        $o.retryMs = DEFAULT_RETRY_MS;
    }
    if ($o.maxPageBytes == 0) {
        $o.maxPageBytes = DEFAULT_MAX_PAGE_BYTES;
    }
    if ($o.maxPages == 0) {
        $o.maxPages = DEFAULT_MAX_PAGES;
    }
    if ($o.maxJobBytes == 0) {
        $o.maxJobBytes = DEFAULT_MAX_JOB_BYTES;
    }
    return $o;
}

/**
 * The absolute URL of a job from a `Location` header. A relative reference
 * resolves against the `ScanJobs` URL. An absolute one keeps only its path:
 * devices often name themselves by a host or port the client cannot reach,
 * so the scanner's own origin is used.
 *
 * @param s {Scanner} the scanner
 * @param location {string} the header
 * @return {string} the job URL, without a trailing slash
 * @throws {Error} kind "escl" if the header is empty or malformed
 */
func jobUrl(s as Scanner, location as string) {
    def loc as string init strings.trim($location);
    def lower as string init strings.lower($loc);
    if (strings.startsWith($lower, "http://") or strings.startsWith($lower, "https://")) {
        def at as int init strings.indexOf($loc, "/", strings.indexOf($loc, "//") + 2);
        if ($at < 0) {
            fail("the job location has no path: " + shown($location));
        }
        $loc = strings.substring($loc, $at);
    } elseif ($loc != "" and not strings.startsWith($loc, "/")) {
        $loc = strings.substring($s.base, len($s.origin)) + "/" + $loc;
    }
    $loc = bare($loc);
    if ($loc == "") {
        fail("the scanner gave no usable job location: " + shown($location));
    }
    for (def seg in strings.split($loc, "/")) {
        if ($seg == "." or $seg == ".." or not onlyOf($seg, LETTERS + "-._~%")) {
            fail("the scanner gave no usable job location: " + shown($location));
        }
    }
    return $s.origin + "/" + $loc;
}

# --- transport ------------------------------------------------------------

/**
 * Send one request.
 *
 * @param s {Scanner} the scanner
 * @param method {string} the HTTP method
 * @param url {string} the absolute URL
 * @param body {string} the request body, `""` for none
 * @param maxBytes {int} the largest response body accepted
 * @return {Reply} the response
 * @throws {Error} kind "escl" if the request fails
 */
func send(s as Scanner, method as string, url as string, body as string, maxBytes as int) {
    def headers as map of string to string init {"Accept": "*/*"};
    if ($s.options.username != "") {
        $headers["Authorization"] = http.basic($s.options.username, $s.options.password);
    }
    if ($body != "") {
        $headers["Content-Type"] = "text/xml";
    }
    def tls as http.TlsOptions init http.TlsOptions{
        skipVerify: $s.options.skipVerify,
        caCert: $s.options.caCert
    };
    def r as http.BytesResponse;
    try {
        if ($s.options.deadlineMs > 0) {
            $r = requestBefore($method, $url, $headers, $body, $s.options, $maxBytes, $tls);
        } else {
            $r = http.requestWithBytes(
                $method,
                $url,
                $headers,
                $body,
                $s.options.timeoutMs,
                $maxBytes,
                $tls);
        }
    } catch (e) {
        fail("{$method} {$url}: " + clip($e.message));
    }
    def location as string init "";
    if (maps.has($r.headers, "location")) {
        $location = $r.headers["location"];
    }
    def ctype as string init "";
    if (maps.has($r.headers, "content-type")) {
        $ctype = $r.headers["content-type"];
    }
    def retry as int init -1;
    if (maps.has($r.headers, "retry-after")) {
        def secs as string init strings.trim($r.headers["retry-after"]);
        # an HTTP date is not worth a clock comparison: retryMs applies
        if (onlyOf($secs, "0123456789") and len($secs) <= 4) {
            $retry = convert.toInt($secs, 10) * 1000;
        }
    }
    return Reply{
        status: $r.status,
        location: $location,
        contentType: $ctype,
        retryAfterMs: $retry,
        body: $r.body
    };
}

/**
 * One request that must finish within `deadlineMs`: it runs in a task the
 * caller stops waiting for at the deadline. The abandoned task ends by itself
 * when its socket next times out or the reply completes.
 *
 * @param method {string} the HTTP method
 * @param url {string} the absolute URL
 * @param headers {map of string to string} the headers
 * @param body {string} the request body
 * @param o {Options} the scanner's options
 * @param maxBytes {int} the largest response body accepted
 * @param tls {http.TlsOptions} the TLS options
 * @return {http.BytesResponse} the response
 * @throws {Error} kind "timeout" at the deadline, or whatever the request throws
 */
func requestBefore(
    method as string,
    url as string,
    headers as map of string to string,
    body as string,
    o as Options,
    maxBytes as int,
    tls as http.TlsOptions) {
    def t as task of http.BytesResponse init spawn {
        return http.requestWithBytes($method, $url, $headers, $body, $o.timeoutMs, $maxBytes, $tls);
    };
    def began as time.Time init time.now();
    try {
        return task.waitTimeout($t, $o.deadlineMs);
    } catch (e) {
        # a read timeout inside the task is kind "timeout" too; only the wait
        # running out reaches the deadline
        if ($e.kind == "timeout" and
            time.milliseconds(time.sub(time.now(), $began)) >= $o.deadlineMs) {
            task.cancel($t);
            task.discard($t);
            throw Error{
                kind: "timeout",
                message: "no complete reply within {$o.deadlineMs} ms (Options.deadlineMs)"
            };
        }
        throw $e;
    }
    return task.wait($t);
}

/**
 * Send a request, retrying while the scanner answers 503 (busy or not ready)
 * until `busyWaitMs` has passed. The pause is `retryMs`, or the reply's
 * `Retry-After` when that is longer, never past the deadline.
 *
 * @param s {Scanner} the scanner
 * @param method {string} the HTTP method
 * @param url {string} the absolute URL
 * @param body {string} the request body, `""` for none
 * @param maxBytes {int} the largest response body accepted
 * @return {Reply} the first response that is not a 503, or the last 503
 * @throws {Error} kind "escl" if a request fails
 */
func sendPatiently(s as Scanner, method as string, url as string, body as string, maxBytes as int) {
    def began as time.Time init time.now();
    while (true) {
        def r as Reply init send($s, $method, $url, $body, $maxBytes);
        if ($r.status != 503) {
            return $r;
        }
        def left as int init $s.options.busyWaitMs - time.milliseconds(time.sub(time.now(), $began));
        if ($left <= 0) {
            return $r;
        }
        def pause as int init $s.options.retryMs;
        if ($r.retryAfterMs > $pause) {
            $pause = $r.retryAfterMs;
        }
        if ($pause > $left) {
            $pause = $left;
        }
        time.sleep(time.fromMilliseconds($pause));
    }
}

/**
 * A reply body as text.
 *
 * @param r {Reply} the reply
 * @param what {string} what was asked for, for the error
 * @return {string} the body
 * @throws {Error} kind "escl" if it is not UTF-8
 */
func textOf(r as Reply, what as string) {
    def s as string init "";
    try {
        $s = convert.stringFromBytes("utf-8", $r.body);
    } catch (e) {
        fail("{$what}: the reply is not UTF-8 text");
    }
    return $s;
}

/**
 * The first line of a short plain-text reply, for an error message.
 *
 * @param r {Reply} the reply
 * @return {string} `""`, or `": "` and the quoted text
 */
func detail(r as Reply) {
    if (len($r.body) == 0 or len($r.body) > 4096) {
        return "";
    }
    def s as string init "";
    try {
        $s = strings.trim(convert.stringFromBytes("utf-8", $r.body));
    } catch (e) {
        return "";
    }
    if ($s == "" or strings.startsWith($s, "<")) {
        return "";
    }
    return ": " + shown(strings.split($s, "\n")[0]);
}

/**
 * An HTTP status a request did not expect, explained where the deck can.
 *
 * @param s {Scanner} the scanner
 * @param r {Reply} the reply
 * @return {string} `HTTP <code>`, a hint, and the reply's first line
 */
func refusal(s as Scanner, r as Reply) {
    def out as string init "HTTP {$r.status}";
    if ($r.status == 401 and $s.options.username == "") {
        $out = $out + " (the scanner wants a login: Options.username / password)";
    } elseif (($r.status == 401 or $r.status == 403) and $s.options.username != "") {
        $out = $out + " (the login was refused)";
    }
    return $out + detail($r);
}

/**
 * Decode an XML document and check its root element.
 *
 * @param text {string} the XML
 * @param name {string} the expected root element's local name
 * @return {xml.Value} the root element
 * @throws {Error} kind "escl" if it is malformed or another document
 */
func decodeAs(text as string, name as string) {
    def root as xml.Value;
    try {
        $root = xml.decode($text);
    } catch (e) {
        fail("{$name}: malformed XML: {$e.message}");
    }
    if (local($root) != $name) {
        fail("expected a {$name} document, got <" + clip(xml.tag($root)) + ">");
    }
    checkElements($root, $name);
    return $root;
}

/**
 * Refuse a document with more elements than eSCL ever needs, so a hostile
 * one cannot make the parse slow. Walks with a list, not recursion.
 *
 * @param root {xml.Value} the root element
 * @param name {string} the document, for the error
 * @throws {Error} kind "escl" past `MAX_ELEMENTS` elements
 */
func checkElements(root as xml.Value, name as string) {
    def pending as list of xml.Value init [$root];
    def seen as int init 0;
    while (len($pending) > 0) {
        def node as xml.Value init $pending[len($pending) - 1];
        $pending = $pending[..len($pending) - 1];
        $seen = $seen + 1;
        if ($seen > MAX_ELEMENTS) {
            fail("{$name} has more than {MAX_ELEMENTS} elements; not an eSCL document");
        }
        for (def c in xml.children($node)) {
            $pending[] = $c;
        }
    }
}

/**
 * GET an XML document and decode it.
 *
 * @param s {Scanner} the scanner
 * @param name {string} the resource and its root element, e.g. `ScannerStatus`
 * @return {xml.Value} the root element
 * @throws {Error} kind "escl" if the request fails or the reply is not that document
 */
func document(s as Scanner, name as string) {
    def r as Reply init sendPatiently($s, "GET", $s.base + "/" + $name, "", MAX_DOC_BYTES);
    if ($r.status != 200) {
        fail("GET {$name}: " + refusal($s, $r));
    }
    return decodeAs(textOf($r, $name), $name);
}

# --- reading documents ----------------------------------------------------

/**
 * An element's name without its prefix.
 *
 * @param node {xml.Value} the element
 * @return {string} the local name
 */
func local(node as xml.Value) {
    def tag as string init xml.tag($node);
    def colon as int init strings.indexOf($tag, ":");
    if ($colon < 0) {
        return $tag;
    }
    return strings.substring($tag, $colon + 1);
}

/**
 * The element children with this local name.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {list of xml.Value} the children, in document order
 */
func kids(node as xml.Value, name as string) {
    def out as list of xml.Value init [];
    for (def c in xml.children($node)) {
        if (local($c) == $name) {
            $out[] = $c;
        }
    }
    return $out;
}

/**
 * The children named `inner` of the children named `outer`.
 *
 * @param node {xml.Value} the element
 * @param outer {string} the local name one level down
 * @param inner {string} the local name two levels down
 * @return {list of xml.Value} the grandchildren, in document order
 */
func grandkids(node as xml.Value, outer as string, inner as string) {
    def out as list of xml.Value init [];
    for (def o in kids($node, $outer)) {
        for (def i in kids($o, $inner)) {
            $out[] = $i;
        }
    }
    return $out;
}

/**
 * Whether the element has a child with this local name.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {bool} whether it has
 */
func hasKid(node as xml.Value, name as string) {
    return len(kids($node, $name)) > 0;
}

/**
 * The first child with this local name.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {xml.Value} the child
 * @throws {Error} kind "escl" if there is none
 */
func kid(node as xml.Value, name as string) {
    def found as list of xml.Value init kids($node, $name);
    if (len($found) == 0) {
        fail("<" + clip(local($node)) + "> has no <{$name}>");
    }
    return $found[0];
}

/**
 * The trimmed text of the first child with this local name, control
 * characters as `?`.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {string} the text, `""` if there is no such child
 */
func textAt(node as xml.Value, name as string) {
    def found as list of xml.Value init kids($node, $name);
    if (len($found) == 0) {
        return "";
    }
    return printable(strings.trim(xml.text($found[0])));
}

/**
 * The number in the first child with this local name.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @param absent {int} the value when there is no such child
 * @return {int} the number
 * @throws {Error} kind "escl" if the text is not a number
 */
func intAt(node as xml.Value, name as string, absent as int) {
    if (not hasKid($node, $name)) {
        return $absent;
    }
    return digits(textAt($node, $name), "<{$name}>");
}

/**
 * The trimmed texts of every child with this local name, each once, control
 * characters as `?`.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {list of string} the texts, in document order
 */
func textsAt(node as xml.Value, name as string) {
    def texts as list of string init [];
    for (def c in kids($node, $name)) {
        def t as string init printable(strings.trim(xml.text($c)));
        if ($t != "") {
            $texts[] = $t;
        }
    }
    return union([], $texts);
}

/**
 * Add the strings of `more` that `into` lacks, in linear time.
 *
 * @param into {list of string} the list
 * @param more {list of string} what to add
 * @return {list of string} the union, in first-seen order
 * @throws {Error} kind "escl" past `MAX_ITEMS` entries
 */
func union(into as list of string, more as list of string) {
    def seen as map of string to bool init {};
    for (def t in $into) {
        $seen[$t] = true;
    }
    for (def t in $more) {
        if (not maps.has($seen, $t)) {
            $seen[$t] = true;
            $into[] = $t;
        }
    }
    if (len($into) > MAX_ITEMS) {
        fail("a list has more than {MAX_ITEMS} entries; not an eSCL document");
    }
    return $into;
}

/**
 * A `ResolutionRange`, kept only where the X and Y ranges agree.
 *
 * @param rr {xml.Value} the element
 * @return {Range} the range, `min` 0 if unusable
 * @throws {Error} kind "escl" if a number is malformed
 */
func readRange(rr as xml.Value) {
    def none as Range init Range{min: 0, max: 0, step: 0};
    if (not hasKid($rr, "XResolutionRange") or not hasKid($rr, "YResolutionRange")) {
        return $none;
    }
    def x as xml.Value init kid($rr, "XResolutionRange");
    def y as xml.Value init kid($rr, "YResolutionRange");
    def r as Range init Range{
        min: intAt($x, "Min", 0),
        max: intAt($x, "Max", 0),
        step: intAt($x, "Step", 1)
    };
    if ($r.min <= 0 or $r.max < $r.min or $r.step <= 0 or intAt($y, "Min", 0) != $r.min or
        intAt($y, "Max", 0) != $r.max or intAt($y, "Step", 1) != $r.step) {
        return $none;
    }
    return $r;
}

/**
 * The discrete resolutions in a `SupportedResolutions` element that are the
 * same for X and Y.
 *
 * @param sr {xml.Value} the element
 * @return {list of int} the resolutions, in document order
 * @throws {Error} kind "escl" if a number is malformed
 */
func discrete(sr as xml.Value) {
    def out as list of int init [];
    for (def r in grandkids($sr, "DiscreteResolutions", "DiscreteResolution")) {
        def x as int init intAt($r, "XResolution", 0);
        if ($x > 0 and $x == intAt($r, "YResolution", 0)) {
            $out[] = $x;
        }
    }
    return $out;
}

/**
 * One input's capabilities from its `PlatenInputCaps`, `AdfSimplexInputCaps`
 * or `AdfDuplexInputCaps` element. The setting profiles are merged.
 *
 * @param caps {xml.Value} the element
 * @param source {string} `PLATEN` or `FEEDER`
 * @param duplex {bool} whether these are duplex capabilities
 * @return {Input} the input
 * @throws {Error} kind "escl" if a size is missing or a number is malformed
 */
func readInput(caps as xml.Value, source as string, duplex as bool) {
    def in2 as Input init Input{
        source: $source,
        duplex: $duplex,
        minWidth: intAt($caps, "MinWidth", 0),
        maxWidth: intAt($caps, "MaxWidth", 0),
        minHeight: intAt($caps, "MinHeight", 0),
        maxHeight: intAt($caps, "MaxHeight", 0),
        colorModes: [],
        formats: [],
        resolutions: [],
        resolutionRanges: [],
        intents: []
    };
    if ($in2.maxWidth == 0 or $in2.maxHeight == 0) {
        fail("the {$source} capabilities lack MaxWidth or MaxHeight");
    }
    for (def p in grandkids($caps, "SettingProfiles", "SettingProfile")) {
        for (def modes in kids($p, "ColorModes")) {
            $in2.colorModes = union($in2.colorModes, textsAt($modes, "ColorMode"));
        }
        for (def formats in kids($p, "DocumentFormats")) {
            $in2.formats = union($in2.formats, textsAt($formats, "DocumentFormat"));
            $in2.formats = union($in2.formats, textsAt($formats, "DocumentFormatExt"));
        }
        for (def sr in kids($p, "SupportedResolutions")) {
            for (def x in discrete($sr)) {
                if (not lists.contains($in2.resolutions, $x)) {
                    $in2.resolutions[] = $x;
                }
            }
            for (def rr in kids($sr, "ResolutionRange")) {
                def r as Range init readRange($rr);
                if ($r.min > 0 and not lists.contains($in2.resolutionRanges, $r)) {
                    $in2.resolutionRanges[] = $r;
                }
            }
        }
    }
    for (def si in kids($caps, "SupportedIntents")) {
        $in2.intents = union($in2.intents, textsAt($si, "Intent"));
        $in2.intents = union($in2.intents, textsAt($si, "SupportedIntent"));
    }
    if (len($in2.resolutions) > MAX_ITEMS or len($in2.resolutionRanges) > MAX_ITEMS) {
        fail("the {$source} capabilities list more than {MAX_ITEMS} resolutions");
    }
    $in2.resolutions = lists.sort($in2.resolutions);
    return $in2;
}

/**
 * The elements with this local name at or below `node`, depth-first, at most
 * `depth` levels down.
 *
 * @param node {xml.Value} where to look
 * @param name {string} the local name
 * @param depth {int} how many levels to descend
 * @return {list of xml.Value} the elements, in document order
 */
func findAll(node as xml.Value, name as string, depth as int) {
    def out as list of xml.Value init [];
    if (local($node) == $name) {
        $out[] = $node;
    }
    if ($depth > 0) {
        for (def c in xml.children($node)) {
            for (def hit in findAll($c, $name, $depth - 1)) {
                $out[] = $hit;
            }
        }
    }
    return $out;
}

/**
 * One adjustment's range. One the deck cannot use comes back with `step` 0.
 *
 * @param el {xml.Value} the `<name>Support` element
 * @return {Adjustment} the range
 * @throws {Error} kind "escl" if a number is malformed
 */
func readAdjustment(el as xml.Value) {
    def a as Adjustment init Adjustment{
        min: signedAt($el, "Min"),
        max: signedAt($el, "Max"),
        normal: 0,
        step: 1
    };
    if (hasKid($el, "Step")) {
        $a.step = signedAt($el, "Step");
    }
    $a.normal = $a.min + ($a.max - $a.min) // 2;
    if (hasKid($el, "Normal")) {
        $a.normal = signedAt($el, "Normal");
    }
    if (not hasKid($el, "Min") or not hasKid($el, "Max") or $a.max < $a.min or $a.step <= 0) {
        $a.step = 0;
    }
    return $a;
}

/**
 * A number that may be negative, in the first child with this local name.
 *
 * @param node {xml.Value} the parent
 * @param name {string} the local name
 * @return {int} the number, 0 if there is no such child
 * @throws {Error} kind "escl" if the text is not a number
 */
func signedAt(node as xml.Value, name as string) {
    if (not hasKid($node, $name)) {
        return 0;
    }
    def t as string init textAt($node, $name);
    if (strings.startsWith($t, "-")) {
        return -digits(strings.substring($t, 1), "<{$name}>");
    }
    return digits($t, "<{$name}>");
}

/**
 * Whether an input's setting profiles name a format as `DocumentFormatExt`.
 *
 * @param caps {xml.Value} the input's capabilities element
 * @return {bool} whether they do
 */
func listsFormatExt(caps as xml.Value) {
    for (def p in grandkids($caps, "SettingProfiles", "SettingProfile")) {
        for (def formats in kids($p, "DocumentFormats")) {
            if (hasKid($formats, "DocumentFormatExt")) {
                return true;
            }
        }
    }
    return false;
}

/**
 * The capabilities in a decoded `ScannerCapabilities` element.
 *
 * @param root {xml.Value} the root element
 * @return {Capabilities} the capabilities
 * @throws {Error} kind "escl" if it describes no input or a number is malformed
 */
func readCapabilities(root as xml.Value) {
    def c as Capabilities init Capabilities{
        version: textAt($root, "Version"),
        makeAndModel: textAt($root, "MakeAndModel"),
        serialNumber: textAt($root, "SerialNumber"),
        uuid: textAt($root, "UUID"),
        adminUri: textAt($root, "AdminURI"),
        iconUri: textAt($root, "IconURI"),
        inputs: [],
        feederOptions: [],
        formatExt: false,
        adjustments: {}
    };
    for (def platen in kids($root, "Platen")) {
        for (def pc in kids($platen, "PlatenInputCaps")) {
            $c.inputs[] = readInput($pc, PLATEN, false);
            $c.formatExt = $c.formatExt or listsFormatExt($pc);
        }
    }
    for (def adf in kids($root, "Adf")) {
        for (def opts in kids($adf, "AdfOptions")) {
            $c.feederOptions = union($c.feederOptions, textsAt($opts, "AdfOption"));
        }
        def simplex as list of xml.Value init kids($adf, "AdfSimplexInputCaps");
        for (def sc in $simplex) {
            $c.inputs[] = readInput($sc, FEEDER, false);
            $c.formatExt = $c.formatExt or listsFormatExt($sc);
        }
        def duplex as list of xml.Value init kids($adf, "AdfDuplexInputCaps");
        for (def dc in $duplex) {
            $c.inputs[] = readInput($dc, FEEDER, true);
            $c.formatExt = $c.formatExt or listsFormatExt($dc);
        }
        # Some devices list the Duplex option but only simplex capabilities,
        # which then hold for both sides.
        if (len($duplex) == 0 and len($simplex) > 0 and lists.contains($c.feederOptions, "Duplex")) {
            $c.inputs[] = readInput($simplex[0], FEEDER, true);
        }
    }
    if (len($c.inputs) == 0) {
        fail("ScannerCapabilities describes no platen and no feeder");
    }
    for (def name in ADJUSTMENTS) {
        def found as list of xml.Value init findAll($root, $name + "Support", 6);
        if (len($found) > 0) {
            def a as Adjustment init readAdjustment($found[0]);
            if ($a.step > 0) {
                $c.adjustments[$name] = $a;
            }
        }
    }
    return $c;
}

/**
 * The status in a decoded `ScannerStatus` element.
 *
 * @param root {xml.Value} the root element
 * @return {Status} the status
 * @throws {Error} kind "escl" if it has no state or a number is malformed
 */
func readStatus(root as xml.Value) {
    def st as Status init Status{
        version: textAt($root, "Version"),
        state: textAt($root, "State"),
        adfState: textAt($root, "AdfState"),
        jobs: []
    };
    if ($st.state == "") {
        fail("ScannerStatus has no State");
    }
    for (def jobs in kids($root, "Jobs")) {
        for (def j in kids($jobs, "JobInfo")) {
            def reasons as list of string init [];
            for (def rs in kids($j, "JobStateReasons")) {
                $reasons = union($reasons, textsAt($rs, "JobStateReason"));
            }
            $st.jobs[] = JobInfo{
                uri: textAt($j, "JobUri"),
                uuid: textAt($j, "JobUuid"),
                age: intAt($j, "Age", 0),
                imagesCompleted: intAt($j, "ImagesCompleted", 0),
                imagesToTransfer: intAt($j, "ImagesToTransfer", 0),
                state: textAt($j, "JobState"),
                reasons: $reasons
            };
        }
    }
    return $st;
}

/**
 * Parse a `ScannerCapabilities` document, as `capabilities` reads it from a
 * scanner.
 *
 * @param text {string} the XML
 * @return {Capabilities} the capabilities
 * @throws {Error} kind "escl" if it is not a usable capabilities document
 */
export func parseCapabilities(text as string) {
    return readCapabilities(decodeAs($text, "ScannerCapabilities"));
}

/**
 * Parse a `ScannerStatus` document, as `status` reads it from a scanner.
 *
 * @param text {string} the XML
 * @return {Status} the status
 * @throws {Error} kind "escl" if it is not a usable status document
 */
export func parseStatus(text as string) {
    return readStatus(decodeAs($text, "ScannerStatus"));
}

/**
 * Read the scanner's capabilities.
 *
 * @param s {Scanner} the scanner
 * @return {Capabilities} what it can do
 * @throws {Error} kind "escl" if the request fails or the reply is unusable
 */
export func capabilities(s as Scanner) {
    return readCapabilities(document($s, "ScannerCapabilities"));
}

/**
 * Read the scanner's status.
 *
 * @param s {Scanner} the scanner
 * @return {Status} its state, the feeder's and its jobs
 * @throws {Error} kind "escl" if the request fails or the reply is unusable
 */
export func status(s as Scanner) {
    return readStatus(document($s, "ScannerStatus"));
}

# --- settings -------------------------------------------------------------

/**
 * The default settings: the platen, colour (`RGB24`), 300 dpi, JPEG, the
 * whole scan area, no intent.
 *
 * @return {Settings} the defaults
 */
export func settings() {
    return Settings{
        source: PLATEN,
        duplex: false,
        colorMode: "RGB24",
        resolution: 300,
        format: "image/jpeg",
        intent: "",
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        adjust: {}
    };
}

/**
 * Convert millimetres to the protocol's 1/300 inch, rounded.
 *
 * @param mm {float} a length in millimetres, 0 to 10000
 * @return {int} the length in 1/300 inch
 * @throws {Error} kind "escl" if the length is out of range
 * @example
 *   escl.fromMm(210.0);   # 2480, the width of A4
 */
export func fromMm(mm as float) {
    if ($mm < 0.0 or $mm > 10000.0) {
        fail("a length must be 0 to 10000 mm, got {$mm}");
    }
    return math.round($mm * 300.0 / 25.4);
}

/**
 * The input the settings select.
 *
 * @param caps {Capabilities} the scanner's capabilities
 * @param st {Settings} the settings
 * @return {Input} the input
 * @throws {Error} kind "escl" if the scanner has no such input
 */
func inputFor(caps as Capabilities, st as Settings) {
    if ($st.source != PLATEN and $st.source != FEEDER) {
        fail("source must be escl.PLATEN or escl.FEEDER, got " + shown($st.source));
    }
    if ($st.duplex and $st.source != FEEDER) {
        fail("duplex needs the feeder");
    }
    for (def i in $caps.inputs) {
        if ($i.source == $st.source and $i.duplex == $st.duplex) {
            return $i;
        }
    }
    if ($st.duplex) {
        fail("the scanner has no duplex feeder");
    }
    if ($st.source == FEEDER) {
        fail("the scanner has no feeder");
    }
    fail("the scanner has no platen");
    return $caps.inputs[0];
}

/**
 * Whether the input offers a resolution.
 *
 * @param in2 {Input} the input
 * @param dpi {int} the resolution
 * @return {bool} whether it does
 */
func offers(in2 as Input, dpi as int) {
    if (lists.contains($in2.resolutions, $dpi)) {
        return true;
    }
    for (def r in $in2.resolutionRanges) {
        if ($dpi >= $r.min and $dpi <= $r.max and ($dpi - $r.min) % $r.step == 0) {
            return true;
        }
    }
    return false;
}

/**
 * What an input offers, for an error message.
 *
 * @param xs {list of string} the offers
 * @return {string} them, comma-separated, or `none`
 */
func listed(xs as list of string) {
    if (len($xs) == 0) {
        return "none";
    }
    return clip(strings.join($xs, ", "));
}

/**
 * Check settings against the capabilities and fill in the scan area. Every
 * problem is an error here, before the scanner sees a request.
 *
 * @param caps {Capabilities} the scanner's capabilities
 * @param st {Settings} the settings
 * @return {Settings} the settings with `width` and `height` resolved
 * @throws {Error} kind "escl" naming the first setting the scanner does not offer
 */
export func check(caps as Capabilities, st as Settings) {
    def in2 as Input init inputFor($caps, $st);
    if (not lists.contains($in2.colorModes, $st.colorMode)) {
        fail("color mode " + shown($st.colorMode) + " not offered; the scanner has " +
            listed($in2.colorModes));
    }
    if (not lists.contains($in2.formats, $st.format)) {
        fail("format " + shown($st.format) + " not offered; the scanner has " + listed($in2.formats));
    }
    if (not offers($in2, $st.resolution)) {
        def offered as list of string init [];
        for (def r in $in2.resolutions) {
            $offered[] = convert.toString($r);
        }
        for (def rr in $in2.resolutionRanges) {
            $offered[] = "{$rr.min}-{$rr.max} in steps of {$rr.step}";
        }
        fail("{$st.resolution} dpi not offered; the scanner has " + listed($offered));
    }
    if ($st.intent != "" and not lists.contains($in2.intents, $st.intent)) {
        fail("intent " + shown($st.intent) + " not offered; the scanner has " + listed($in2.intents));
    }
    for (def name in $st.adjust) {
        checkAdjustment($caps, $name, $st.adjust[$name]);
    }
    if ($st.x < 0 or $st.y < 0 or $st.width < 0 or $st.height < 0) {
        fail("the scan area must not be negative");
    }
    if ($st.width == 0) {
        $st.width = $in2.maxWidth - $st.x;
    }
    if ($st.height == 0) {
        $st.height = $in2.maxHeight - $st.y;
    }
    if ($st.width < $in2.minWidth or $st.width <= 0 or $st.width > $in2.maxWidth - $st.x) {
        fail("the scan area must be {$in2.minWidth} to {$in2.maxWidth} wide (1/300 inch) and fit, got x {$st.x}, width {$st.width}");
    }
    if ($st.height < $in2.minHeight or $st.height <= 0 or $st.height > $in2.maxHeight - $st.y) {
        fail("the scan area must be {$in2.minHeight} to {$in2.maxHeight} high (1/300 inch) and fit, got y {$st.y}, height {$st.height}");
    }
    return $st;
}

/**
 * Check one requested adjustment against what the scanner offers.
 *
 * @param caps {Capabilities} the scanner's capabilities
 * @param name {string} the adjustment
 * @param value {int} the requested value
 * @throws {Error} kind "escl" if it is unknown, not offered, or out of range
 */
func checkAdjustment(caps as Capabilities, name as string, value as int) {
    if (not lists.contains(ADJUSTMENTS, $name)) {
        fail("unknown adjustment " + shown($name) + "; the adjustments are " +
            strings.join(ADJUSTMENTS, ", "));
    }
    if (not maps.has($caps.adjustments, $name)) {
        fail(strings.lower($name) + " is not adjustable on this scanner");
    }
    def a as Adjustment init $caps.adjustments[$name];
    if ($value < $a.min or $value > $a.max or ($value - $a.min) % $a.step != 0) {
        fail(strings.lower($name) +
            " must be {$a.min} to {$a.max} in steps of {$a.step} (normal {$a.normal}), got {$value}");
    }
}

/**
 * Escape text for XML content.
 *
 * @param s {string} the text
 * @return {string} the escaped text
 */
func esc(s as string) {
    return strings.replace(
        strings.replace(strings.replace($s, "&", "&amp;"), "<", "&lt;"),
        ">",
        "&gt;");
}

/**
 * The `ScanSettings` document a job is created with. The settings are
 * checked first, as `check` does.
 *
 * @param caps {Capabilities} the scanner's capabilities
 * @param st {Settings} the settings
 * @return {string} the XML
 * @throws {Error} kind "escl" as `check`
 */
export func settingsXml(caps as Capabilities, st as Settings) {
    def s2 as Settings init check($caps, $st);
    def version as string init $caps.version;
    if (not onlyOf($version, "0123456789.")) {
        $version = "2.0";
    }
    def x as string init "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    $x = $x + "<scan:ScanSettings xmlns:scan=\"" + SCAN_NS + "\" xmlns:pwg=\"" + PWG_NS + "\">\n";
    $x = $x + "  <pwg:Version>{$version}</pwg:Version>\n";
    if ($s2.intent != "") {
        $x = $x + "  <scan:Intent>" + esc($s2.intent) + "</scan:Intent>\n";
    }
    $x = $x + "  <pwg:ScanRegions pwg:MustHonor=\"true\">\n";
    $x = $x + "    <pwg:ScanRegion>\n";
    $x = $x +
        "      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>\n";
    $x = $x + "      <pwg:XOffset>{$s2.x}</pwg:XOffset>\n";
    $x = $x + "      <pwg:YOffset>{$s2.y}</pwg:YOffset>\n";
    $x = $x + "      <pwg:Width>{$s2.width}</pwg:Width>\n";
    $x = $x + "      <pwg:Height>{$s2.height}</pwg:Height>\n";
    $x = $x + "    </pwg:ScanRegion>\n";
    $x = $x + "  </pwg:ScanRegions>\n";
    $x = $x + "  <pwg:DocumentFormat>" + esc($s2.format) + "</pwg:DocumentFormat>\n";
    if ($caps.formatExt) {
        $x = $x + "  <scan:DocumentFormatExt>" + esc($s2.format) + "</scan:DocumentFormatExt>\n";
    }
    $x = $x + "  <pwg:InputSource>" + esc($s2.source) + "</pwg:InputSource>\n";
    $x = $x + "  <scan:ColorMode>" + esc($s2.colorMode) + "</scan:ColorMode>\n";
    $x = $x + "  <scan:XResolution>{$s2.resolution}</scan:XResolution>\n";
    $x = $x + "  <scan:YResolution>{$s2.resolution}</scan:YResolution>\n";
    if ($s2.source == FEEDER) {
        $x = $x + "  <scan:Duplex>{$s2.duplex}</scan:Duplex>\n";
    }
    for (def name in ADJUSTMENTS) {
        if (maps.has($s2.adjust, $name)) {
            def v as int init $s2.adjust[$name];
            $x = $x + "  <scan:{$name}>{$v}</scan:{$name}>\n";
        }
    }
    return $x + "</scan:ScanSettings>\n";
}

# --- jobs -----------------------------------------------------------------

/**
 * Create a scan job. The settings are checked against `caps` first; a feeder
 * job also checks that the feeder is not reported empty. A busy scanner (503)
 * is retried for `busyWaitMs`.
 *
 * @param s {Scanner} the scanner
 * @param caps {Capabilities} its capabilities, from `capabilities`
 * @param st {Settings} what to scan
 * @return {Job} the job, ready for `nextPage`
 * @throws {Error} kind "escl" if the settings are not offered, the feeder is empty, or the scanner refuses the job
 */
export func start(s as Scanner, caps as Capabilities, st as Settings) {
    def body as string init settingsXml($caps, $st);
    if ($st.source == FEEDER) {
        def now as Status init status($s);
        if ($now.adfState == "ScannerAdfEmpty") {
            fail("the feeder is empty");
        }
    }
    def r as Reply init sendPatiently($s, "POST", $s.base + "/ScanJobs", $body, MAX_DOC_BYTES);
    if ($r.status == 409) {
        fail("the scanner refused the job (HTTP 409): it is busy, or the input is empty" +
            detail($r));
    }
    if ($r.status == 503) {
        fail("the scanner stayed busy for {$s.options.busyWaitMs} ms");
    }
    if ($r.status != 201 and $r.status != 200) {
        fail("the scanner refused the job: " + refusal($s, $r));
    }
    return Job{scanner: $s, url: jobUrl($s, $r.location), pages: 0, bytes: 0};
}

/**
 * A MIME type without parameters, lowercased.
 *
 * @param contentType {string} a `Content-Type` value
 * @return {string} the type
 */
func mediaType(contentType as string) {
    def t as string init $contentType;
    def semi as int init strings.indexOf($t, ";");
    if ($semi >= 0) {
        $t = strings.substring($t, 0, $semi);
    }
    return strings.lower(strings.trim($t));
}

/**
 * Fetch the job's next page. A 404 means there are no more: the page comes
 * back with `done` true. A page that is not ready (503) is waited for, up to
 * `busyWaitMs`.
 *
 * @param job {Job} the job
 * @return {Page} the page, or `done`
 * @throws {Error} kind "escl" if the request fails or the scanner answers otherwise
 */
export func nextPage(job as Job) {
    def r as Reply init sendPatiently(
        $job.scanner,
        "GET",
        $job.url + "/NextDocument",
        "",
        $job.scanner.options.maxPageBytes);
    def n as int init $job.pages + 1;
    if ($r.status == 404) {
        def none as bytes;
        return Page{done: true, contentType: "", data: $none};
    }
    if ($r.status == 503) {
        fail("page {$n} was not ready within {$job.scanner.options.busyWaitMs} ms");
    }
    if ($r.status != 200) {
        fail("page {$n}: " + refusal($job.scanner, $r));
    }
    if (len($r.body) == 0) {
        fail("page {$n} is empty");
    }
    return Page{done: false, contentType: mediaType($r.contentType), data: $r.body};
}

/**
 * Cancel a job and let the scanner forget it. A job the scanner no longer
 * knows (404) counts as cancelled.
 *
 * @param job {Job} the job
 * @throws {Error} kind "escl" if the scanner refuses
 */
export func cancel(job as Job) {
    def r as Reply init send($job.scanner, "DELETE", $job.url, "", MAX_DOC_BYTES);
    if ($r.status != 200 and $r.status != 204 and $r.status != 404) {
        fail("cancel: " + refusal($job.scanner, $r));
    }
}

/**
 * Cancel a job after a failure. The error that led here is the one to
 * report; a failure to cancel is added to its message.
 *
 * @param job {Job} the job
 * @param err {Error} the error that stopped the job
 * @return {Error} the error to throw
 */
func abandon(job as Job, err as Error) {
    try {
        cancel($job);
    } catch (e) {
        $err.message = $err.message + "; cancelling the job failed too: " + $e.message;
    }
    return $err;
}

/**
 * Check how a job ended, from the scanner's status. A job the status no
 * longer lists is taken as finished.
 *
 * @param job {Job} the job, after its last page, `pages` counted
 * @throws {Error} kind "escl" if the scanner aborted or cancelled it, or it gave no pages
 */
func finished(job as Job) {
    def path as string init bare(strings.substring($job.url, len($job.scanner.origin)));
    def st as Status init status($job.scanner);
    for (def j in $st.jobs) {
        def same as bool init $j.uri != "" and bare($j.uri) == $path;
        if (not $same and $j.uuid != "") {
            $same = strings.endsWith($path, "/" + $j.uuid);
        }
        if ($same and ($j.state == "Aborted" or $j.state == "Canceled")) {
            def why as string init "";
            if (len($j.reasons) > 0) {
                $why = " (" + clip(strings.join($j.reasons, ", ")) + ")";
            }
            if ($st.adfState != "" and $st.adfState != "ScannerAdfEmpty" and
                $st.adfState != "ScannerAdfLoaded") {
                $why = $why + ", feeder: " + clip($st.adfState);
            }
            fail("the scanner " + strings.lower($j.state) + " the job after {$job.pages} page(s)" +
                $why);
        }
    }
    if ($job.pages == 0) {
        fail("the scanner returned no pages");
    }
}

/**
 * Scan: read the capabilities, check the settings, run the job and return
 * every page. A feeder job gives a page per side scanned. If anything fails
 * the job is cancelled; a job the scanner aborts (a paper jam) is an error.
 *
 * @param s {Scanner} the scanner
 * @param st {Settings} what to scan
 * @return {list of Page} the pages, in order
 * @throws {Error} kind "escl" if the settings are not offered, the scanner refuses, or the job fails
 * @example
 *   def pages as list of escl.Page init escl.scan(escl.scanner("192.168.1.40:8080"), escl.settings());
 */
export func scan(s as Scanner, st as Settings) {
    def caps as Capabilities init capabilities($s);
    def job as Job init start($s, $caps, $st);
    def pages as list of Page init [];
    try {
        while (true) {
            def p as Page init nextPage($job);
            if ($p.done) {
                break;
            }
            $job = countPage($job, $p);
            $pages[] = $p;
        }
        finished($job);
    } catch (e) {
        throw abandon($job, $e);
    }
    return $pages;
}

/**
 * Read the `ScanImageInfo` of the page last fetched: its size in pixels.
 * Not every scanner offers it.
 *
 * @param job {Job} the job
 * @return {ImageInfo} the image size
 * @throws {Error} kind "escl" if the scanner does not offer it or the reply is unusable
 */
export func imageInfo(job as Job) {
    def r as Reply init sendPatiently(
        $job.scanner,
        "GET",
        $job.url + "/ScanImageInfo",
        "",
        MAX_DOC_BYTES);
    if ($r.status == 404) {
        fail("the scanner offers no ScanImageInfo for this job");
    }
    if ($r.status != 200) {
        fail("GET ScanImageInfo: " + refusal($job.scanner, $r));
    }
    def root as xml.Value init decodeAs(textOf($r, "ScanImageInfo"), "ScanImageInfo");
    return ImageInfo{
        width: intAt($root, "ActualWidth", 0),
        height: intAt($root, "ActualHeight", 0),
        bytesPerLine: intAt($root, "ActualBytesPerLine", 0)
    };
}

/**
 * Scan, handing each page to `handler` as it arrives instead of keeping it:
 * `handler(page as Page, n as int)`, `n` counting from 1, its result ignored.
 * An error the handler throws stops the job, which is cancelled, and comes
 * back to the caller.
 *
 * @param s {Scanner} the scanner
 * @param st {Settings} what to scan
 * @param handler {func} called once per page
 * @return {int} the number of pages
 * @throws {Error} kind "escl" as `scan`, or whatever `handler` throws
 */
export func scanEach(s as Scanner, st as Settings, handler as func) {
    def caps as Capabilities init capabilities($s);
    def job as Job init start($s, $caps, $st);
    try {
        while (true) {
            def p as Page init nextPage($job);
            if ($p.done) {
                break;
            }
            $job = countPage($job, $p);
            $handler($p, $job.pages);
        }
        finished($job);
    } catch (e) {
        throw abandon($job, $e);
    }
    return $job.pages;
}

/**
 * The job with one more page counted, refusing a page past `maxPages` or
 * past `maxJobBytes` in all.
 *
 * @param job {Job} the job, pages and bytes counted so far
 * @param p {Page} the page just fetched
 * @return {Job} the job with the page counted
 * @throws {Error} kind "escl" if the page goes over either limit
 */
func countPage(job as Job, p as Page) {
    def o as Options init $job.scanner.options;
    if ($job.pages >= $o.maxPages) {
        fail("the job gave more than {$o.maxPages} pages; raise Options.maxPages for longer jobs");
    }
    if (len($p.data) > $o.maxJobBytes - $job.bytes) {
        fail("the job's pages add up to more than {$o.maxJobBytes} bytes; raise Options.maxJobBytes for larger jobs");
    }
    $job.pages = $job.pages + 1;
    $job.bytes = $job.bytes + len($p.data);
    return $job;
}

/**
 * Write a new file, never replacing one, in one exclusive create: a file or a
 * symbolic link already at the name is refused, never written through.
 *
 * @param path {string} the file
 * @param data {bytes} its content
 * @throws {Error} kind "escl" if the name is taken or the file cannot be written
 */
func writeFresh(path as string, data as bytes) {
    try {
        fs.writeNew($path, $data);
    } catch (e) {
        if (fs.exists($path) or isLink($path)) {
            fail("will not overwrite " + shown($path));
        }
        fail("cannot write " + shown($path) + ": " + clip($e.message));
    }
}

/**
 * Whether a path is a symbolic link (`fs.exists` follows links, so a link to
 * nothing reads as absent).
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

/**
 * The usual file extension for a MIME type.
 *
 * @param contentType {string} the MIME type, parameters allowed
 * @return {string} `jpg`, `png`, `pdf`, `tif`, or `bin` for anything else
 */
export func extension(contentType as string) {
    match (mediaType($contentType)) {
        when "image/jpeg", "image/jpg" { return "jpg"; }
        when "image/png" { return "png"; }
        when "application/pdf" { return "pdf"; }
        when "image/tiff" { return "tif"; }
    }
    return "bin";
}

/**
 * The file a page is written to.
 *
 * @param dir {string} the directory
 * @param stem {string} the stem
 * @param n {int} the page number, from 1
 * @param ext {string} the extension
 * @return {string} the path
 */
func fileName(dir as string, stem as string, n as int, ext as string) {
    def num as string init convert.toString($n);
    while (len($num) < 3) {
        $num = "0" + $num;
    }
    def sep as string init "/";
    if (strings.endsWith($dir, "/")) {
        $sep = "";
    }
    return $dir + $sep + $stem + "-" + $num + "." + $ext;
}

/**
 * Scan into files `<dir>/<stem>-001.<ext>`, `-002`, ..., writing each page
 * as it arrives, the extension following its type. An existing file is never
 * overwritten: the scan is refused before it starts if the first name is
 * taken, and stops if a later one is.
 *
 * @param s {Scanner} the scanner
 * @param st {Settings} what to scan
 * @param dir {string} an existing directory
 * @param stem {string} the file name before `-NNN`: letters, digits, `-`, `_` and `.`, not starting with `.`
 * @return {list of string} the files written, in page order
 * @throws {Error} kind "escl" as `scan`, or if a file exists or the stem or directory is unusable
 */
export func scanToFiles(s as Scanner, st as Settings, dir as string, stem as string) {
    if (not onlyOf($stem, LETTERS + "-_.") or strings.startsWith($stem, ".")) {
        fail("the file stem must be letters, digits, -, _ and ., not starting with ., got " +
            shown($stem));
    }
    if (not fs.isDir($dir)) {
        fail("no such directory: " + shown($dir));
    }
    def caps as Capabilities init capabilities($s);
    def first as string init fileName($dir, $stem, 1, extension($st.format));
    if (fs.exists($first)) {
        fail("will not overwrite " + shown($first));
    }
    def job as Job init start($s, $caps, $st);
    def written as list of string init [];
    try {
        while (true) {
            def p as Page init nextPage($job);
            if ($p.done) {
                break;
            }
            $job = countPage($job, $p);
            def path as string init fileName($dir, $stem, $job.pages, extension($p.contentType));
            writeFresh($path, $p.data);
            $written[] = $path;
        }
        finished($job);
    } catch (e) {
        def err as Error init abandon($job, $e);
        if (len($written) > 0) {
            $err.message = $err.message + "; " + convert.toString(len($written)) +
                " page(s) were written, " + $written[0] + " to " + $written[len($written) - 1];
        }
        throw $err;
    }
    return $written;
}

# --- discovery ------------------------------------------------------------

/**
 * Find eSCL scanners on the local network: one mDNS query for `_uscan._tcp`
 * and `_uscans._tcp`, then every answer that arrives within `timeoutMs`. The
 * query goes out from an ordinary port, so scanners answer it directly
 * (RFC 6762 "legacy unicast"); nothing joins the multicast group. It leaves
 * by the interface of the default route, and only IPv4 addresses are read.
 * A malformed answer is skipped.
 *
 * @param timeoutMs {int} how long to collect answers, 1 to 60000 ms (1000 to 3000 is usual)
 * @return {list of Found} the scanners, each once, in the order they answered
 * @throws {Error} kind "escl" if `timeoutMs` is out of range or the socket fails
 * @example
 *   for (def f in escl.discover(2000)) {
 *       io.printf("%s at %s\n", $f.name, $f.url);
 *   }
 */
export func discover(timeoutMs as int) {
    return discoverAt(MDNS_GROUP, $timeoutMs);
}

/**
 * `discover`, sending the query to `target` instead of the mDNS group.
 *
 * @param target {string} `host:port` to query
 * @param timeoutMs {int} how long to collect answers
 * @return {list of Found} the scanners
 * @throws {Error} kind "escl" if `timeoutMs` is out of range or the socket fails
 */
func discoverAt(target as string, timeoutMs as int) {
    if ($timeoutMs < 1 or $timeoutMs > 60000) {
        fail("timeoutMs must be 1 to 60000, got {$timeoutMs}");
    }
    def sock as net.UDPSocket;
    try {
        $sock = net.listenUDP("0.0.0.0:0");
    } catch (e) {
        fail("mDNS: cannot open a socket: " + clip($e.message));
    }
    defer net.close($sock);
    try {
        net.sendTo($sock, $target, mdnsQuery());
    } catch (e) {
        fail("mDNS query to {$target}: " + clip($e.message));
    }
    def recs as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def began as time.Time init time.now();
    while (true) {
        def left as int init $timeoutMs - time.milliseconds(time.sub(time.now(), $began));
        if ($left <= 0) {
            break;
        }
        net.setReadDeadline($sock, $left);
        def d as net.Datagram;
        try {
            $d = net.recvFrom($sock, 9000);
        } catch (e) {
            if ($e.kind == "timeout") {
                break;
            }
            fail("mDNS: " + clip($e.message));
        }
        if ($d.truncated) {
            continue;
        }
        if ($recs.count >= MAX_RECORDS) {
            # a flood, not a network of scanners: keep what came first
            break;
        }
        try {
            $recs = absorb($recs, $d.data);
        } catch (e) {
            # a malformed answer from one device must not hide the others
            continue;
        }
    }
    return assemble($recs);
}

/**
 * Append a DNS name in wire form.
 *
 * @param out {bytes} the message so far
 * @param name {string} a dotted name of ASCII labels
 * @return {bytes} the message with the name
 */
func putName(out as bytes, name as string) {
    for (def label in strings.split($name, ".")) {
        def b as bytes init convert.bytesFromString("utf-8", $label);
        $out[] = len($b);
        for (def i in 0..len($b)) {
            $out[] = $b[$i];
        }
    }
    $out[] = 0;
    return $out;
}

/**
 * The query: two PTR questions, each asking for a unicast answer.
 *
 * @return {bytes} the DNS message
 */
func mdnsQuery() {
    def q as bytes;
    # id 0, flags 0, two questions, no records
    for (def b in [0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]) {
        $q[] = $b;
    }
    for (def service in [USCAN, USCANS]) {
        $q = putName($q, $service);
        # type PTR (12), class IN with the unicast-response bit
        for (def b in [0, 12, 128, 1]) {
            $q[] = $b;
        }
    }
    return $q;
}

/**
 * A big-endian 16-bit number.
 *
 * @param msg {bytes} the message
 * @param at {int} where it starts
 * @return {int} the number
 * @throws {Error} kind "escl" if it runs past the end
 */
func u16(msg as bytes, at as int) {
    if ($at < 0 or $at + 2 > len($msg)) {
        fail("mDNS: truncated message");
    }
    return $msg[$at] * 256 + $msg[$at + 1];
}

/**
 * Bytes of a DNS message as text.
 *
 * @param msg {bytes} the message
 * @param from {int} the first byte
 * @param end {int} the byte after the last
 * @return {string} the text
 * @throws {Error} kind "escl" if it is not UTF-8
 */
func utf8At(msg as bytes, from as int, end as int) {
    def s as string init "";
    try {
        $s = convert.stringFromBytes("utf-8", $msg[$from..$end]);
    } catch (e) {
        fail("mDNS: text that is not UTF-8");
    }
    return $s;
}

/**
 * Read a possibly compressed DNS name.
 *
 * @param msg {bytes} the message
 * @param at {int} where the name starts
 * @return {NameAt} the name and the offset after it
 * @throws {Error} kind "escl" if it is malformed, loops, or is too long
 */
func readName(msg as bytes, at as int) {
    def labels as list of string init [];
    def pos as int init $at;
    def next as int init -1;
    def jumps as int init 0;
    def total as int init 0;
    while (true) {
        if ($pos < 0 or $pos >= len($msg)) {
            fail("mDNS: a name runs past the message");
        }
        def l as int init $msg[$pos];
        if ($l == 0) {
            if ($next < 0) {
                $next = $pos + 1;
            }
            break;
        }
        if ($l >= 192) {
            def ptr as int init u16($msg, $pos) - 49152;
            if ($next < 0) {
                $next = $pos + 2;
            }
            $jumps = $jumps + 1;
            if ($jumps > 16) {
                fail("mDNS: a name loops");
            }
            $pos = $ptr;
            continue;
        }
        if ($l >= 64 or $pos + 1 + $l > len($msg)) {
            fail("mDNS: a malformed label");
        }
        $total = $total + $l + 1;
        if ($total > 255) {
            fail("mDNS: a name is too long");
        }
        $labels[] = printable(utf8At($msg, $pos + 1, $pos + 1 + $l));
        $pos = $pos + 1 + $l;
    }
    return NameAt{name: strings.join($labels, "."), next: $next};
}

/**
 * The strings of a TXT record as `key=value` lines, keys lowercased and
 * control characters as `?`.
 *
 * @param msg {bytes} the message
 * @param at {int} where the record data starts
 * @param end {int} where it ends
 * @return {string} the lines
 * @throws {Error} kind "escl" if a string runs past the record
 */
func readTxt(msg as bytes, at as int, end as int) {
    def lines as list of string init [];
    def pos as int init $at;
    while ($pos < $end) {
        def l as int init $msg[$pos];
        if ($pos + 1 + $l > $end) {
            fail("mDNS: a TXT string runs past its record");
        }
        def entry as string init printable(utf8At($msg, $pos + 1, $pos + 1 + $l));
        $pos = $pos + 1 + $l;
        def eq as int init strings.indexOf($entry, "=");
        if ($eq > 0) {
            $lines[] = strings.lower(strings.substring($entry, 0, $eq)) + "=" +
                strings.substring($entry, $eq + 1);
        }
    }
    return strings.join($lines, "\n");
}

/**
 * A value from `readTxt` lines.
 *
 * @param txt {string} the lines
 * @param key {string} the key, lowercase
 * @return {string} the first value, `""` if absent
 */
func txtValue(txt as string, key as string) {
    for (def line in strings.split($txt, "\n")) {
        if (strings.startsWith($line, $key + "=")) {
            return strings.substring($line, len($key) + 1);
        }
    }
    return "";
}

/**
 * Add the records of one mDNS answer.
 *
 * @param recs {Records} the records so far
 * @param msg {bytes} the DNS message
 * @return {Records} the records with this message's added
 * @throws {Error} kind "escl" if the message is malformed
 */
func absorb(recs as Records, msg as bytes) {
    if (len($msg) < 12 or u16($msg, 2) < 32768) {
        # too short, or a query rather than an answer
        return $recs;
    }
    def counts as int init u16($msg, 6) + u16($msg, 8) + u16($msg, 10);
    def off as int init 12;
    for (def i in 0..u16($msg, 4)) {
        $off = readName($msg, $off).next + 4;
    }
    for (def i in 0..$counts) {
        def owner as NameAt init readName($msg, $off);
        def at as int init $owner.next;
        def kind as int init u16($msg, $at);
        def data as int init $at + 10;
        def end as int init $data + u16($msg, $at + 8);
        if ($end > len($msg)) {
            fail("mDNS: a record runs past the message");
        }
        def key as string init strings.lower($owner.name);
        if ($kind == 12 or $kind == 33 or $kind == 16 or $kind == 1) {
            $recs.count = $recs.count + 1;
        }
        match ($kind) {
            when 12 { $recs.ptrs[] = $key + "\t" + readName($msg, $data).name; }
            when 33 {
                if ($end - $data < 7) {
                    fail("mDNS: an SRV record is too short");
                }
                $recs.srvs[$key] = Srv{
                    target: strings.lower(readName($msg, $data + 6).name),
                    port: u16($msg, $data + 4)
                };
            }
            when 16 { $recs.txts[$key] = readTxt($msg, $data, $end); }
            when 1 {
                if ($end - $data == 4) {
                    $recs.addrs[$key] = "{$msg[$data]}.{$msg[$data + 1]}.{$msg[$data + 2]}.{$msg[$data + 3]}";
                }
            }
        }
        $off = $end;
    }
    return $recs;
}

/**
 * Join PTR, SRV, TXT and A answers into scanners.
 *
 * @param recs {Records} the answers
 * @return {list of Found} each scanner once; one whose answers do not make a usable address is left out
 */
func assemble(recs as Records) {
    def out as list of Found init [];
    def urls as list of string init [];
    for (def pair in $recs.ptrs) {
        # the service never holds a tab; an instance name may
        def tab as int init strings.indexOf($pair, "\t");
        def service as string init strings.substring($pair, 0, $tab);
        def instance as string init strings.substring($pair, $tab + 1);
        def key as string init strings.lower($instance);
        if (($service != USCAN and $service != USCANS) or not maps.has($recs.srvs, $key)) {
            continue;
        }
        def srv as Srv init $recs.srvs[$key];
        def txt as string init "";
        if (maps.has($recs.txts, $key)) {
            $txt = $recs.txts[$key];
        }
        def f as Found init Found{
            name: $instance,
            host: $srv.target,
            address: "",
            port: $srv.port,
            secure: $service == USCANS,
            root: bare(txtValue($txt, "rs")),
            model: txtValue($txt, "ty"),
            uuid: txtValue($txt, "uuid"),
            url: ""
        };
        if (strings.endsWith($key, "." + $service)) {
            $f.name = strings.substring($instance, 0, len($instance) - len($service) - 1);
        }
        if (maps.has($recs.addrs, $srv.target)) {
            $f.address = $recs.addrs[$srv.target];
        }
        if ($f.root == "") {
            $f.root = "eSCL";
        }
        def scheme as string init "http";
        if ($f.secure) {
            $scheme = "https";
        }
        def where as string init $f.address;
        if ($where == "") {
            $where = $f.host;
        }
        $f.url = "{$scheme}://{$where}:{$f.port}/{$f.root}";
        if (usable($f.url) and not lists.contains($urls, $f.url)) {
            $urls[] = $f.url;
            $out[] = $f;
        }
    }
    return $out;
}

/**
 * Whether `scanner` accepts an address.
 *
 * @param url {string} the address
 * @return {bool} whether it does
 */
func usable(url as string) {
    try {
        scanner($url);
    } catch (e) {
        return false;
    }
    return true;
}
