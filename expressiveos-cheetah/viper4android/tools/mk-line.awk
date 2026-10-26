# Where a makefile has a line: want="<line>" awk -f mk-line.awk -- <makefile>
# Prints "top" when the line is there outside every ifeq/ifneq/ifdef/ifndef and define
# block (so make always reads it), "nested" when it is there only inside such a block,
# and nothing when it isn't there. Leading spaces and trailing whitespace don't count.
# apply-v4a.sh and v4a-check.sh use it for the inherit line in vendor/extra/product.mk.
function trim(s) { sub(/^ +/, "", s); sub(/[ \t\r]+$/, "", s); return s }
BEGIN { want = trim(ENVIRON["want"]); depth = 0 }
{
    l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t\r]+$/, "", l)
    if (l ~ /^(ifeq|ifneq|ifdef|ifndef)([ \t(]|$)/ || l ~ /^define([ \t]|$)/) { depth++; next }
    if (l ~ /^(endif|endef)([ \t#]|$)/) { if (depth > 0) depth--; next }
    if (trim($0) == want) { if (depth == 0) top = 1; else nested = 1 }
}
END { if (top) print "top"; else if (nested) print "nested" }
