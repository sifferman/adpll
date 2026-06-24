import sys, re
vlng_h, outdir = sys.argv[1], sys.argv[2]
pat = re.compile(r'VL_(INOUT|OUT|IN)(\d+)\(&(\w+)\s*,\s*(\d+)\s*,\s*(\d+)\)')
buckets = {"IN": [], "OUT": [], "INOUT": []}
for line in open(vlng_h):
    m = pat.search(line)
    if m:
        kind, size, name, msb, lsb = m.groups()
        buckets[kind].append(f"VL_DATA({size},{name},{msb},{lsb})\n")
open(outdir+"/inputs.h","w").write("".join(buckets["IN"]))
open(outdir+"/outputs.h","w").write("".join(buckets["OUT"]))
open(outdir+"/inouts.h","w").write("".join(buckets["INOUT"]))
print("ports -> in:%d out:%d inout:%d" % (len(buckets["IN"]),len(buckets["OUT"]),len(buckets["INOUT"])))
