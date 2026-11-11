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
use httpd;
use images;
use task;
use testing;

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
        "page 1 cannot go into a PDF",
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
 * @param replies {list of bytes} the bodies; a body starting with `<` is XML, an empty one a 404, else a JPEG
 * @return {int} the requests answered
 */
func serve(srv as httpd.Server, replies as list of bytes) {
    for (def body in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        if (len($body) == 0) {
            httpd.respond($req, 404, $body);
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
        $x,
        imagePage("jpeg", 300, 600).data,
        imagePage("jpeg", 300, 600).data,
        $none,
        convert.bytesFromString("utf-8", $status)
    ];
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return serve($srv, $replies);
    };
    def st as escl.Settings init escl.settings();
    $st.resolution = 150;
    def path as string init $dir + "/out.pdf";
    def o as escl.Options;
    $o.timeoutMs = 5000;
    def s as escl.Scanner init escl.scannerWith(httpd.address($srv), $o);
    testing.assertEqual(scanToPdf($s, $st, $path), 2);
    testing.assertEqual(task.waitTimeout($t, 10000), 6);
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
    testing.assertContains($msg, "set the format to image/jpeg");
}
