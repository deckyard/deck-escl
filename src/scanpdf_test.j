# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for scanpdf: jennifer test src/scanpdf_test.j
 *
 * Pages are real JPEG and PNG images made with the `images` library;
 * `scanToPdf` runs against a small `httpd` fake scanner.
 */
use binary;
use convert;
use fs;
use strings;
use httpd;
use images;
use task;
use testing;
use time;

def const CAPS as string init '<scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
    xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
  <pwg:Version>2.63</pwg:Version>
  <scan:Platen><scan:PlatenInputCaps>
    <scan:MinWidth>8</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth>
    <scan:MinHeight>8</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
    <scan:SettingProfiles><scan:SettingProfile>
      <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
      <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:DocumentFormats>
      <scan:SupportedResolutions><scan:DiscreteResolutions><scan:DiscreteResolution>
        <scan:XResolution>150</scan:XResolution><scan:YResolution>150</scan:YResolution>
      </scan:DiscreteResolution></scan:DiscreteResolutions></scan:SupportedResolutions>
    </scan:SettingProfile></scan:SettingProfiles>
  </scan:PlatenInputCaps></scan:Platen>
  <scan:Adf><scan:AdfSimplexInputCaps>
    <scan:MinWidth>8</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth>
    <scan:MinHeight>8</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
    <scan:SettingProfiles><scan:SettingProfile>
      <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
      <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:DocumentFormats>
      <scan:SupportedResolutions><scan:DiscreteResolutions><scan:DiscreteResolution>
        <scan:XResolution>150</scan:XResolution><scan:YResolution>150</scan:YResolution>
      </scan:DiscreteResolution></scan:DiscreteResolutions></scan:SupportedResolutions>
    </scan:SettingProfile></scan:SettingProfiles>
  </scan:AdfSimplexInputCaps></scan:Adf>
</scan:ScannerCapabilities>';

/**
 * A page holding an image of this size in this format.
 *
 * @param format {string} `jpeg` or `png`
 * @param width {int} pixels
 * @param height {int} pixels
 * @return {escl.Page} the page
 */
func imagePage(format as string, width as int, height as int) {
    def img as images.Image init images.create($width, $height, images.rgb(200, 30, 30));
    return escl.Page{
        done: false,
        contentType: "image/" + $format,
        data: images.encode($format, $img)
    };
}

/**
 * How often `needle` occurs in the PDF.
 *
 * @param doc {bytes} the PDF
 * @param needle {string} the text
 * @return {int} the count
 */
func occurrences(doc as bytes, needle as string) {
    def n as bytes init convert.bytesFromString("utf-8", $needle);
    def count as int init 0;
    def at as int init binary.indexOf($doc, $n);
    while ($at >= 0) {
        $count = $count + 1;
        $at = binary.indexOf($doc, $n, $at + 1);
    }
    return $count;
}

func testBuildSizesPagesFromPixelsAndResolution() {
    def jpeg as escl.Page init imagePage("jpeg", 300, 150);
    def doc as bytes init build([$jpeg, imagePage("png", 150, 300)], 150);
    testing.assertTrue(binary.startsWith($doc, convert.bytesFromString("utf-8", "%PDF-")));
    testing.assertEqual(occurrences($doc, "/MediaBox [0 0 144 72]"), 1);
    testing.assertEqual(occurrences($doc, "/MediaBox [0 0 72 144]"), 1);
    testing.assertEqual(occurrences($doc, "/DCTDecode"), 1);
    # the JPEG goes in as it came
    testing.assertTrue(binary.contains($doc, $jpeg.data));
}

