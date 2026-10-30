#!/usr/bin/env python3
# XML and APK reads for launcher-check.sh. Run it with python3 -I.
#
#   launcher-xml.py privileged <AndroidManifest.xml> <permission>...
#       of the permissions given, print (in the order given) the ones a <permission> in that
#       manifest (frameworks/base core/res/AndroidManifest.xml: the platform's) declares with
#       "privileged" in its protectionLevel, in any of its declarations
#   launcher-xml.py string <resources.xml> <name>
#       print <string name="<name>">'s value, or a <string-array>'s items joined with ":",
#       nothing if there is none
#   launcher-xml.py overlay <AndroidManifest.xml>
#       print the <overlay> tag's "targetPackage priority isStatic targetName" (- if unset)
#   launcher-xml.py overlay-package <AndroidManifest.xml>
#       print the manifest's package
#   launcher-xml.py config <name> <rro folder>...
#       for every static overlay of "android" in the folders given (one per subfolder with an
#       AndroidManifest.xml), print "priority<TAB>overlay folder<TAB>value" for each
#       <string> or <string-array> (items joined with ":") named <name> in its
#       res/values/*.xml, highest priority first
#   launcher-xml.py sources <name> <top>
#       the same for every value of <name> the tree's framework config could come from:
#       framework-res's own (priority -1), vendor/lineage/overlay/common (a static product
#       overlay, priority 1) and vendor/pixel-style's static overlays of "android"
#   launcher-xml.py zip-has <apk> <entry> <text>...
#       print "found <text>" or "missing <text>" for each text, looked for in that zip entry
#       as UTF-8 and as UTF-16LE (aapt2's string pools use either)
#   launcher-xml.py privapp <xml> <package>
#       print "permission <name>" / "deny <name>" for <package>'s <privapp-permissions>, and
#       "other <package>" for any other package's
#   launcher-xml.py hiddenapi <xml> <package>
#       print "whitelisted" if <package> has a <hidden-api-whitelisted-app> tag
#   launcher-xml.py install-in <xml> <package>
#       print "install-in <user type>" / "do-not-install-in <user type>" for each of
#       <package>'s <install-in-user-type> entries
#   (privapp and hiddenapi are viper4android/tools/v4a-xml.py's, so each kit stands alone)
import os, sys, zipfile
import xml.etree.ElementTree as ET

A = "{http://schemas.android.com/apk/res/android}"

def usage():
    sys.exit("usage: launcher-xml.py privileged|string|overlay|overlay-package|config|sources|zip-has|privapp|hiddenapi|install-in ...")

def strings(path, name):
    # a <string>'s text, or a <string-array>'s items joined with ":"
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return []
    out = []
    for e in root:
        if e.get("name") != name:
            continue
        if e.tag == "string":
            out.append("".join(e.itertext()).strip())
        elif e.tag == "string-array":
            out.append(":".join("".join(i.itertext()).strip() for i in e.iter("item")))
    return out

def overlay(path):
    root = ET.parse(path).getroot()
    o = root.find("overlay")
    if o is None:
        return None
    return (o.get(A + "targetPackage") or "-", o.get(A + "priority") or "-",
            o.get(A + "isStatic") or "-", o.get(A + "targetName") or "-")

