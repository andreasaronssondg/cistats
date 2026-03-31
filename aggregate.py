#!/usr/bin/env python3
"""Aggregate CI run data into weekly and monthly summaries.

Reads CSV lines from stdin: timestamp,exec_minutes
Filters outliers (> outlier_cap), then outputs weekly and monthly aggregates.

Usage:
    awk -F',' '...' data.csv | python3 aggregate.py --weekly [--cap 300]
    awk -F',' '...' data.csv | python3 aggregate.py --monthly [--cap 300]
"""

import sys
import argparse
import statistics
import datetime
import collections


def parse_args():
    p = argparse.ArgumentParser()
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--weekly", action="store_true", help="Output weekly aggregates")
    mode.add_argument("--monthly", action="store_true", help="Output monthly aggregates")
    p.add_argument("--cap", type=float, default=300.0,
                   help="Exclude runs longer than this many minutes (default: 300)")
    return p.parse_args()


def read_data(cap):
    """Read timestamp,value lines from stdin, filtering outliers."""
    data = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        ts, val = line.split(",", 1)
        val = float(val)
        if val > cap or val <= 0:
            continue
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        data.append((dt, val))
    return data


def weekly_aggregate(data):
    """Group by ISO week, output: midpoint_timestamp,median,p75,count"""
    weeks = collections.defaultdict(list)
    for dt, val in data:
        wk = dt.strftime("%G-W%V")
        weeks[wk].append(val)

    for wk in sorted(weeks):
        v = sorted(weeks[wk])
        yr, w = wk.split("-W")
        mid = datetime.datetime.strptime(f"{yr}-W{w}-3", "%G-W%V-%u")
        med = statistics.median(v)
        p75_idx = max(0, int(len(v) * 0.75) - 1)
        p75 = v[p75_idx]
        print(f"{mid.strftime('%Y-%m-%dT12:00:00Z')},{med:.1f},{p75:.1f},{len(v)}")


def monthly_aggregate(data):
    """Group by month, output: month_label,mean,median,count"""
    months = collections.defaultdict(list)
    for dt, val in data:
        key = dt.strftime("%Y-%m")
        months[key].append(val)

    for key in sorted(months):
        v = months[key]
        mean = statistics.mean(v)
        med = statistics.median(v)
        print(f"{key},{mean:.1f},{med:.1f},{len(v)}")


def main():
    args = parse_args()
    data = read_data(args.cap)

    if not data:
        return

    if args.weekly:
        weekly_aggregate(data)
    elif args.monthly:
        monthly_aggregate(data)


if __name__ == "__main__":
    main()