func testBuildRefusesWhatItCannotBind() {
    def pdfPage as escl.Page init escl.Page{
        done: false,
        contentType: "application/pdf",
        data: convert.bytesFromString("utf-8", "%PDF-1.4")
    };
    def junk as escl.Page init escl.Page{
        done: false,
        contentType: "image/jpeg",
        data: convert.bytesFromString("utf-8", "not an image at all")
    };
    def none as bytes;
    def end as escl.Page init escl.Page{done: true, contentType: "", data: $none};
    def cases as list of list of escl.Page init [[], [$pdfPage], [$junk], [$end]];
    def wants as list of string init [
        "there are no pages to bind",
        "page 1 is a PDF already",
        "page 1 is not a JPEG or PNG image",
        "page 1 is the end-of-job marker"
    ];
    for (def k in 0..len($cases)) {
        def msg as string init "";
        try {
            build($cases[$k], 150);
        } catch (e) {
            $msg = $e.kind + " " + $e.message;
        }
        testing.assertContains($msg, "escl escl: " + $wants[$k]);
    }
    def big as escl.Page init imagePage("png", 2001, 10);
    def msg as string init "";
    try {
        build([$big], 10);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "would be 14407 x 72 points");
    $msg = "";
    try {
        build([$big], 0);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "the resolution must be 1 to 10000 dpi");
}

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the server
 * @param replies {list of bytes} the bodies; a body starting with `<` is XML, an empty one a 404,
 *   `!` a 500, else a JPEG
 * @return {int} the requests answered
 */
func serve(srv as httpd.Server, replies as list of bytes) {
    for (def body in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        if (len($body) == 0) {
            httpd.respond($req, 404, $body);
        } elseif ($body == FAILURE) {
            httpd.respond($req, 500, "");
        } elseif ($body[0] == 60) {
            httpd.setHeader($req, "Content-Type", "text/xml");
            if (httpd.method($req) == "POST") {
                httpd.setHeader($req, "Location", "/eSCL/ScanJobs/1");
                httpd.respond($req, 201, "");
            } else {
                httpd.respond($req, 200, $body);
            }
        } else {
            httpd.setHeader($req, "Content-Type", "image/jpeg");
            httpd.respond($req, 200, $body);
        }
    }
    return len($replies);
}

func testScanToPdf() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def status as string init "<scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" " +
        "xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:State>Idle</pwg:State></scan:ScannerStatus>";
    def none as bytes;
    def x as bytes init convert.bytesFromString("utf-8", "<post/>");
    def replies as list of bytes init [
        convert.bytesFromString("utf-8", CAPS),
        convert.bytesFromString("utf-8", STATUS),
        $x,
        imagePage("jpeg", 300, 600).data,
        imagePage("jpeg", 300, 600).data,
        $none,
        convert.bytesFromString("utf-8", $status),
        $none
    ];
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return serve($srv, $replies);
    };
    def st as escl.Settings init escl.settings();
    $st.source = escl.FEEDER;
    $st.resolution = 150;
    def path as string init $dir + "/out.pdf";
    def o as escl.Options;
    $o.timeoutMs = 5000;
    def s as escl.Scanner init escl.scannerWith(httpd.address($srv), $o);
    testing.assertEqual(scanToPdf($s, $st, $path), 2);
    testing.assertEqual(task.waitTimeout($t, 10000), 8);
    httpd.shutdown($srv);
    def doc as bytes init fs.readBytes($path);
    testing.assertEqual(occurrences($doc, "/MediaBox [0 0 144 288]"), 2);
    # the file now exists: refused before any request
    def msg as string init "";
    try {
        scanToPdf($s, $st, $path);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "will not overwrite");
    $st.format = "application/pdf";
    $msg = "";
    try {
        scanToPdf($s, $st, $dir + "/other.pdf");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "set the format to image/jpeg or image/png");
}

/**
 * Bytes from a list of byte values.
 *
 * @param xs {list of int} the values
 * @return {bytes} the bytes
 */
func raw(xs as list of int) {
    def out as bytes;
    for (def x in $xs) {
        $out[] = $x;
    }
    return $out;
}

/**
 * A PNG made only of its signature, an IHDR and one more chunk; enough for
 * the header checks, never decoded.
 *
 * @param kind {int} the colour type
 * @param interlace {int} the interlace method
 * @param extra {string} the next chunk's type
 * @return {escl.Page} the page
 */
