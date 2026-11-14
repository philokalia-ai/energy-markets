"""Compare exact book dumps from benchmark_runtime_upgrade.jl.

Usage: python3 compare_runtime_books.py RESULTS_DIR
Set OPS_BOOK_DUMP_PREFIX to RESULTS_DIR/{old12,new12,stable13} for each arm.
Output book_value_deltas.csv compares sorted semantic order groups and capacity
keys. Relative error uses max(1 MW, abs(reference)) as its denominator; absolute
MW error is reported separately. Exact hashes remain in benchmark JSON.
"""
from collections import defaultdict
import csv
from pathlib import Path
import struct
import sys
root=Path(sys.argv[1])
def number(bits):
    return struct.unpack('!d',int(bits,2).to_bytes(8,'big'))[0]
def read_caps(p):
    return {tuple(parts[:-1]):number(parts[-1]) for line in p.read_text().splitlines()
            if (parts:=line.split('|'))}
def read_orders(p):
    groups=defaultdict(list)
    for line in p.read_text().splitlines():
        z,t,k,price,qty,res=line.split('|')
        groups[z,t,k,res].append((number(price),number(qty)))
    return {k:sorted(v) for k,v in groups.items()}
rows=[]
for reference,config in [('old12','new12'),('new12','stable13')]:
    for old_file in sorted(root.glob(reference+'-*-capacities.txt')):
        stem=old_file.name[len(reference)+1:-len('-capacities.txt')]
        new_file=root/(config+'-'+stem+'-capacities.txt')
        if not new_file.exists():continue
        old,new=read_caps(old_file),read_caps(new_file)
        common=old.keys()&new.keys()
        cap_diff=[abs(old[k]-new[k]) for k in common]
        rel=[abs(old[k]-new[k])/max(1,abs(old[k])) for k in common]
        old_orders=read_orders(root/(reference+'-'+stem+'-orders.txt'))
        new_orders=read_orders(root/(config+'-'+stem+'-orders.txt'))
        order_keys=old_orders.keys()&new_orders.keys()
        price_delta=[];qty_delta=[];pairdiff=0
        for k in order_keys:
            for (p,q),(pp,qq) in zip(old_orders[k],new_orders[k]):
                price_delta.append(abs(p-pp));qty_delta.append(abs(q-qq))
                pairdiff+=(p,q)!=(pp,qq)
        rows.append(dict(reference=reference,config=config,book=stem,
            capacity_common=len(common),capacity_missing_reference=len(new.keys()-old.keys()),
            capacity_missing_treatment=len(old.keys()-new.keys()),
            capacity_differences=sum(v!=0 for v in cap_diff),capacity_max_abs_mw=max(cap_diff,default=0),
            capacity_max_relative=max(rel,default=0),
            capacity_criterion_pass=old.keys()==new.keys() and max(rel,default=0)<=1e-6,
            order_groups_match=old_orders.keys()==new_orders.keys(),
            order_group_counts_match=all(len(old_orders[k])==len(new_orders[k]) for k in order_keys),
            order_pairs_differ=pairdiff,order_max_price_delta=max(price_delta,default=0),
            order_max_quantity_delta_mw=max(qty_delta,default=0)))
if rows:
    with (root/'book_value_deltas.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
    for r in rows:print(r)
