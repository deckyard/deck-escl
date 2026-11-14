# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for escl: jennifer test src/escl_test.j
 *
 * The parsing and checking helpers are tested directly. Jobs run against an
 * `httpd` server on a loopback port that plays a scanner from canned replies
 * and hands back what it received.
 *
 * The two capability documents follow the shape of an HP LaserJet M28
 * (flatbed only, `scan:` and `pwg:` prefixes) and of an Epson document
 * scanner (feeder only, simplex and duplex, `DocumentFormatExt`, a default
 * namespace). They are written for these tests, not captured from devices.
 */
use httpd;
use task;
use testing;

def const HP_CAPS as string init '<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
    xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
  <pwg:Version>2.63</pwg:Version>
  <pwg:MakeAndModel>HP LaserJet MFP M28w</pwg:MakeAndModel>
  <pwg:SerialNumber>VNC1234567</pwg:SerialNumber>
  <scan:UUID>564e4333-3132-3334-3536-000000000000</scan:UUID>
  <scan:AdminURI>http://NPI6142D.local.</scan:AdminURI>
  <scan:IconURI>http://NPI6142D.local./ipp/images/printer.png</scan:IconURI>
  <scan:Platen>
    <scan:PlatenInputCaps>
      <scan:MinWidth>8</scan:MinWidth>
      <scan:MaxWidth>2550</scan:MaxWidth>
      <scan:MinHeight>8</scan:MinHeight>
      <scan:MaxHeight>3508</scan:MaxHeight>
      <scan:MaxScanRegions>1</scan:MaxScanRegions>
      <scan:SettingProfiles>
        <scan:SettingProfile>
          <scan:ColorModes>
            <scan:ColorMode>BlackAndWhite1</scan:ColorMode>
            <scan:ColorMode>Grayscale8</scan:ColorMode>
            <scan:ColorMode>RGB24</scan:ColorMode>
          </scan:ColorModes>
          <scan:DocumentFormats>
            <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
            <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>
          </scan:DocumentFormats>
          <scan:SupportedResolutions>
            <scan:DiscreteResolutions>
              <scan:DiscreteResolution>
                <scan:XResolution>300</scan:XResolution>
                <scan:YResolution>300</scan:YResolution>
              </scan:DiscreteResolution>
              <scan:DiscreteResolution>
                <scan:XResolution>75</scan:XResolution>
                <scan:YResolution>75</scan:YResolution>
              </scan:DiscreteResolution>
              <scan:DiscreteResolution>
                <scan:XResolution>600</scan:XResolution>
                <scan:YResolution>600</scan:YResolution>
              </scan:DiscreteResolution>
              <scan:DiscreteResolution>
                <scan:XResolution>1200</scan:XResolution>
                <scan:YResolution>600</scan:YResolution>
              </scan:DiscreteResolution>
            </scan:DiscreteResolutions>
          </scan:SupportedResolutions>
        </scan:SettingProfile>
      </scan:SettingProfiles>
      <scan:SupportedIntents>
        <scan:Intent>Document</scan:Intent>
        <scan:Intent>Photo</scan:Intent>
        <scan:Intent>TextAndGraphic</scan:Intent>
      </scan:SupportedIntents>
      <scan:MaxOpticalXResolution>600</scan:MaxOpticalXResolution>
      <scan:MaxOpticalYResolution>600</scan:MaxOpticalYResolution>
    </scan:PlatenInputCaps>
  </scan:Platen>
</scan:ScannerCapabilities>
';

def const EPSON_CAPS as string init '<?xml version="1.0" encoding="UTF-8"?>
<ScannerCapabilities xmlns="http://schemas.hp.com/imaging/escl/2011/05/03"
    xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.6</pwg:Version>
  <pwg:MakeAndModel>EPSON ES-C380W</pwg:MakeAndModel>
  <Adf>
    <AdfSimplexInputCaps>
      <MinWidth>300</MinWidth>
      <MaxWidth>2550</MaxWidth>
      <MinHeight>300</MinHeight>
      <MaxHeight>4200</MaxHeight>
      <SettingProfiles>
        <SettingProfile>
          <ColorModes>
            <ColorMode>Grayscale8</ColorMode>
            <ColorMode>RGB24</ColorMode>
          </ColorModes>
          <DocumentFormats>
            <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
            <DocumentFormatExt>image/jpeg</DocumentFormatExt>
            <DocumentFormatExt>application/pdf</DocumentFormatExt>
          </DocumentFormats>
          <SupportedResolutions>
            <ResolutionRange>
              <XResolutionRange><Min>50</Min><Max>600</Max><Normal>300</Normal><Step>50</Step></XResolutionRange>
              <YResolutionRange><Min>50</Min><Max>600</Max><Normal>300</Normal><Step>50</Step></YResolutionRange>
            </ResolutionRange>
          </SupportedResolutions>
        </SettingProfile>
        <SettingProfile>
          <ColorModes>
            <ColorMode>BlackAndWhite1</ColorMode>
          </ColorModes>
          <DocumentFormats>
            <pwg:DocumentFormat>image/png</pwg:DocumentFormat>
          </DocumentFormats>
        </SettingProfile>
      </SettingProfiles>
    </AdfSimplexInputCaps>
    <AdfDuplexInputCaps>
      <MinWidth>300</MinWidth>
      <MaxWidth>2550</MaxWidth>
      <MinHeight>300</MinHeight>
      <MaxHeight>3600</MaxHeight>
      <SettingProfiles>
        <SettingProfile>
          <ColorModes><ColorMode>RGB24</ColorMode></ColorModes>
          <DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></DocumentFormats>
          <SupportedResolutions>
            <DiscreteResolutions>
              <DiscreteResolution><XResolution>200</XResolution><YResolution>200</YResolution></DiscreteResolution>
              <DiscreteResolution><XResolution>300</XResolution><YResolution>300</YResolution></DiscreteResolution>
            </DiscreteResolutions>
          </SupportedResolutions>
        </SettingProfile>
      </SettingProfiles>
    </AdfDuplexInputCaps>
    <AdfOptions>
      <AdfOption>DetectPaperLoaded</AdfOption>
      <AdfOption>Duplex</AdfOption>
    </AdfOptions>
  </Adf>
</ScannerCapabilities>
';

/** A canned reply. */
def struct Canned {
    status as int,
    contentType as string,
    location as string,
    retryAfter as string,
    body as bytes
};

/** One request as the fake scanner saw it. */
def struct Seen {
    method as string,
    path as string,
    auth as string,
    body as string
};

/** A running fake scanner. */
def struct Fake {
    srv as httpd.Server,
    address as string,
    t as task of list of Seen
};

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param replies {list of Canned} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, replies as list of Canned) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            auth: httpd.header($req, "Authorization"),
            body: convert.stringFromBytes("utf-8", httpd.body($req))
        };
        if ($r.contentType != "") {
            httpd.setHeader($req, "Content-Type", $r.contentType);
        }
        if ($r.location != "") {
            httpd.setHeader($req, "Location", $r.location);
        }
        if ($r.retryAfter != "") {
            httpd.setHeader($req, "Retry-After", $r.retryAfter);
        }
        httpd.respond($req, $r.status, $r.body);
    }
    return $seen;
}

/**
 * Start a fake scanner that gives these replies.
 *
 * @param replies {list of Canned} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Canned) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of Seen init spawn {
        return serve($srv, $replies);
    };
    return Fake{srv: $srv, address: httpd.address($srv), t: $t};
}

/**
 * Stop a fake scanner, failing if it has not had every request within 10 s.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func stopFake(f as Fake) {
    defer httpd.shutdown($f.srv);
    try {
        return task.waitTimeout($f.t, 10000);
    } catch (e) {
        task.discard($f.t);
        throw Error{
            kind: "test",
            message: "the fake scanner did not get every request it expected: {$e.message}"
        };
    }
    return [];
}

/**
 * A scanner on the fake, retrying quickly.
 *
 * @param f {Fake} the server
 * @return {Scanner} the scanner
 */
func on(f as Fake) {
    def o as Options;
    $o.retryMs = 10;
    $o.busyWaitMs = 300;
    $o.timeoutMs = 5000;
    return scannerWith($f.address, $o);
}

/**
 * Text as bytes.
 *
 * @param text {string} the text
 * @return {bytes} its UTF-8
 */
func utf8(text as string) {
    return convert.bytesFromString("utf-8", $text);
}

/**
 * An XML reply.
 *
 * @param text {string} the document
 * @return {Canned} the reply
 */
func xmlReply(text as string) {
    return Canned{
        status: 200,
        contentType: "text/xml",
        retryAfter: "",
        location: "",
        body: utf8($text)
    };
}

/**
 * A reply with a status and no body.
 *
 * @param code {int} the status
 * @return {Canned} the reply
 */
func bareReply(code as int) {
    return Canned{status: $code, contentType: "", retryAfter: "", location: "", body: utf8("")};
}

/**
 * The 201 that creates a job.
 *
 * @param location {string} the `Location` header, `""` for none
 * @return {Canned} the reply
 */
func created(location as string) {
    return Canned{
        status: 201,
        contentType: "",
        retryAfter: "",
        location: $location,
        body: utf8("")
    };
}

/**
 * A page.
 *
 * @param contentType {string} its type
 * @param text {string} stand-in content
 * @return {Canned} the reply
 */
func pageReply(contentType as string, text as string) {
    return Canned{
        status: 200,
        contentType: $contentType,
        retryAfter: "",
        location: "",
        body: utf8($text)
    };
}

/**
 * A `ScannerStatus` document.
 *
 * @param adf {string} the `AdfState`, `""` for none
 * @param jobState {string} the one job's state, `""` for no job
 * @param reason {string} its reason
 * @return {string} the XML
 */
func statusXml(adf as string, jobState as string, reason as string) {
    def x as string init '<?xml version="1.0" encoding="UTF-8"?>' +
        '<scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"' +
        ' xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">' +
        '<pwg:Version>2.63</pwg:Version><pwg:State>Idle</pwg:State>';
    if ($adf != "") {
        $x = $x + "<scan:AdfState>{$adf}</scan:AdfState>";
    }
    if ($jobState != "") {
        $x = $x + "<scan:Jobs><scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/42</pwg:JobUri>" +
            "<pwg:JobUuid>42</pwg:JobUuid><scan:Age>3</scan:Age>" +
            "<pwg:ImagesCompleted>1</pwg:ImagesCompleted>" +
            "<pwg:ImagesToTransfer>0</pwg:ImagesToTransfer>" +
            "<pwg:JobState>{$jobState}</pwg:JobState>" +
            "<pwg:JobStateReasons><pwg:JobStateReason>{$reason}</pwg:JobStateReason>" +
            "</pwg:JobStateReasons></scan:JobInfo></scan:Jobs>";
    }
    return $x + "</scan:ScannerStatus>";
}