func fakePng(kind as int, interlace as int, extra as string) {
    def b as bytes init raw([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        0,
        8,
        $kind,
        0,
        0,
        $interlace,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
    ]);
    def e as bytes init convert.bytesFromString("utf-8", $extra);
    for (def i in 0..4) {
        $b[] = $e[$i];
    }
    for (def i in 0..4) {
        $b[] = 0;
    }
    return escl.Page{done: false, contentType: "image/png", data: $b};
}

func testBuildChecksHeadersBeforeDecoding() {
    # a JPEG frame header claiming 65535 x 65535 pixels
    def huge as escl.Page init escl.Page{
        done: false,
        contentType: "image/jpeg",
        data: raw([
            255,
            216,
            255,
            224,
            0,
            4,
            0,
            0,
            255,
            192,
            0,
            11,
            8,
            255,
            255,
            255,
            255,
            1,
            1,
            17,
            0
        ])
    };
    def alpha as images.Image init images.create(400, 400, images.rgba(1, 2, 3, 100));
    def cases as list of escl.Page init [
        $huge,
        escl.Page{done: false, contentType: "image/png", data: images.encode("png", $alpha)},
        fakePng(6, 0, "IDAT"),
        fakePng(2, 1, "IDAT"),
        fakePng(2, 0, "tRNS"),
        escl.Page{done: false, contentType: "image/jpeg", data: raw([255, 216, 255, 218, 0, 2])},
        escl.Page{
            done: false,
            contentType: "image/png",
            data: raw([137, 80, 78, 71, 13, 10, 26, 10])
        }
    ];
    def wants as list of string init [
        "would be 15728 x 15728 points",
        "is a PNG with transparency",
        "is a PNG with transparency",
        "is an interlaced PNG",
        "is a PNG with transparency",
        "is a JPEG without a frame header",
        "is a PNG without a header"
    ];
    for (def k in 0..len($cases)) {
        def t0 as time.Time init time.now();
        def msg as string init "";
        try {
            build([$cases[$k]], 300);
        } catch (e) {
            $msg = $e.kind + " " + $e.message;
        }
        testing.assertContains($msg, "escl escl: page 1 " + $wants[$k]);
        testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 1000);
    }
}

func testScanToPdfRefusesBeforeScanning() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    fs.symlink($dir + "/nowhere", $dir + "/link.pdf");
    def s as escl.Scanner init escl.scanner("127.0.0.1:1");
    def msg as string init "";
    try {
        scanToPdf($s, escl.settings(), $dir + "/link.pdf");
    } catch (e) {
        $msg = $e.message;
    }
    # refused before any request: the scanner address is unreachable
    testing.assertContains($msg, "will not overwrite");
    testing.assertFalse(fs.exists($dir + "/nowhere"));
}

/**
 * A PNG with a colour IHDR and then empty chunks of these types.
 *
 * @param types {list of string} the chunk types, in order
 * @return {escl.Page} the page
 */
func pngOf(types as list of string) {
    def p as escl.Page init fakePng(2, 0, $types[0]);
    for (def k in 1..len($types)) {
        def e as bytes init convert.bytesFromString("utf-8", $types[$k]);
        for (def i in 0..4) {
            $p.data[] = 0;
        }
        for (def i in 0..4) {
            $p.data[] = $e[$i];
        }
        for (def i in 0..4) {
            $p.data[] = 0;
        }
    }
    return $p;
}