def main(argv):
    if len(argv) < 2:
        usage()
    mode, args = argv[1], argv[2:]
    if mode == "privileged" and len(args) >= 1:
        levels = {}
        for p in ET.parse(args[0]).getroot().iter("permission"):
            levels.setdefault(p.get(A + "name"), []).append(p.get(A + "protectionLevel") or "")
        for name in args[1:]:
            if any("privileged" in lv.split("|") for lv in levels.get(name, [])):
                print(name)
    elif mode == "string" and len(args) == 2:
        for v in strings(args[0], args[1])[:1]:
            print(v)
    elif mode == "overlay" and len(args) == 1:
        o = overlay(args[0])
        if o:
            print(" ".join(o))
    elif mode == "overlay-package" and len(args) == 1:
        print(ET.parse(args[0]).getroot().get("package") or "")
    elif mode == "config" and len(args) >= 2:
        rows = []
        for top in args[1:]:
            for d in sorted(os.listdir(top)):
                m = os.path.join(top, d, "AndroidManifest.xml")
                if not os.path.isfile(m):
                    continue
                try:
                    o = overlay(m)
                except (ET.ParseError, OSError):
                    continue
                if not o or o[0] != "android" or o[2] != "true":
                    continue
                vals = os.path.join(top, d, "res", "values")
                if not os.path.isdir(vals):
                    continue
                for f in sorted(os.listdir(vals)):
                    if f.endswith(".xml"):
                        for v in strings(os.path.join(vals, f), args[0]):
                            rows.append((int(o[1]) if o[1].lstrip("-").isdigit() else 0, os.path.join(top, d), v))
        for pr, d, v in sorted(rows, key=lambda r: -r[0]):
            print("%d\t%s\t%s" % (pr, d, v))
    elif mode == "sources" and len(args) == 2:
        # where the build's value comes from: framework-res's own, vendor/lineage/overlay/common
        # (the build makes it a static product overlay, priority 1: build/make
        # core/generate_enforce_rro.mk) and vendor/pixel-style's static product overlays
        name, top = args
        rows = []
        def scan(d, pr, label):
            if os.path.isdir(d):
                for f in sorted(os.listdir(d)):
                    if f.endswith(".xml"):
                        for v in strings(os.path.join(d, f), name):
                            rows.append((pr, label, v))
        scan(os.path.join(top, "frameworks/base/core/res/res/values"), -1, "frameworks/base (framework-res)")
        scan(os.path.join(top, "vendor/lineage/overlay/common/frameworks/base/core/res/res/values"), 1, "vendor/lineage/overlay/common")
        rro = os.path.join(top, "vendor/pixel-style/rro_overlays")
        if os.path.isdir(rro):
            for d in sorted(os.listdir(rro)):
                m = os.path.join(rro, d, "AndroidManifest.xml")
                try:
                    o = overlay(m) if os.path.isfile(m) else None
                except (ET.ParseError, OSError):
                    o = None
                if o and o[0] == "android" and o[2] == "true":
                    scan(os.path.join(rro, d, "res", "values"),
                         int(o[1]) if o[1].lstrip("-").isdigit() else 0, "vendor/pixel-style/rro_overlays/" + d)
        for pr, label, v in sorted(rows, key=lambda r: -r[0]):
            print("%d\t%s\t%s" % (pr, label, v))
    elif mode == "zip-has" and len(args) >= 3:
        with zipfile.ZipFile(args[0]) as z:
            data = z.read(args[1])
        for t in args[2:]:
            hit = t.encode("utf-8") in data or t.encode("utf-16-le") in data
            print(("found " if hit else "missing ") + t)
    elif mode == "privapp" and len(args) == 2:
        for p in ET.parse(args[0]).getroot().iter("privapp-permissions"):
            if p.get("package") != args[1]:
                print("other " + str(p.get("package")))
                continue
            for e in p:
                if e.tag == "permission":
                    print("permission " + str(e.get("name")))
                elif e.tag == "deny-permission":
                    print("deny " + str(e.get("name")))
    elif mode == "hiddenapi" and len(args) == 2:
        root = ET.parse(args[0]).getroot()
        if any(e.get("package") == args[1] for e in root.iter("hidden-api-whitelisted-app")):
            print("whitelisted")
    elif mode == "install-in" and len(args) == 2:
        for p in ET.parse(args[0]).getroot().iter("install-in-user-type"):
            if p.get("package") == args[1]:
                for e in p:
                    if e.tag in ("install-in", "do-not-install-in"):
                        print("%s %s" % (e.tag, e.get("user-type")))
    else:
        usage()

main(sys.argv)