/**
 * The feeder settings for the Epson fixture.
 *
 * @param duplex {bool} both sides
 * @return {Settings} the settings
 */
func feederSettings(duplex as bool) {
    def st as Settings init settings();
    $st.source = FEEDER;
    $st.duplex = $duplex;
    return $st;
}

/**
 * The message `check` throws for these settings, `""` if none.
 *
 * @param caps {Capabilities} the capabilities
 * @param st {Settings} the settings
 * @return {string} the message
 */
func checkError(caps as Capabilities, st as Settings) {
    try {
        check($caps, $st);
    } catch (e) {
        return $e.message;
    }
    return "";
}

/**
 * The message `scanner` throws for an address, `""` if none.
 *
 * @param address {string} the address
 * @return {string} the message
 */
func addressError(address as string) {
    try {
        scanner($address);
    } catch (e) {
        return $e.kind + ": " + $e.message;
    }
    return "";
}

# --- addresses ------------------------------------------------------------

func testScannerAddressForms() {
    def a as Scanner init scanner("192.168.1.40");
    testing.assertEqual($a.origin, "http://192.168.1.40");
    testing.assertEqual($a.base, "http://192.168.1.40/eSCL");
    testing.assertEqual(scanner("  printer.local:8080 ").base, "http://printer.local:8080/eSCL");
    def c as Scanner init scanner("HTTPS://10.0.0.5:443/eSCL/");
    testing.assertEqual($c.origin, "https://10.0.0.5:443");
    testing.assertEqual($c.base, "https://10.0.0.5:443/eSCL");
    testing.assertEqual(
        scanner("http://[fe80::1]:8080/scan/escl").base,
        "http://[fe80::1]:8080/scan/escl");
    testing.assertEqual(scanner("http://host/").base, "http://host/eSCL");
}

func testScannerFillsDefaults() {
    def s as Scanner init scanner("host");
    testing.assertEqual($s.options.timeoutMs, DEFAULT_TIMEOUT_MS);
    testing.assertEqual($s.options.busyWaitMs, DEFAULT_BUSY_WAIT_MS);
    testing.assertEqual($s.options.retryMs, DEFAULT_RETRY_MS);
    testing.assertEqual($s.options.maxPageBytes, DEFAULT_MAX_PAGE_BYTES);
}

func testScannerRefusesMalformedAddresses() {
    for (def bad in [
        "",
        "ftp://host",
        "host:0",
        "host:65536",
        "host:80x",
        "ho st",
        "host/../x",
        "host/a//b",
        "[fe80::1",
        "[fe80::1]x",
        "[zz]",
        "host:",
        "[::1]:",
        "http://host?x=1/"
    ]) {
        testing.assertContains(addressError($bad), "escl: escl: ");
    }
    def o as Options;
    $o.retryMs = -1;
    def msg as string init "";
    try {
        scannerWith("host", $o);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertEqual($msg, "escl: options must not be negative");
}

func testJobUrlTakesOnlyThePath() {
    def s as Scanner init scanner("10.0.0.7:8080");
    # a device naming itself by a host the client cannot reach
    testing.assertEqual(
        jobUrl($s, "http://NPI6142D.local.:80/eSCL/ScanJobs/42"),
        "http://10.0.0.7:8080/eSCL/ScanJobs/42");
    testing.assertEqual(jobUrl($s, "/eSCL/ScanJobs/42/"), "http://10.0.0.7:8080/eSCL/ScanJobs/42");
    testing.assertEqual(jobUrl($s, "ScanJobs/42"), "http://10.0.0.7:8080/eSCL/ScanJobs/42");
    # every character RFC 3986 allows in a path segment
    testing.assertEqual(
        jobUrl($s, "/eSCL/ScanJobs/a+b;c=1,d:e@f!$&'()*~%20"),
        "http://10.0.0.7:8080/eSCL/ScanJobs/a+b;c=1,d:e@f!$&'()*~%20");
    for (def bad in [
        "",
        "   ",
        "http://host",
        "/eSCL/../x",
        "/eSCL/ScanJobs/4 2",
        "/eSCL/ScanJobs/42?x",
        "/eSCL/ScanJobs/42#x",
        "/eSCL/ScanJobs/<42>"
    ]) {
        def msg as string init "";
        try {
            jobUrl($s, $bad);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, "escl: ");
    }
}

# --- documents ------------------------------------------------------------

func testParseCapabilitiesPlaten() {
    def c as Capabilities init parseCapabilities(HP_CAPS);
    testing.assertEqual($c.version, "2.63");
    testing.assertEqual($c.makeAndModel, "HP LaserJet MFP M28w");
    testing.assertEqual($c.serialNumber, "VNC1234567");
    testing.assertEqual($c.adminUri, "http://NPI6142D.local.");
    testing.assertFalse($c.formatExt);
    testing.assertEqual(len($c.inputs), 1);
    def p as Input init $c.inputs[0];
    testing.assertEqual($p.source, PLATEN);
    testing.assertFalse($p.duplex);
    testing.assertEqual($p.maxWidth, 2550);
    testing.assertEqual($p.maxHeight, 3508);
    testing.assertEqual($p.minWidth, 8);
    testing.assertEqual($p.colorModes, ["BlackAndWhite1", "Grayscale8", "RGB24"]);
    testing.assertEqual($p.formats, ["image/jpeg", "application/pdf"]);
    # sorted, and 1200x600 left out: a resolution here is the same for X and Y
    testing.assertEqual($p.resolutions, [75, 300, 600]);
    testing.assertEqual(len($p.resolutionRanges), 0);
    testing.assertEqual($p.intents, ["Document", "Photo", "TextAndGraphic"]);
}

func testParseCapabilitiesFeeder() {
    def c as Capabilities init parseCapabilities(EPSON_CAPS);
    testing.assertEqual($c.makeAndModel, "EPSON ES-C380W");
    testing.assertTrue($c.formatExt);
    testing.assertEqual($c.feederOptions, ["DetectPaperLoaded", "Duplex"]);
    testing.assertEqual(len($c.inputs), 2);
    def simplex as Input init $c.inputs[0];
    testing.assertEqual($simplex.source, FEEDER);
    testing.assertFalse($simplex.duplex);
    # the two setting profiles merge
    testing.assertEqual($simplex.colorModes, ["Grayscale8", "RGB24", "BlackAndWhite1"]);
    testing.assertEqual($simplex.formats, ["image/jpeg", "application/pdf", "image/png"]);
    testing.assertEqual(len($simplex.resolutions), 0);
    testing.assertEqual($simplex.resolutionRanges, [Range{min: 50, max: 600, step: 50}]);
    def duplex as Input init $c.inputs[1];
    testing.assertTrue($duplex.duplex);
    testing.assertEqual($duplex.maxHeight, 3600);
    testing.assertEqual($duplex.resolutions, [200, 300]);
}

func testDuplexOptionWithoutDuplexCapsUsesSimplex() {
    def x as string init strings.replace(EPSON_CAPS, "AdfDuplexInputCaps", "UnknownCaps");
    def c as Capabilities init parseCapabilities($x);
    testing.assertEqual(len($c.inputs), 2);
    testing.assertTrue($c.inputs[1].duplex);
    testing.assertEqual($c.inputs[1].maxHeight, 4200);
    # without the Duplex option there is no duplex input
    def y as string init strings.replace($x, "<AdfOption>Duplex</AdfOption>", "");
    testing.assertEqual(len(parseCapabilities($y).inputs), 1);
}

func testParseCapabilitiesRefusesBadDocuments() {
    def caps as string init "<ScannerCapabilities><Platen><PlatenInputCaps>";
    def end as string init "</PlatenInputCaps></Platen></ScannerCapabilities>";
    def cases as map of string to string init {
        "<a>": "malformed XML",
        "<scan:ScannerStatus xmlns:scan='u'/>": "expected a ScannerCapabilities document",
        "<ScannerCapabilities><Version>2.0</Version></ScannerCapabilities>": "no platen and no feeder"
    };
    $cases[$caps + "<MaxWidth>2550</MaxWidth>" + $end] = "lack MaxWidth or MaxHeight";
    $cases[$caps + "<MaxWidth>-1</MaxWidth><MaxHeight>9</MaxHeight>" + $end] = "<MaxWidth> must be a number";
    for (def text in $cases) {
        def msg as string init "";
        def kind as string init "";
        try {
            parseCapabilities($text);
        } catch (e) {
            $msg = $e.message;
            $kind = $e.kind;
        }
        # a malformed document is the deck's error, not a reached cap
        testing.assertEqual($kind, "escl");
        testing.assertContains($msg, $cases[$text]);
    }
}

func testParseStatus() {
    def st as Status init parseStatus(statusXml("ScannerAdfJam", "Aborted", "JobCanceledByUser"));
    testing.assertEqual($st.state, "Idle");
    testing.assertEqual($st.adfState, "ScannerAdfJam");
    testing.assertEqual(len($st.jobs), 1);
    def j as JobInfo init $st.jobs[0];
    testing.assertEqual($j.uri, "/eSCL/ScanJobs/42");
    testing.assertEqual($j.uuid, "42");
    testing.assertEqual($j.age, 3);
    testing.assertEqual($j.imagesCompleted, 1);
    testing.assertEqual($j.state, "Aborted");
    testing.assertEqual($j.reasons, ["JobCanceledByUser"]);
    def idle as Status init parseStatus(statusXml("", "", ""));
    testing.assertEqual($idle.adfState, "");
    testing.assertEqual(len($idle.jobs), 0);
    def msg as string init "";
    try {
        parseStatus("<ScannerStatus/>");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "no State");
}

# --- settings -------------------------------------------------------------

func testCheckFillsTheScanArea() {
    def caps as Capabilities init parseCapabilities(HP_CAPS);
    def st as Settings init check($caps, settings());
    testing.assertEqual($st.width, 2550);
    testing.assertEqual($st.height, 3508);
    def part as Settings init settings();
    $part.x = 100;
    $part.y = 200;
    $part.height = fromMm(100.0);
    def got as Settings init check($caps, $part);
    testing.assertEqual($got.width, 2450);
    testing.assertEqual($got.height, 1181);
}

func testCheckAcceptsARangedResolution() {
    def caps as Capabilities init parseCapabilities(EPSON_CAPS);
    def st as Settings init feederSettings(false);
    $st.resolution = 450;
    testing.assertEqual(check($caps, $st).resolution, 450);
}

func testCheckNamesWhatThePlatenLacks() {
    def hp as Capabilities init parseCapabilities(HP_CAPS);
    def a as Settings init settings();
    $a.colorMode = "RGB48";
    testing.assertContains(
        checkError($hp, $a),
        "color mode \"RGB48\" not offered; the scanner has BlackAndWhite1, Grayscale8, RGB24");
    def b as Settings init settings();
    $b.resolution = 1200;
    testing.assertContains(
        checkError($hp, $b),
        "1200 dpi not offered; the scanner has 75, 300, 600");
    def c as Settings init settings();
    $c.format = "image/png";
    testing.assertContains(checkError($hp, $c), "format \"image/png\" not offered");
    def d as Settings init settings();
    $d.intent = "Preview";
    testing.assertContains(
        checkError($hp, $d),
        "intent \"Preview\" not offered; the scanner has Document, Photo, TextAndGraphic");
    def e as Settings init settings();
    $e.x = 2600;
    testing.assertContains(checkError($hp, $e), "the scan area must be 8 to 2550 wide");
    def f as Settings init settings();
    $f.height = 3600;
    testing.assertContains(checkError($hp, $f), "the scan area must be 8 to 3508 high");
    def g as Settings init settings();
    $g.duplex = true;
    testing.assertContains(checkError($hp, $g), "duplex needs the feeder");
    def h as Settings init settings();
    $h.source = "Camera";
    testing.assertContains(checkError($hp, $h), "source must be escl.PLATEN or escl.FEEDER");
    testing.assertContains(checkError($hp, feederSettings(false)), "the scanner has no feeder");
    def j as Settings init settings();
    $j.width = -5;
    testing.assertContains(checkError($hp, $j), "must not be negative");
}

func testCheckNamesWhatTheFeederLacks() {
    def epson as Capabilities init parseCapabilities(EPSON_CAPS);
    testing.assertContains(checkError($epson, settings()), "the scanner has no platen");
    def q as Settings init feederSettings(false);
    $q.resolution = 425;
    testing.assertContains(
        checkError($epson, $q),
        "425 dpi not offered; the scanner has 50-600 in steps of 50");
    def r as Settings init feederSettings(true);
    $r.colorMode = "Grayscale8";
    testing.assertContains(
        checkError($epson, $r),
        "color mode \"Grayscale8\" not offered; the scanner has RGB24");
}

func testSettingsXmlPlaten() {
    def caps as Capabilities init parseCapabilities(HP_CAPS);
    def st as Settings init settings();
    $st.intent = "Document";
    def x as string init settingsXml($caps, $st);
    def root as xml.Value init xml.decode($x);
    testing.assertEqual(local($root), "ScanSettings");
    testing.assertEqual(textAt($root, "Version"), "2.63");
    testing.assertEqual(textAt($root, "Intent"), "Document");
    testing.assertEqual(textAt($root, "InputSource"), "Platen");
    testing.assertEqual(textAt($root, "ColorMode"), "RGB24");
    testing.assertEqual(textAt($root, "XResolution"), "300");
    testing.assertEqual(textAt($root, "YResolution"), "300");
    testing.assertEqual(textAt($root, "DocumentFormat"), "image/jpeg");
    testing.assertFalse(hasKid($root, "DocumentFormatExt"));
    testing.assertFalse(hasKid($root, "Duplex"));
    def region as xml.Value init kid(kid($root, "ScanRegions"), "ScanRegion");
    testing.assertEqual(textAt($region, "Width"), "2550");
    testing.assertEqual(textAt($region, "Height"), "3508");
    testing.assertEqual(textAt($region, "ContentRegionUnits"), "escl:ThreeHundredthsOfInches");
    testing.assertContains($x, 'xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"');
    testing.assertContains($x, 'xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"');
}

func testSettingsXmlFeeder() {
    def caps as Capabilities init parseCapabilities(EPSON_CAPS);
    def root as xml.Value init xml.decode(settingsXml($caps, feederSettings(true)));
    testing.assertEqual(textAt($root, "InputSource"), "Feeder");
    testing.assertEqual(textAt($root, "Duplex"), "true");
    testing.assertEqual(textAt($root, "DocumentFormatExt"), "image/jpeg");
    testing.assertEqual(textAt(kid(kid($root, "ScanRegions"), "ScanRegion"), "Height"), "3600");
    def single as xml.Value init xml.decode(settingsXml($caps, feederSettings(false)));
    testing.assertEqual(textAt($single, "Duplex"), "false");
}

func testSmallHelpers() {
    testing.assertEqual(fromMm(210.0), 2480);
    testing.assertEqual(fromMm(297.0), 3508);
    testing.assertEqual(fromMm(0.0), 0);
    testing.assertEqual(extension("image/jpeg"), "jpg");
    testing.assertEqual(extension("IMAGE/JPEG; charset=binary"), "jpg");
    testing.assertEqual(extension("application/pdf"), "pdf");
    testing.assertEqual(extension("image/png"), "png");
    testing.assertEqual(extension("image/tiff"), "tif");
    testing.assertEqual(extension("application/octet-stream"), "bin");
    testing.assertEqual(shown("a\nb"), "\"a?b\"");
    testing.assertEqual(fileName("/tmp/", "scan", 7, "jpg", 3), "/tmp/scan-007.jpg");
    testing.assertEqual(fileName("out", "scan", 1234, "pdf", 3), "out/scan-1234.pdf");
    testing.assertEqual(fileName("out", "scan", 7, "pdf", 4), "out/scan-0007.pdf");
}

# --- jobs against a fake scanner ------------------------------------------

func testScanPlaten() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("http://NPI6142D.local.:8080/eSCL/ScanJobs/42"),
        bareReply(503),
        pageReply("image/jpeg", "JPEG-1"),
        xmlReply(statusXml("", "Completed", "JobCompletedSuccessfully")),
        bareReply(204)
    ]);
    def pages as list of Page init scan(on($f), settings());
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(len($pages), 1);
    testing.assertEqual($pages[0].contentType, "image/jpeg");
    testing.assertEqual(convert.stringFromBytes("utf-8", $pages[0].data), "JPEG-1");
    def calls as list of string init [];
    for (def s in $seen) {
        $calls[] = $s.method + " " + $s.path;
    }
    testing.assertEqual(
        $calls,
        [
            "GET /eSCL/ScannerCapabilities",
            "POST /eSCL/ScanJobs",
            "GET /eSCL/ScanJobs/42/NextDocument",
            "GET /eSCL/ScanJobs/42/NextDocument",
            "GET /eSCL/ScannerStatus",
            "DELETE /eSCL/ScanJobs/42"
        ]);
    testing.assertContains($seen[1].body, "<pwg:InputSource>Platen</pwg:InputSource>");
}