func testHeaderWalksAreBounded() {
    def many as list of string init [];
    for (def i in 0..65) {
        $many[] = "tEXt";
    }
    $many[] = "IDAT";
    $many[] = "IEND";
    # a JPEG of 200000 empty APP0 segments before its frame header
    def segs as bytes init raw([255, 216]);
    for (def i in 0..200000) {
        $segs[] = 255;
        $segs[] = 224;
        $segs[] = 0;
        $segs[] = 2;
    }
    def cases as list of escl.Page init [
        pngOf($many),
        escl.Page{done: false, contentType: "image/jpeg", data: $segs},
        pngOf(["IDAT", "tRNS", "IEND"]),
        pngOf(["IDAT", "IHDR", "IEND"]),
        pngOf(["IDAT", "PLTE", "IEND"]),
        pngOf(["tEXt", "IEND"])
    ];
    def wants as list of string init [
        "is a PNG with more than 64 chunks before its image data",
        "is a JPEG with more than 64 segments before its frame header",
        "is a PNG with transparency",
        "is a malformed PNG",
        "is a malformed PNG",
        "is a PNG without image data"
    ];
    for (def k in 0..len($cases)) {
        def t0 as time.Time init time.now();
        def msg as string init "";
        def kind as string init "";
        try {
            build([$cases[$k]], 300);
        } catch (e) {
            $msg = $e.message;
            $kind = $e.kind;
        }
        testing.assertContains($msg, "escl: page 1 " + $wants[$k]);
        # the chunk and segment budgets are reached caps; the rest are format rules
        if ($k < 2) {
            testing.assertEqual($kind, "limit");
        } else {
            testing.assertEqual($kind, "escl");
        }
        testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 1000);
    }
    # 200000 empty image-data chunks is a flood, refused fast
    def flood as list of string init [];
    for (def i in 0..200000) {
        $flood[] = "IDAT";
    }
    $flood[] = "IEND";
    def floodPage as escl.Page init pngOf($flood);
    def t0 as time.Time init time.now();
    def msg as string init "";
    def kind as string init "";
    try {
        build([$floodPage], 300);
    } catch (e) {
        $msg = $e.message;
        $kind = $e.kind;
    }
    testing.assertContains($msg, "is a PNG of more than 2407 chunks");
    testing.assertEqual($kind, "limit");
    testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 1000);
    # chunks after the image data, as encoders write them, pass the walk
    testing.assertEqual(imageSize(pngOf(["IDAT", "IDAT", "tEXt", "IEND"]).data, 1).width, 256);
}

func testScanToPdfNeedsAWritablePlaceFirst() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    # unreachable: a request would fail with a GET error instead
    def s as escl.Scanner init escl.scanner("127.0.0.1:1");
    def msg as string init "";
    try {
        scanToPdf($s, escl.settings(), $dir + "/typo/out.pdf");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "cannot write");
    testing.assertFalse(strings.contains($msg, "GET"));
    # a failed scan leaves no empty file behind
    $msg = "";
    try {
        scanToPdf($s, escl.settings(), $dir + "/out.pdf");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "GET");
    testing.assertFalse(fs.exists($dir + "/out.pdf"));
}

func testScanToPdfKeepsPagesItCannotBind() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def status as string init "<scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" " +
        "xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:State>Idle</pwg:State></scan:ScannerStatus>";
    def none as bytes;
    def junk as bytes init convert.bytesFromString("utf-8", "not an image");
    def replies as list of bytes init [
        convert.bytesFromString("utf-8", CAPS),
        convert.bytesFromString("utf-8", STATUS),
        convert.bytesFromString("utf-8", "<post/>"),
        imagePage("jpeg", 30, 60).data,
        $junk,
        $none,
        convert.bytesFromString("utf-8", $status),
        $none
    ];
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return serve($srv, $replies);
    };
    def o as escl.Options;
    $o.timeoutMs = 5000;
    def s as escl.Scanner init escl.scannerWith(httpd.address($srv), $o);
    def st as escl.Settings init escl.settings();
    $st.source = escl.FEEDER;
    $st.resolution = 150;
    def msg as string init "";
    try {
        scanToPdf($s, $st, $dir + "/out.pdf");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertEqual(task.waitTimeout($t, 10000), 8);
    httpd.shutdown($srv);
    testing.assertContains($msg, "page 2 is not a JPEG or PNG image");
    testing.assertContains($msg, "the 2 scanned page(s) were kept as");
    testing.assertFalse(fs.exists($dir + "/out.pdf"));
    testing.assertEqual(fs.readBytes($dir + "/out-002.jpg"), $junk);
    testing.assertTrue(fs.exists($dir + "/out-001.jpg"));
}

/** A reply body the fake answers with HTTP 500. */
def const FAILURE as bytes init convert.bytesFromString("utf-8", "!");

