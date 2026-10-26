#!/usr/bin/env python3
# XML reads for v4a-check.sh. Run it with python3 -I.
#
#   v4a-xml.py aidl-effect <xml>...     print each file that declares an AIDL
#                                       android.hardware.audio.effect HAL (VINTF
#                                       <hal format="aidl">), "unparseable <file>" for
#                                       a file that isn't XML
#   v4a-xml.py privapp <xml> <package>  print "permission <name>" / "deny <name>" for
#                                       <package>, and "other <package>" for any other
#   v4a-xml.py hiddenapi <xml> <package>  print "whitelisted" if <package> is listed
import sys
import xml.etree.ElementTree as ET

def main(argv):
    if len(argv) < 2:
        sys.exit("usage: v4a-xml.py aidl-effect|privapp|hiddenapi ...")
    mode, args = argv[1], argv[2:]
    if mode == "aidl-effect":
        for path in args:
            try:
                root = ET.parse(path).getroot()
            except (ET.ParseError, OSError):
                print("unparseable " + path)
                continue
            for hal in root.iter("hal"):
                name = (hal.findtext("name") or "").strip()
                if hal.get("format") == "aidl" and name == "android.hardware.audio.effect":
                    print(path)
                    break
    elif mode == "privapp" and len(args) == 2:
        root = ET.parse(args[0]).getroot()
        for p in root.iter("privapp-permissions"):
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
    else:
        sys.exit("usage: v4a-xml.py aidl-effect|privapp|hiddenapi ...")

main(sys.argv)