func testScanFeederDuplex() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "front"),
        pageReply("image/jpeg", "back"),
        bareReply(404),
        xmlReply(statusXml("ScannerAdfEmpty", "Completed", "JobCompletedSuccessfully")),
        bareReply(204)
    ]);
    def pages as list of Page init scan(on($f), feederSettings(true));
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(len($pages), 2);
    testing.assertEqual(convert.stringFromBytes("utf-8", $pages[1].data), "back");
    testing.assertEqual($seen[1].path, "/eSCL/ScannerStatus");
    testing.assertContains($seen[2].body, "<scan:Duplex>true</scan:Duplex>");
}

func testEmptyFeederIsRefusedBeforeTheJob() {
    def f as Fake init fake([xmlReply(EPSON_CAPS), xmlReply(statusXml("ScannerAdfEmpty", "", ""))]);
    def msg as string init "";
    try {
        scan(on($f), feederSettings(false));
    } catch (e) {
        $msg = $e.message;
    }
    def seen as list of Seen init stopFake($f);
    testing.assertEqual($msg, "escl: the feeder is empty");
    testing.assertEqual(len($seen), 2);
}

func testJamAbortsAndCancels() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "front"),
        bareReply(404),
        xmlReply(statusXml("ScannerAdfJam", "Aborted", "JobCanceledBySystem")),
        bareReply(200)
    ]);
    def msg as string init "";
    try {
        scan(on($f), feederSettings(false));
    } catch (e) {
        $msg = $e.message;
    }
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(
        $msg,
        "escl: the scanner aborted the job after 1 page(s) (JobCanceledBySystem), feeder: ScannerAdfJam");
    testing.assertEqual($seen[6].method, "DELETE");
    testing.assertEqual($seen[6].path, "/eSCL/ScanJobs/42");
}

func testFailedCancelIsAddedToTheError() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/42"),
        bareReply(500),
        bareReply(500)
    ]);
    def msg as string init "";
    try {
        scan(on($f), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertEqual(
        $msg,
        "escl: page 1: HTTP 500; cancelling the job failed too: escl: cancel: HTTP 500");
}

func testNoPagesIsAnError() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/42"),
        bareReply(404),
        xmlReply(statusXml("", "", "")),
        bareReply(404)
    ]);
    def msg as string init "";
    try {
        scan(on($f), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertEqual($msg, "escl: the scanner returned no pages");
}

func testRefusedJob() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        Canned{
            status: 409,
            contentType: "text/plain",
            retryAfter: "",
            location: "",
            body: utf8("Conflict\nmore")
        }
    ]);
    def msg as string init "";
    try {
        scan(on($f), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertEqual(
        $msg,
        "escl: the scanner refused the job (HTTP 409): it is busy, or the input is empty: \"Conflict\"");
}

func testBusyScannerGivesUp() {
    def replies as list of Canned init [xmlReply(HP_CAPS)];
    for (def k in 0..100) {
        $replies[] = bareReply(503);
    }
    def f as Fake init fake($replies);
    def s as Scanner init on($f);
    $s.options.busyWaitMs = 50;
    def caps as Capabilities init capabilities($s);
    def msg as string init "";
    try {
        start($s, $caps, settings());
    } catch (e) {
        $msg = $e.message;
    }
    httpd.shutdown($f.srv);
    task.discard($f.t);
    testing.assertEqual($msg, "escl: the scanner stayed busy for 50 ms");
}

func testMissingLocationIsAnError() {
    def f as Fake init fake([xmlReply(HP_CAPS), created("")]);
    def s as Scanner init on($f);
    def msg as string init "";
    try {
        start($s, capabilities($s), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertContains($msg, "no usable job location");
    testing.assertContains($msg, "the scanner may stay busy");
}

func testUnreachableScanner() {
    def o as Options;
    $o.timeoutMs = 2000;
    def s as Scanner init scannerWith("127.0.0.1:1", $o);
    def msg as string init "";
    def kind as string init "";
    try {
        status($s);
    } catch (e) {
        $msg = $e.message;
        $kind = $e.kind;
    }
    testing.assertEqual($kind, "escl");
    testing.assertTrue(strings.startsWith(
        $msg,
        "escl: GET http://127.0.0.1:1/eSCL/ScannerStatus: "));
}

func testScanToFiles() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "one"),
        pageReply("image/jpeg; q=1", "two"),
        bareReply(404),
        xmlReply(statusXml("", "Completed", "JobCompletedSuccessfully")),
        bareReply(204)
    ]);
    def files as list of string init scanToFiles(on($f), feederSettings(false), $dir, "letter");
    stopFake($f);
    testing.assertEqual($files, [$dir + "/letter-001.jpg", $dir + "/letter-002.jpg"]);
    testing.assertEqual(convert.stringFromBytes("utf-8", fs.readBytes($files[1])), "two");

    # the first name is taken: refused before any job
    def g as Fake init fake([xmlReply(EPSON_CAPS)]);
    def msg as string init "";
    try {
        scanToFiles(on($g), feederSettings(false), $dir, "letter");
    } catch (e) {
        $msg = $e.message;
    }
    def seen as list of Seen init stopFake($g);
    testing.assertContains($msg, "will not overwrite");
    testing.assertEqual(len($seen), 1);
}