/**
 * Run `scanToPdf` against a fake scanner giving these replies.
 *
 * @param replies {list of bytes} as `serve` takes them
 * @param path {string} the PDF file
 * @return {string} the error message, `""` if it succeeded
 */
func scanAgainst(replies as list of bytes, path as string) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return serve($srv, $replies);
    };
    def o as escl.Options;
    $o.timeoutMs = 5000;
    def st as escl.Settings init escl.settings();
    $st.source = escl.FEEDER;
    $st.resolution = 150;
    def msg as string init "";
    try {
        scanToPdf(escl.scannerWith(httpd.address($srv), $o), $st, $path);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertEqual(task.waitTimeout($t, 10000), len($replies));
    httpd.shutdown($srv);
    return $msg;
}

func testScanToPdfKeepsThePagesOfAFailedJob() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def one as bytes init imagePage("jpeg", 30, 60).data;
    def none as bytes;
    def msg as string init scanAgainst(
        [
            convert.bytesFromString("utf-8", CAPS),
            convert.bytesFromString("utf-8", STATUS),
            convert.bytesFromString("utf-8", "<post/>"),
            $one,
            $one,
            FAILURE,
            $none
        ],
        $dir + "/out.pdf");
    testing.assertContains($msg, "page 3: HTTP 500");
    testing.assertContains($msg, "2 of the 2 scanned page(s) were kept as");
    testing.assertFalse(fs.exists($dir + "/out.pdf"));
    testing.assertEqual(fs.readBytes($dir + "/out-002.jpg"), $one);
}

func testKeptPagesTakeFreeNames() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    fs.writeNew($dir + "/out-002.jpg", "earlier");
    def one as bytes init imagePage("jpeg", 30, 60).data;
    def none as bytes;
    def msg as string init scanAgainst(
        [
            convert.bytesFromString("utf-8", CAPS),
            convert.bytesFromString("utf-8", STATUS),
            convert.bytesFromString("utf-8", "<post/>"),
            $one,
            convert.bytesFromString("utf-8", "not an image"),
            $none,
            convert.bytesFromString("utf-8", STATUS),
            $none
        ],
        $dir + "/out.pdf");
    testing.assertContains($msg, "page 2 is not a JPEG or PNG image");
    testing.assertContains(
        $msg,
        "were kept as \"" + $dir + "/out-2-001.jpg\" to \"" + $dir +
            "/out-2-002.jpg\"");
    testing.assertEqual(fs.readString($dir + "/out-002.jpg"), "earlier");
    testing.assertFalse(fs.exists($dir + "/out-001.jpg"));
    testing.assertEqual(fs.readBytes($dir + "/out-2-001.jpg"), $one);
}

/** An idle scanner's status. */
def const STATUS as string init "<scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" " +
    "xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:State>Idle</pwg:State></scan:ScannerStatus>";

func testErrorTextLosesControlsAndBidi() {
    testing.assertEqual(quoted("a\u202eb\u001b[2J\u061cc"), "\"a?b?[2J?c\"");
}

func testAFailedReleaseKeepsTheFirstError() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def sub as string init $dir + "/locked";
    fs.mkdir($sub);
    fs.writeNew($sub + "/out.pdf", "");
    fs.chmod($sub, 365);
    defer fs.chmod($sub, 493);
    def note as string init releaseNote($sub + "/out.pdf");
    testing.assertTrue(strings.startsWith($note, "; cannot remove the empty "));
    testing.assertFalse(strings.contains($note, "escl: "));
}

# A failed job rethrown with the pages kept keeps the escl error's fields.
func testARethrownEsclErrorKeepsItsFields() {
    try {
        failAs("escl: page 3: HTTP 503; 2 of the 2 scanned page(s) were kept", 503, 2000);
        throw Error{kind: "missed", message: "failAs did not throw"};
    } catch (e) {
        testing.assertEqual($e.kind, "escl");
        testing.assertEqual($e.status, 503);
        testing.assertEqual($e.retryAfterMs, 2000);
    }
}