func testScanToFilesRefusesABadStem() {
    for (def bad in ["", ".hidden", "a/b", "a b"]) {
        def m as string init "";
        try {
            scanToFiles(scanner("127.0.0.1:1"), settings(), ".", $bad);
        } catch (e) {
            $m = $e.message;
        }
        testing.assertContains($m, "file stem");
    }
}

func testStepByStep() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/7"),
        pageReply("image/png", "P1"),
        bareReply(404),
        bareReply(404)
    ]);
    def s as Scanner init on($f);
    def job as Job init start($s, capabilities($s), settings());
    testing.assertEqual($job.url, $s.origin + "/eSCL/ScanJobs/7");
    def first as Page init nextPage($job);
    testing.assertFalse($first.done);
    testing.assertEqual($first.contentType, "image/png");
    testing.assertTrue(nextPage($job).done);
    # a job the scanner has already forgotten counts as cancelled
    cancel($job);
    def seen as list of Seen init stopFake($f);
    testing.assertEqual($seen[4].method, "DELETE");
    testing.assertEqual($seen[4].path, "/eSCL/ScanJobs/7");
}

func testCancelRefused() {
    def f as Fake init fake([bareReply(403)]);
    def job as Job init Job{
        scanner: on($f),
        url: on($f).origin + "/eSCL/ScanJobs/7",
        pages: 0,
        bytes: 0,
        platen: false
    };
    def msg as string init "";
    try {
        cancel($job);
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertEqual($msg, "escl: cancel: HTTP 403");
}

func testPageCapStopsARunawayJob() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "1"),
        pageReply("image/jpeg", "2"),
        pageReply("image/jpeg", "3"),
        bareReply(200)
    ]);
    def s as Scanner init on($f);
    $s.options.maxPages = 2;
    def msg as string init "";
    def kind as string init "";
    try {
        scan($s, feederSettings(false));
    } catch (e) {
        $msg = $e.message;
        $kind = $e.kind;
    }
    testing.assertEqual($kind, "limit");
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(
        $msg,
        "escl: the job gave more than 2 pages; raise Options.maxPages for longer jobs");
    testing.assertEqual($seen[6].method, "DELETE");
    testing.assertEqual(scanner("host").options.maxPages, DEFAULT_MAX_PAGES);
}

func testHugeAreaIsAnEsclErrorNotAnOverflow() {
    def caps as Capabilities init parseCapabilities(HP_CAPS);
    def st as Settings init settings();
    $st.x = 9223372036854775807;
    $st.width = 9223372036854775807;
    testing.assertContains(checkError($caps, $st), "escl: the scan area must be 8 to 2550 wide");
    def msg as string init "";
    try {
        fromMm(1.0e300);
    } catch (e) {
        $msg = $e.kind + " " + $e.message;
    }
    testing.assertEqual($msg, "escl escl: a length must be 0 to 10000 mm, got 1e+300");
}

func testDeviceTextInErrorsIsClipped() {
    def tag as string init strings.repeat("x", 500);
    def msg as string init "";
    try {
        parseStatus("<" + $tag + "/>");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertTrue(len($msg) < 140);
    testing.assertContains($msg, "...");
}

func testRetryAfterIsHonoured() {
    def busy as Canned init bareReply(503);
    $busy.retryAfter = "1";
    def f as Fake init fake([xmlReply(HP_CAPS), $busy, xmlReply(statusXml("", "", ""))]);
    def s as Scanner init on($f);
    $s.options.busyWaitMs = 5000;
    def t0 as time.Time init time.now();
    capabilities($s);
    status($s);
    def took as int init time.milliseconds(time.sub(time.now(), $t0));
    stopFake($f);
    # retryMs is 10; the scanner asked for a second
    testing.assertTrue($took >= 1000);
}

func testScanToFilesNeverWritesThroughALink() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    def target as string init $dir + "/precious.txt";
    fs.writeString($target, "keep me");
    fs.symlink($target, $dir + "/doc-002.jpg");
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "one"),
        pageReply("image/jpeg", "two"),
        bareReply(200)
    ]);
    def msg as string init "";
    try {
        scanToFiles(on($f), feederSettings(false), $dir, "doc");
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertContains($msg, "will not overwrite");
    testing.assertContains(
        $msg,
        "1 page(s) were written, " + $dir + "/doc-001.jpg to " + $dir + "/doc-001.jpg");
    testing.assertEqual(fs.readString($target), "keep me");
}

# --- discovery ------------------------------------------------------------

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
 * Join byte strings.
 *
 * @param parts {list of bytes} the parts
 * @return {bytes} them, in order
 */
func cat(parts as list of bytes) {
    def out as bytes;
    for (def p in $parts) {
        for (def i in 0..len($p)) {
            $out[] = $p[$i];
        }
    }
    return $out;
}

/**
 * A resource record, the owner given in wire form.
 *
 * @param owner {bytes} the owner name, encoded
 * @param kind {int} the record type
 * @param data {bytes} the record data
 * @return {bytes} the record
 */
func rr(owner as bytes, kind as int, data as bytes) {
    return cat([
        $owner,
        raw([0, $kind, 128, 1, 0, 0, 17, 148, len($data) // 256, len($data) % 256]),
        $data
    ]);
}

/**
 * A name in wire form.
 *
 * @param name {string} the dotted name
 * @return {bytes} the encoded name
 */
func wire(name as string) {
    def none as bytes;
    return putName($none, $name);
}

/**
 * A DNS response carrying these records as answers.
 *
 * @param records {list of bytes} the records
 * @return {bytes} the message
 */
func answer(records as list of bytes) {
    return cat([
        raw([0, 0, 132, 0, 0, 0, len($records) // 256, len($records) % 256, 0, 0, 0, 0]),
        cat($records)
    ]);
}

/**
 * TXT record data from strings.
 *
 * @param entries {list of string} the strings
 * @return {bytes} the data
 */
func txtData(entries as list of string) {
    def out as list of bytes init [];
    for (def e in $entries) {
        def b as bytes init utf8($e);
        $out[] = raw([len($b)]);
        $out[] = $b;
    }
    return cat($out);
}

/**
 * Answer one query with these packets.
 *
 * @param sock {net.UDPSocket} the responder's socket
 * @param packets {list of bytes} what to send back
 * @return {bytes} the query received
 */
func respondMdns(sock as net.UDPSocket, packets as list of bytes) {
    def q as net.Datagram init net.recvFrom($sock, 9000);
    for (def p in $packets) {
        net.sendTo($sock, $q.peer, $p);
    }
    return $q.data;
}

func testDiscover() {
    def hpName as string init "HP LaserJet MFP M28w._uscan._tcp.local";
    # one packet with every record, the SRV owner compressed to the PTR's data
    # (offset 12 + 19 for the owner + 10 for the record header)
    def hp as bytes init answer([
        rr(wire("_uscan._tcp.local"), 12, wire($hpName)),
        rr(raw([192, 41]), 33, cat([raw([0, 0, 0, 0, 31, 144]), wire("NPI6142D.local")])),
        rr(
            wire($hpName),
            16,
            txtData(["txtvers=1", "rs=/eSCL", "ty=HP LaserJet MFP M28w", "UUID=564e4333"])),
        rr(wire("NPI6142D.local"), 1, raw([192, 168, 1, 40]))
    ]);
    def epsonName as string init "EPSON ES-C380W._uscans._tcp.local";
    def epson as bytes init answer([
        rr(wire("_uscans._tcp.local"), 12, wire($epsonName)),
        rr(wire($epsonName), 33, cat([raw([0, 0, 0, 0, 1, 187]), wire("EPSON1A2B3C.local")])),
        rr(wire($epsonName), 16, txtData(["RS=eSCL", "ty=EPSON ES-C380W"]))
    ]);
    def loop as bytes init answer([rr(raw([192, 12]), 12, wire("x.local"))]);
    def query as bytes init raw([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    def other as bytes init answer([
        rr(wire("_ipp._tcp.local"), 12, wire("Printer._ipp._tcp.local"))
    ]);
    def sock as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def t as task of bytes init spawn {
        return respondMdns($sock, [$loop, $hp, $query, $other, $epson, $hp]);
    };
    def found as list of Found init discoverAt(net.address($sock), 500);
    def q as bytes init task.wait($t);
    net.close($sock);
    testing.assertEqual($q, mdnsQuery());
    testing.assertEqual(len($found), 2);
    def a as Found init $found[0];
    testing.assertEqual($a.name, "HP LaserJet MFP M28w");
    testing.assertEqual($a.host, "npi6142d.local");
    testing.assertEqual($a.address, "192.168.1.40");
    testing.assertEqual($a.port, 8080);
    testing.assertFalse($a.secure);
    testing.assertEqual($a.root, "eSCL");
    testing.assertEqual($a.model, "HP LaserJet MFP M28w");
    testing.assertEqual($a.uuid, "564e4333");
    testing.assertEqual($a.url, "http://192.168.1.40:8080/eSCL");
    def b as Found init $found[1];
    testing.assertTrue($b.secure);
    testing.assertEqual($b.address, "");
    testing.assertEqual($b.url, "https://epson1a2b3c.local:443/eSCL");
    testing.assertEqual(scanner($b.url).base, $b.url);
}

func testDiscoverChecksItsTimeout() {
    for (def bad in [0, -1, 60001]) {
        def msg as string init "";
        try {
            discover($bad);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, "timeoutMs must be 1 to 60000");
    }
}

func testQueryAsksForUnicastPtrAnswers() {
    def q as bytes init mdnsQuery();
    testing.assertEqual(u16($q, 4), 2);
    def first as NameAt init readName($q, 12);
    testing.assertEqual($first.name, USCAN);
    testing.assertEqual(u16($q, $first.next), 12);
    testing.assertEqual(u16($q, $first.next + 2), 32769);
    testing.assertEqual(readName($q, $first.next + 4).name, USCANS);
}

func testMalformedAnswersAreRefused() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def cases as list of bytes init [
        answer([rr(raw([192, 12]), 12, wire("x.local"))]),
        answer([rr(raw([5, 97]), 12, wire("x.local"))]),
        cat([answer([rr(wire("a.local"), 16, raw([9, 97]))])]),
        raw([0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 97, 0, 0, 12, 0, 1, 0, 0, 0, 0, 0, 50])
    ];
    for (def m in $cases) {
        def msg as string init "";
        try {
            absorb($empty, $m);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, "escl: mDNS: ");
    }
}

# --- adjustments, login, image info, scanEach -----------------------------

/**
 * The HP fixture with brightness at the root (signed, no Normal) and
 * contrast inside the platen's capabilities.
 *
 * @return {Capabilities} the capabilities
 */
func adjustableCaps() {
    def x as string init strings.replace(
        HP_CAPS,
        "<scan:Platen>",
        "<scan:BrightnessSupport><scan:Min>-100</scan:Min><scan:Max>100</scan:Max>" +
            "<scan:Step>5</scan:Step></scan:BrightnessSupport><scan:Platen>");
    $x = strings.replace(
        $x,
        "<scan:MaxScanRegions>",
        "<scan:ContrastSupport><scan:Min>0</scan:Min><scan:Max>2000</scan:Max>" +
            "<scan:Normal>1000</scan:Normal><scan:Step>1</scan:Step></scan:ContrastSupport><scan:MaxScanRegions>");
    $x = strings.replace(
        $x,
        "<scan:MaxScanRegions>",
        "<scan:SharpenSupport><scan:Min>5</scan:Min><scan:Max>1</scan:Max></scan:SharpenSupport><scan:MaxScanRegions>");
    return parseCapabilities($x);
}

func testAdjustmentsAreReadWhereverTheyAre() {
    def c as Capabilities init adjustableCaps();
    testing.assertEqual(maps.keys($c.adjustments), ["Contrast", "Brightness"]);
    def b as Adjustment init $c.adjustments["Brightness"];
    testing.assertEqual($b.min, -100);
    testing.assertEqual($b.max, 100);
    testing.assertEqual($b.step, 5);
    testing.assertEqual($b.normal, 0);
    testing.assertEqual($c.adjustments["Contrast"].normal, 1000);
    # max below min: not offered
    testing.assertFalse(maps.has($c.adjustments, "Sharpen"));
    testing.assertEqual(len(parseCapabilities(HP_CAPS).adjustments), 0);
}

func testAdjustmentsAreCheckedAndSent() {
    def c as Capabilities init adjustableCaps();
    def st as Settings init settings();
    $st.adjust = {"Brightness": -15, "Contrast": 1200};
    def root as xml.Value init xml.decode(settingsXml($c, $st));
    testing.assertEqual(textAt($root, "Brightness"), "-15");
    testing.assertEqual(textAt($root, "Contrast"), "1200");
    testing.assertFalse(hasKid($root, "Sharpen"));
    def x as string init settingsXml($c, $st);
    testing.assertTrue(strings.indexOf($x, "<scan:Contrast>") <
        strings.indexOf($x, "<scan:Brightness>"));
    $st.adjust = {"Brightness": 7};
    testing.assertContains(
        checkError($c, $st),
        "brightness must be -100 to 100 in steps of 5 (normal 0), got 7");
    $st.adjust = {"Brightness": 105};
    testing.assertContains(checkError($c, $st), "got 105");
    $st.adjust = {"Sharpen": 1};
    testing.assertContains(checkError($c, $st), "sharpen is not adjustable on this scanner");
    $st.adjust = {"Gamma": 1};
    testing.assertContains(checkError($c, $st), "unknown adjustment \"Gamma\"");
}

func testLoginRules() {
    def o as Options;
    $o.username = "scan";
    $o.password = "pa:ss";
    testing.assertEqual(scannerWith("https://10.0.0.5", $o).options.username, "scan");
    def cases as map of string to string init {
        "http://10.0.0.5": "refusing to send a login over plain http",
        "10.0.0.5": "refusing to send a login over plain http"
    };
    for (def addr in $cases) {
        def msg as string init "";
        try {
            scannerWith($addr, $o);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, $cases[$addr]);
    }
    $o.allowPlainAuth = true;
    testing.assertEqual(scannerWith("10.0.0.5", $o).origin, "http://10.0.0.5");
    def bad as list of Options init [$o, $o, $o];
    $bad[0].username = "a:b";
    $bad[1].username = "";
    $bad[2].password = "x\ny";
    def wants as list of string init [
        "cannot contain ':'",
        "a password needs a username",
        "control character"
    ];
    for (def k in 0..3) {
        def msg as string init "";
        try {
            scannerWith("https://h", $bad[$k]);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, $wants[$k]);
    }
}

func testLoginIsSentAndRefusalsExplained() {
    def f as Fake init fake([xmlReply(HP_CAPS), bareReply(401)]);
    def o as Options;
    $o.username = "scan";
    $o.password = "secret";
    $o.allowPlainAuth = true;
    $o.timeoutMs = 5000;
    def s as Scanner init scannerWith($f.address, $o);
    capabilities($s);
    def msg as string init "";
    try {
        status($s);
    } catch (e) {
        $msg = $e.message;
    }
    def seen as list of Seen init stopFake($f);
    testing.assertEqual($seen[0].auth, http.basic("scan", "secret"));
    testing.assertEqual($msg, "escl: GET ScannerStatus: HTTP 401 (the login was refused)");
    def g as Fake init fake([bareReply(401)]);
    def m2 as string init "";
    try {
        status(on($g));
    } catch (e) {
        $m2 = $e.message;
    }
    def seen2 as list of Seen init stopFake($g);
    testing.assertEqual($seen2[0].auth, "");
    testing.assertContains($m2, "the scanner wants a login");
}

func testImageInfo() {
    def info as string init "<scan:ScanImageInfo xmlns:scan=\"" + SCAN_NS + "\" xmlns:pwg=\"" +
        PWG_NS + "\">" +
        "<pwg:JobUri>/eSCL/ScanJobs/7</pwg:JobUri><scan:ActualWidth>2480</scan:ActualWidth>" +
        "<scan:ActualHeight>3508</scan:ActualHeight><scan:ActualBytesPerLine>7440</scan:ActualBytesPerLine>" +
        "</scan:ScanImageInfo>";
    def f as Fake init fake([xmlReply($info), bareReply(404)]);
    def s as Scanner init on($f);
    def job as Job init Job{
        scanner: $s,
        url: $s.base + "/ScanJobs/7",
        pages: 1,
        bytes: 0,
        platen: false
    };
    def got as ImageInfo init imageInfo($job);
    testing.assertEqual($got.width, 2480);
    testing.assertEqual($got.height, 3508);
    testing.assertEqual($got.bytesPerLine, 7440);
    def msg as string init "";
    try {
        imageInfo($job);
    } catch (e) {
        $msg = $e.message;
    }
    def seen as list of Seen init stopFake($f);
    testing.assertEqual($seen[0].path, "/eSCL/ScanJobs/7/ScanImageInfo");
    testing.assertEqual($msg, "escl: the scanner offers no ScanImageInfo for this job");
}

/**
 * A `scanEach` handler: page `n` must hold `page<n>`.
 *
 * @param p {Page} the page
 * @param n {int} its number
 */
func checkPage(p as Page, n as int) {
    testing.assertEqual(convert.stringFromBytes("utf-8", $p.data), "page{$n}");
}

/**
 * A `scanEach` handler that fails on the second page.
 *
 * @param p {Page} the page
 * @param n {int} its number
 */
func refuseSecond(p as Page, n as int) {
    if ($n == 2) {
        throw Error{kind: "mine", message: "no second page"};
    }
}

func testScanEach() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "page1"),
        pageReply("image/jpeg", "page2"),
        bareReply(404),
        xmlReply(statusXml("", "Completed", "JobCompletedSuccessfully")),
        bareReply(204)
    ]);
    testing.assertEqual(scanEach(on($f), feederSettings(false), checkPage), 2);
    stopFake($f);
    def g as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "page1"),
        pageReply("image/jpeg", "page2"),
        bareReply(200)
    ]);
    def kind as string init "";
    try {
        scanEach(on($g), feederSettings(false), refuseSecond);
    } catch (e) {
        $kind = $e.kind + ": " + $e.message;
    }
    def seen as list of Seen init stopFake($g);
    testing.assertEqual($kind, "mine: no second page");
    testing.assertEqual($seen[5].method, "DELETE");
}

func testQueriesAreNotAnswers() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def asAnswer as bytes init answer([
        rr(wire("_uscan._tcp.local"), 12, wire("X._uscan._tcp.local"))
    ]);
    testing.assertEqual(len(absorb($empty, $asAnswer).ptrs), 1);
    # the same records with the response bit cleared: another host's query
    def asQuery as bytes init cat([raw([0, 0, 0, 0]), $asAnswer[4..]]);
    testing.assertEqual(len(absorb($empty, $asQuery).ptrs), 0);
}

# --- second review --------------------------------------------------------

/**
 * One scanner's full answer.
 *
 * @param instance {string} the instance name, without the service
 * @param rs {string} the TXT `rs` value
 * @return {bytes} the DNS message
 */
func scannerAnswer(instance as string, rs as string) {
    def full as string init $instance + "._uscan._tcp.local";
    return answer([
        rr(wire("_uscan._tcp.local"), 12, wire($full)),
        rr(wire($full), 33, cat([raw([0, 0, 0, 0, 0, 80]), wire("dev.local")])),
        rr(wire($full), 16, txtData(["rs=" + $rs])),
        rr(wire("dev.local"), 1, raw([10, 0, 0, 9]))
    ]);
}

func testNetworkTextCannotDriveATerminal() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def evil as string init "Evil" + convert.fromCodepoint(27) + "[2J" +
        convert.fromCodepoint(155) + "x";
    def found as list of Found init assemble(absorb($empty, scannerAnswer($evil, "eSCL")));
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].name, "Evil?[2J?x");
}

func testLongTxtValuesAreNotCut() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def rs as string init strings.repeat("a", 120);
    def found as list of Found init assemble(absorb($empty, scannerAnswer("S", $rs)));
    testing.assertEqual($found[0].root, $rs);
    testing.assertEqual($found[0].url, "http://10.0.0.9:80/" + $rs);
    # an rs that is not a plain path leaves the scanner out
    testing.assertEqual(len(assemble(absorb($empty, scannerAnswer("S", "a/../b")))), 0);
}

func testTabInAnInstanceName() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def found as list of Found init assemble(absorb($empty, scannerAnswer("Desk\tScanner", "eSCL")));
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].name, "Desk?Scanner");
}

func testShortSrvIsRefused() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def msg as string init "";
    try {
        absorb($empty, answer([rr(wire("x.local"), 33, raw([0, 0, 0, 0, 0, 80]))]));
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertEqual($msg, "escl: mDNS: an SRV record is too short");
}

func testLoginNeedsAVerifiedCertificate() {
    def o as Options;
    $o.username = "scan";
    $o.skipVerify = true;
    def msg as string init "";
    try {
        scannerWith("https://10.0.0.5", $o);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "refusing to send a login to an unverified certificate");
    $o.allowPlainAuth = true;
    testing.assertEqual(scannerWith("https://10.0.0.5", $o).origin, "https://10.0.0.5");
}

func testDiscoveryStopsAtAFlood() {
    # 60 PTRs a packet (under the label budget of one answer), each owner and
    # service compressed to the first name; 40 packets pass MAX_RECORDS
    def packets as list of bytes init [];
    for (def p in 0..40) {
        def recs as list of bytes init [
            rr(wire("_uscan._tcp.local"), 12, cat([raw([2, 78, 48]), raw([192, 12])]))
        ];
        for (def i in 1..60) {
            $recs[] = rr(raw([192, 12]), 12, cat([raw([2, 78, 49]), raw([192, 12])]));
        }
        $packets[] = answer($recs);
    }
    $packets[] = scannerAnswer("Real", "eSCL");
    def sock as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def t as task of bytes init spawn {
        return respondMdns($sock, $packets);
    };
    def t0 as time.Time init time.now();
    def found as list of Found init discoverAt(net.address($sock), 5000);
    def took as int init time.milliseconds(time.sub(time.now(), $t0));
    task.wait($t);
    net.close($sock);
    testing.assertEqual(len($found), 0);
    testing.assertTrue($took < 4000);
}

func testDiscoveryCountsEveryRecordType() {
    # SRV records only, each with its own owner: no PTR, so a PTR-only cap
    # would never stop reading them
    def packets as list of bytes init [];
    for (def p in 0..25) {
        def recs as list of bytes init [];
        for (def i in 0..100) {
            $recs[] = rr(wire("s{$p}x{$i}.local"), 33, raw([0, 0, 0, 0, 0, 80, 192, 12]));
        }
        $packets[] = answer($recs);
    }
    $packets[] = scannerAnswer("Real", "eSCL");
    def sock as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def t as task of bytes init spawn {
        return respondMdns($sock, $packets);
    };
    def found as list of Found init discoverAt(net.address($sock), 5000);
    task.wait($t);
    net.close($sock);
    testing.assertEqual(len($found), 0);
}

func testFuzzedAnswersFailOnlyAsEscl() {
    def seed as bytes init scannerAnswer("Fuzz", "eSCL");
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    math.randSeed(20261111);
    def odd as list of string init [];
    for (def round in 0..3000) {
        def m as bytes init $seed;
        for (def k in 0..math.randInt(1, 4)) {
            $m[math.randInt(0, len($m) - 1)] = math.randInt(0, 255);
        }
        if (math.randInt(0, 3) == 0) {
            $m = $m[..math.randInt(0, len($m))];
        }
        try {
            assemble(absorb($empty, $m));
        } catch (e) {
            if ($e.kind != "escl" and len($odd) < 3) {
                $odd[] = "{$round}: {$e.kind}: {$e.message}";
            }
        }
    }
    testing.assertEqual($odd, []);
}

# --- independent review ---------------------------------------------------

/**
 * The method and path of each request.
 *
 * @param seen {list of Seen} the requests
 * @return {list of string} `METHOD /path` each
 */
func calls(seen as list of Seen) {
    def out as list of string init [];
    for (def s in $seen) {
        $out[] = $s.method + " " + $s.path;
    }
    return $out;
}

func testEveryUsableRangeIsKept() {
    def x as string init '<ScannerCapabilities><Platen><PlatenInputCaps>' +
        '<MaxWidth>2550</MaxWidth><MaxHeight>3508</MaxHeight><SettingProfiles>' +
        '<SettingProfile><ColorModes><ColorMode>RGB24</ColorMode></ColorModes>' +
        '<DocumentFormats><DocumentFormat>image/jpeg</DocumentFormat></DocumentFormats>' +
        '<SupportedResolutions><ResolutionRange>' +
        '<XResolutionRange><Min>75</Min><Max>1200</Max><Step>75</Step></XResolutionRange>' +
        '<YResolutionRange><Min>75</Min><Max>1200</Max><Step>75</Step></YResolutionRange>' +
        '</ResolutionRange></SupportedResolutions></SettingProfile>' +
        '<SettingProfile><SupportedResolutions><ResolutionRange>' +
        '<XResolutionRange><Min>300</Min><Max>300</Max><Step>1</Step></XResolutionRange>' +
        '<YResolutionRange><Min>300</Min><Max>300</Max><Step>1</Step></YResolutionRange>' +
        '</ResolutionRange></SupportedResolutions></SettingProfile>' +
        '<SettingProfile><SupportedResolutions><ResolutionRange>' +
        '<XResolutionRange><Min>100</Min><Max>200</Max></XResolutionRange>' +
        '<YResolutionRange><Min>50</Min><Max>200</Max></YResolutionRange>' +
        '</ResolutionRange></SupportedResolutions></SettingProfile>' +
        '</SettingProfiles></PlatenInputCaps></Platen></ScannerCapabilities>';
    def c as Capabilities init parseCapabilities($x);
    # the X != Y range is dropped, the narrow one does not replace the wide one
    testing.assertEqual(
        $c.inputs[0].resolutionRanges,
        [Range{min: 75, max: 1200, step: 75}, Range{min: 300, max: 300, step: 1}]);
    def st as Settings init settings();
    $st.resolution = 600;
    testing.assertEqual(check($c, $st).resolution, 600);
    $st.resolution = 610;
    testing.assertContains(
        checkError($c, $st),
        "the scanner has 75-1200 in steps of 75, 300-300 in steps of 1");
}

func testScanSettingsDocumentIsPinned() {
    def st as Settings init feederSettings(true);
    $st.intent = "";
    $st.adjust = {};
    def want as string init '<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.6</pwg:Version>
  <pwg:ScanRegions pwg:MustHonor="true">
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
      <pwg:Width>2550</pwg:Width>
      <pwg:Height>3600</pwg:Height>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
  <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
  <pwg:InputSource>Feeder</pwg:InputSource>
  <scan:ColorMode>RGB24</scan:ColorMode>
  <scan:XResolution>300</scan:XResolution>
  <scan:YResolution>300</scan:YResolution>
  <scan:Duplex>true</scan:Duplex>
</scan:ScanSettings>
';
    testing.assertEqual(settingsXml(parseCapabilities(EPSON_CAPS), $st), $want);
}

func testJobRequestsGoWhereTheyShould() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "front"),
        bareReply(404),
        xmlReply(statusXml("ScannerAdfJam", "Aborted", "JobCanceledBySystem")),
        bareReply(200)
    ]);
    def msg as string init "";
    try {
        scan(on($f), feederSettings(false));
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "aborted");
    testing.assertEqual(
        calls(stopFake($f)),
        [
            "GET /eSCL/ScannerCapabilities",
            "GET /eSCL/ScannerStatus",
            "POST /eSCL/ScanJobs",
            "GET /eSCL/ScanJobs/42/NextDocument",
            "GET /eSCL/ScanJobs/42/NextDocument",
            "GET /eSCL/ScannerStatus",
            "DELETE /eSCL/ScanJobs/42"
        ]);
}

func testFinishedJobFoundByUuid() {
    # the status names the job by another URI, but by the same UUID
    def st as string init strings.replace(
        statusXml("", "Aborted", "JobCanceledBySystem"),
        "<pwg:JobUri>/eSCL/ScanJobs/42</pwg:JobUri>",
        "<pwg:JobUri>/jobs/other</pwg:JobUri>");
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "1"),
        xmlReply($st),
        bareReply(200)
    ]);
    def msg as string init "";
    try {
        scan(on($f), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertContains($msg, "the scanner aborted the job after 1 page(s)");
}

func testRetryAfterNeverPassesTheDeadline() {
    def busy as Canned init bareReply(503);
    $busy.retryAfter = "5";
    def f as Fake init fake([$busy, $busy]);
    def s as Scanner init on($f);
    $s.options.busyWaitMs = 300;
    def t0 as time.Time init time.now();
    def msg as string init "";
    def code as int init 0;
    def retry as int init 0;
    try {
        status($s);
    } catch (e) {
        $msg = $e.message;
        $code = $e.status;
        $retry = $e.retryAfterMs;
    }
    def took as int init time.milliseconds(time.sub(time.now(), $t0));
    stopFake($f);
    testing.assertEqual($msg, "escl: GET ScannerStatus: HTTP 503");
    # the scanner's Retry-After reaches the error
    testing.assertEqual($code, 503);
    testing.assertEqual($retry, 5000);
    testing.assertTrue($took >= 300 and $took < 1500);
}

func testHostileCapabilitiesFailFast() {
    def modes as string init "";
    for (def i in 0..300) {
        $modes = $modes + "<ColorMode>m{$i}</ColorMode>";
    }
    def many as string init strings.replace(
        EPSON_CAPS,
        "<ColorMode>Grayscale8</ColorMode>",
        $modes);
    def bulk as string init strings.replace(
        EPSON_CAPS,
        "<AdfOptions>",
        "<x>" + strings.repeat("<y/>", 12000) + "</x><AdfOptions>");
    def cases as map of string to string init {};
    $cases[$many] = "a list has more than 256 entries";
    $cases[$bulk] = "ScannerCapabilities has more than 10000 elements";
    for (def text in $cases) {
        def t0 as time.Time init time.now();
        def msg as string init "";
        def kind as string init "";
        try {
            parseCapabilities($text);
        } catch (e) {
            $msg = $e.message;
            $kind = $e.kind;
        }
        testing.assertEqual($kind, "limit");
        testing.assertContains($msg, $cases[$text]);
        testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 3000);
    }
}

func testControlsInDeviceTextComeBackAsQuestionMarks() {
    def st as Status init parseStatus(strings.replace(
        statusXml("", "Completed", "Done&#x9b;2J"),
        "<pwg:State>Idle</pwg:State>",
        "<pwg:State>Idle&#x9b;[2J</pwg:State>"));
    # XML refuses C0 controls such as ESC itself; C1 ones like CSI get through
    testing.assertEqual($st.state, "Idle?[2J");
    testing.assertEqual($st.jobs[0].reasons, ["Done?2J"]);
    def c as Capabilities init parseCapabilities(strings.replace(
        HP_CAPS,
        "HP LaserJet MFP M28w",
        "HP&#x85;M28"));
    testing.assertEqual($c.makeAndModel, "HP?M28");
}

func testJobBytesAreCapped() {
    def f as Fake init fake([
        xmlReply(EPSON_CAPS),
        xmlReply(statusXml("ScannerAdfLoaded", "", "")),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "123456"),
        pageReply("image/jpeg", "123456"),
        bareReply(200)
    ]);
    def s as Scanner init on($f);
    $s.options.maxJobBytes = 10;
    def msg as string init "";
    def kind as string init "";
    try {
        scanEach($s, feederSettings(false), checkLength);
    } catch (e) {
        $msg = $e.message;
        $kind = $e.kind;
    }
    testing.assertEqual($kind, "limit");
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(
        $msg,
        "escl: the job's pages add up to more than 10 bytes; raise Options.maxJobBytes for larger jobs");
    testing.assertEqual($seen[5].method, "DELETE");
    testing.assertEqual(scanner("h").options.maxJobBytes, DEFAULT_MAX_JOB_BYTES);
}

/**
 * A `scanEach` handler that only checks the page is non-empty.
 *
 * @param p {Page} the page
 * @param n {int} its number
 */
func checkLength(p as Page, n as int) {
    testing.assertTrue(len($p.data) > 0 and $n > 0);
}

/**
 * Accept one request and answer it only after a pause.
 *
 * @param srv {httpd.Server} the server
 * @param ms {int} the pause
 * @return {int} 1
 */
func answerLate(srv as httpd.Server, ms as int) {
    def req as httpd.Request init httpd.accept($srv);
    time.sleep(time.fromMilliseconds($ms));
    httpd.respond($req, 200, HP_CAPS);
    return 1;
}

func testDeadlineEndsASlowRequest() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return answerLate($srv, 1500);
    };
    def o as Options;
    $o.deadlineMs = 200;
    def s as Scanner init scannerWith(httpd.address($srv), $o);
    def t0 as time.Time init time.now();
    def msg as string init "";
    try {
        capabilities($s);
    } catch (e) {
        $msg = $e.message;
    }
    def took as int init time.milliseconds(time.sub(time.now(), $t0));
    task.wait($t);
    httpd.shutdown($srv);
    testing.assertContains($msg, "no complete reply within 200 ms (Options.deadlineMs)");
    testing.assertTrue($took < 1000);
    # a fast reply within the deadline is untouched
    def srv2 as httpd.Server init httpd.listen("127.0.0.1:0");
    def t2 as task of int init spawn {
        return answerLate($srv2, 0);
    };
    $o.deadlineMs = 3000;
    testing.assertEqual(capabilities(scannerWith(httpd.address($srv2), $o)).version, "2.63");
    task.wait($t2);
    httpd.shutdown($srv2);
}

func testADanglingLinkIsNotWrittenThrough() {
    def dir as string init fs.makeTempDir();
    defer fs.removeAll($dir);
    fs.symlink($dir + "/missing-target", $dir + "/p-001.jpg");
    def msg as string init "";
    try {
        writeFresh($dir + "/p-001.jpg", utf8("x"));
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "will not overwrite");
    testing.assertFalse(fs.exists($dir + "/missing-target"));
}

# --- third review ---------------------------------------------------------

func testHostAlwaysCarriesThePort() {
    testing.assertEqual(authority("http://10.0.0.5/eSCL/ScannerStatus"), "10.0.0.5:80");
    testing.assertEqual(authority("https://scan.lan/eSCL"), "scan.lan:443");
    testing.assertEqual(authority("http://10.0.0.5:8080/eSCL"), "10.0.0.5:8080");
    testing.assertEqual(authority("http://[fe80::1]/eSCL"), "[fe80::1]:80");
    testing.assertEqual(authority("http://[fe80::1]:8080/eSCL"), "[fe80::1]:8080");
    def s as Scanner init scanner("10.0.0.5");
    def h as map of string to string init requestHeaders($s, $s.base + "/ScannerStatus", "");
    testing.assertEqual($h["Host"], "10.0.0.5:80");
    testing.assertFalse(maps.has($h, "Content-Type"));
    testing.assertEqual(
        requestHeaders($s, $s.base + "/ScanJobs", "<x/>")["Content-Type"],
        "text/xml");
}

func testHostNamesAreChecked() {
    for (def bad in [".", "..", "-", "a..b", "-a.lan", "a-.lan", ".a", "a.lan.."]) {
        testing.assertContains(addressError($bad), "malformed host");
    }
    testing.assertEqual(scanner("scanner.lan.").origin, "http://scanner.lan.");
    testing.assertEqual(scanner("EPSON1A2B3C.local").origin, "http://EPSON1A2B3C.local");
}

func testMalformedXmlErrorsAreClipped() {
    def junk as string init "&\u009b[2J\n\nFAKE" + strings.repeat("A", 2000) + ";";
    def msg as string init "";
    try {
        parseCapabilities("<ScannerCapabilities><a>" + $junk + "</a></ScannerCapabilities>");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "malformed XML");
    testing.assertTrue(len($msg) < 300);
    testing.assertFalse(strings.contains($msg, "\u009b"));
    testing.assertFalse(strings.contains($msg, "\n"));
}

func testLongDeviceTextIsRefused() {
    def long as string init strings.repeat("M", 1025);
    def caps as string init strings.replace(HP_CAPS, "HP LaserJet MFP M28w", $long);
    testing.assertTrue(strings.contains($caps, $long));
    def msg as string init "";
    try {
        parseCapabilities($caps);
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "more than 1024 characters");
    # a 4 MB field fails fast
    def t0 as time.Time init time.now();
    $msg = "";
    try {
        parseCapabilities(strings.replace(
            HP_CAPS,
            "HP LaserJet MFP M28w",
            strings.repeat("M", 4000000) + "&#x85;"));
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "more than 1024 characters");
    testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 3000);
}

/**
 * Answer one connection with a raw HTTP response, as written.
 *
 * @param l {net.Listener} the listener
 * @param reply {string} the response
 * @return {int} 0
 */
func rawOnce(l as net.Listener, reply as string) {
    def c as net.Conn init net.accept($l);
    net.setReadDeadline($c, 2000);
    net.readBytes($c, 65536);
    net.writeBytes($c, utf8($reply));
    net.close($c);
    return 0;
}

func testPageContentTypeIsChecked() {
    # httpd will not send such a header, so a raw socket does
    def l as net.Listener init net.listen("127.0.0.1:0");
    def t as task of int init spawn {
        return rawOnce(
            $l,
            "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\u001b]0;pwned\u0007\r\n" +
                "Content-Length: 3\r\nConnection: close\r\n\r\nabc");
    };
    def s as Scanner init scanner(net.address($l));
    def job as Job init Job{
        scanner: $s,
        url: $s.base + "/ScanJobs/1",
        pages: 0,
        bytes: 0,
        platen: false
    };
    def msg as string init "";
    try {
        nextPage($job);
    } catch (e) {
        $msg = $e.message;
    }
    task.waitTimeout($t, 10000);
    net.close($l);
    testing.assertContains($msg, "page 1 has a malformed Content-Type");
    testing.assertFalse(strings.contains($msg, "\u001b"));
}

func testPageExtensionFromItsBytes() {
    def kinds as list of list of int init [
        [255, 216, 255, 224],
        [137, 80, 78, 71, 13, 10, 26, 10],
        [37, 80, 68, 70, 45],
        [73, 73, 42, 0],
        [77, 77, 0, 42],
        [1, 2, 3, 4]
    ];
    def wants as list of string init ["jpg", "png", "pdf", "tif", "tif", "bin"];
    for (def k in 0..len($kinds)) {
        testing.assertEqual(
            pageExtension(Page{done: false, contentType: "", data: raw($kinds[$k])}),
            $wants[$k]);
    }
    # a usable type wins over the bytes
    testing.assertEqual(
        pageExtension(Page{done: false, contentType: "image/png", data: raw([255, 216, 255])}),
        "png");
}

func testMdnsErrorsAndOtherOpcodesAreIgnored() {
    def good as bytes init scannerAnswer("Scanner", "eSCL");
    # rcode 3 (NXDOMAIN), then opcode 1
    def failed as bytes init $good;
    $failed[3] = 3;
    def opcode as bytes init $good;
    $opcode[2] = 132 + 8;
    def recs as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    testing.assertEqual(absorb($recs, $failed).count, 0);
    testing.assertEqual(absorb($recs, $opcode).count, 0);
    testing.assertTrue(absorb($recs, $good).count > 0);
}

func testMdnsAnswersFromAnotherPortAreIgnored() {
    def sock as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def other as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def t as task of bytes init spawn {
        def q as net.Datagram init net.recvFrom($sock, 9000);
        net.sendTo($other, $q.peer, scannerAnswer("Spoofed", "eSCL"));
        net.sendTo($sock, $q.peer, scannerAnswer("Real", "eSCL"));
        return $q.data;
    };
    def found as list of Found init discoverAt(net.address($sock), 500);
    task.wait($t);
    net.close($sock);
    net.close($other);
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].name, "Real");
}

func testAFailedStatusAfterTheLastPageKeepsThePages() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "page1"),
        bareReply(500),
        bareReply(500)
    ]);
    def pages as list of Page init scan(on($f), settings());
    def seen as list of Seen init stopFake($f);
    testing.assertEqual(len($pages), 1);
    testing.assertEqual($seen[3].path, "/eSCL/ScannerStatus");
    testing.assertEqual($seen[4].method + " " + $seen[4].path, "DELETE /eSCL/ScanJobs/42");
}

func testALoginInTheAddressIsNotEchoed() {
    for (def a in [
        "scan:hunter2@10.0.0.5",
        "https://scan:hunter2@10.0.0.5:8080/eSCL",
        "ftp://scan:hunter2@10.0.0.5",
        "http://scan:hun/ter2/hunter2@10.0.0.5/eSCL",
        "scan:hunter2/x@10.0.0.5",
        "https://u:hunter2?b/c#d@10.0.0.5"
    ]) {
        def msg as string init "";
        try {
            scanner($a);
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertContains($msg, "escl: ");
        testing.assertFalse(strings.contains($msg, "hunter2"));
    }
    def msg2 as string init "";
    try {
        scanner("scan:hunter2@10.0.0.5");
    } catch (e) {
        $msg2 = $e.message;
    }
    testing.assertEqual(
        $msg2,
        "escl: put a login in Options.username and Options.password, not in the address \"...@10.0.0.5\"");
}

func testBidiControlsAreNeutralised() {
    def spoof as string init "Scan\u202egpj.exe\u2066x\u200f";
    testing.assertEqual(printable($spoof), "Scan?gpj.exe?x?");
    testing.assertEqual(clip($spoof), "Scan?gpj.exe?x?");
    # the Arabic letter mark, invisible spaces and joiners, line and
    # paragraph separators, the byte order mark
    testing.assertEqual(
        printable("a\u061cb\u200bc\u200dd\u2028e\u2029f\u2060g\ufeffh\u180ei"),
        "a?b?c?d?e?f?g?h?i");
    testing.assertEqual(printable("Café ü 日本"), "Café ü 日本");
}

func testALoopOfYourOwnCountsAndFinishes() {
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/7"),
        pageReply("image/png", "P1"),
        xmlReply(statusXml("", "Completed", "JobCompletedSuccessfully")),
        bareReply(204)
    ]);
    def s as Scanner init on($f);
    def job as Job init start($s, capabilities($s), settings());
    while (true) {
        def p as Page init nextPage($job);
        if ($p.done) {
            break;
        }
        $job = countPage($job, $p);
    }
    finish($job);
    def seen as list of Seen init stopFake($f);
    testing.assertEqual($job.pages, 1);
    testing.assertEqual($job.bytes, 2);
    testing.assertEqual($seen[4].method + " " + $seen[4].path, "DELETE /eSCL/ScanJobs/7");
    # an aborted job fails, and a job of no pages too
    def g as Fake init fake([
        xmlReply(statusXml("", "Aborted", "AbortedByDevice")),
        xmlReply(statusXml("", "Completed", "JobCompletedSuccessfully"))
    ]);
    def s2 as Scanner init on($g);
    def done as Job init Job{
        scanner: $s2,
        url: $s2.base + "/ScanJobs/42",
        pages: 1,
        bytes: 2,
        platen: false
    };
    def msgs as list of string init [];
    for (def pages in [1, 0]) {
        $done.pages = $pages;
        try {
            finish($done);
            $msgs[] = "";
        } catch (e) {
            $msgs[] = $e.message;
        }
    }
    stopFake($g);
    testing.assertContains($msgs[0], "the scanner aborted the job after 1 page(s)");
    testing.assertEqual($msgs[1], "escl: the scanner returned no pages");
}

func testAHostileDocumentIsRefusedBeforeItIsParsed() {
    def doc as string init "<ScannerCapabilities>" + strings.repeat("<a/>", 1000000) +
        "</ScannerCapabilities>";
    def t0 as time.Time init time.now();
    def msg as string init "";
    try {
        parseCapabilities($doc);
    } catch (e) {
        $msg = $e.message;
    }
    def ms as int init time.milliseconds(time.sub(time.now(), $t0));
    testing.assertEqual(
        $msg,
        "escl: ScannerCapabilities has more than 10000 elements; not an eSCL document");
    # counted in the text, before a tree is built: about 1 GB and 0.5 s without
    testing.assertTrue($ms < 100);
    # under the text count but over the tree count: refused while walking
    $msg = "";
    try {
        parseCapabilities("<ScannerCapabilities>" + strings.repeat("<a/>", 10001) +
            "</ScannerCapabilities>");
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "more than 10000 elements");
}

func testAbortFoundByAnAbsoluteJobUri() {
    def st as string init strings.replace(
        statusXml("", "Aborted", "AbortedByDevice"),
        "<pwg:JobUri>/eSCL/ScanJobs/42</pwg:JobUri><pwg:JobUuid>42</pwg:JobUuid>",
        "<pwg:JobUri>http://NPI6142D.local.:80/eSCL/ScanJobs/42</pwg:JobUri>");
    testing.assertFalse(strings.contains($st, "JobUuid"));
    def f as Fake init fake([
        xmlReply(HP_CAPS),
        created("/eSCL/ScanJobs/42"),
        pageReply("image/jpeg", "1"),
        xmlReply($st),
        bareReply(200)
    ]);
    def msg as string init "";
    try {
        scan(on($f), settings());
    } catch (e) {
        $msg = $e.message;
    }
    stopFake($f);
    testing.assertContains($msg, "the scanner aborted the job after 1 page(s)");
    testing.assertEqual(uriPath("https://h:1/a/b"), "/a/b");
    testing.assertEqual(uriPath("http://h"), "");
    testing.assertEqual(uriPath("/a/b"), "/a/b");
}

/**
 * An mDNS answer of `n` records of this type, each owned by the 127-label
 * name the first one spells out and the others point back to.
 *
 * @param n {int} the records
 * @param kind {int} their type
 * @return {bytes} the message
 */
func floodOf(n as int, kind as int) {
    def m as bytes;
    for (def b in [0, 0, 132, 0, 0, 0, $n // 256, $n % 256, 0, 0, 0, 0]) {
        $m[] = $b;
    }
    for (def i in 0..127) {
        $m[] = 1;
        $m[] = 97;
    }
    $m[] = 0;
    for (def b in [0, $kind, 0, 1, 0, 0, 0, 0, 0, 0]) {
        $m[] = $b;
    }
    for (def r in 1..$n) {
        for (def b in [192, 12, 0, $kind, 0, 1, 0, 0, 0, 0, 0, 0]) {
            $m[] = $b;
        }
    }
    return $m;
}

func testRecordsOfOtherTypesCountAndCostLittle() {
    def empty as Records init Records{ptrs: [], srvs: {}, txts: {}, addrs: {}, count: 0};
    def t0 as time.Time init time.now();
    def recs as Records init absorb($empty, floodOf(727, 99));
    testing.assertEqual($recs.count, 727);
    testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 100);
    # past the budget the rest of a message is not read
    $recs.count = MAX_RECORDS - 10;
    $recs = absorb($recs, floodOf(727, 99));
    testing.assertEqual($recs.count, MAX_RECORDS + 1);
    # records that are read: their names count against a budget per answer
    for (def kind in [12, 16]) {
        def msg as string init "";
        $t0 = time.now();
        try {
            absorb($empty, floodOf(727, $kind));
        } catch (e) {
            $msg = $e.message;
        }
        testing.assertEqual($msg, "escl: mDNS: an answer with more than 512 name labels");
        testing.assertTrue(time.milliseconds(time.sub(time.now(), $t0)) < 100);
    }
}

func testAFaultyFeederIsRefusedBeforeTheJob() {
    for (def fault in ["ScannerAdfJam", "ScannerAdfHatchOpen"]) {
        def f as Fake init fake([xmlReply(EPSON_CAPS), xmlReply(statusXml($fault, "", ""))]);
        def msg as string init "";
        try {
            scan(on($f), feederSettings(false));
        } catch (e) {
            $msg = $e.message;
        }
        def seen as list of Seen init stopFake($f);
        testing.assertEqual($msg, "escl: the feeder reports {$fault}; clear it and try again");
        testing.assertEqual(len($seen), 2);
    }
}

/**
 * Accept one connection, answer it, and return what the client sent.
 *
 * @param l {net.Listener} the listener
 * @param reply {string} the raw HTTP reply
 * @return {string} the request as received
 */
func rawCapture(l as net.Listener, reply as string) {
    def c as net.Conn init net.accept($l);
    net.setReadDeadline($c, 2000);
    def got as bytes init net.readBytes($c, 65536);
    net.writeBytes($c, utf8($reply));
    net.close($c);
    return convert.stringFromBytes("utf-8", $got);
}

func testHostReachesTheWire() {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def t as task of string init spawn {
        return rawCapture(
            $l,
            "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    };
    def where as string init net.address($l);
    def s as Scanner init scanner($where);
    try {
        status($s);
    } catch (e) {
        testing.assertContains($e.message, "HTTP 500");
    }
    def req as string init task.waitTimeout($t, 10000);
    net.close($l);
    def hosts as int init 0;
    for (def line in strings.split($req, "\r\n")) {
        if (strings.startsWith(strings.lower($line), "host:")) {
            $hosts = $hosts + 1;
            testing.assertEqual($line, "Host: " + $where);
        }
    }
    testing.assertEqual($hosts, 1);
}

func testAnAnswerOverTheLabelBudgetIsSkipped() {
    def sock as net.UDPSocket init net.listenUDP("127.0.0.1:0");
    def packets as list of bytes init [floodOf(727, 12), scannerAnswer("Real", "eSCL")];
    def t as task of bytes init spawn {
        return respondMdns($sock, $packets);
    };
    def found as list of Found init discoverAt(net.address($sock), 1000);
    task.wait($t);
    net.close($sock);
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].name, "Real");
}

# A local failure is an EsclError with no status and no Retry-After.
func testALocalFailureIsAnEsclError() {
    try {
        scanner("http://a b");
        throw Error{kind: "missed", message: "scanner did not throw"};
    } catch (e) {
        testing.assertEqual($e.kind, "escl");
        testing.assertEqual($e.status, 0);
        testing.assertEqual($e.retryAfterMs, -1);
    }
}
