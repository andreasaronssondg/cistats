# plot-pipeline-duration.gp
#
# Usage:
#   gnuplot -e "datafile='file.csv'; outfile='out.png'; gtitle='Title'" plot-pipeline-duration.gp
#
# Plots execution time (queue wait excluded) with outlier filtering:
#   - Faint dots for individual runs (capped, outliers removed)
#   - Shaded band between weekly median and p75
#   - Bold median line with sample count labels
#   - Monthly mean printed as annotation
#
# CSV columns:
#  1=run_id, 2=workflow_name, 3=status, 4=conclusion,
#  5=created_at, 6=updated_at, 7=wall_clock_seconds, 8=wall_clock_minutes,
#  9=exec_seconds, 10=exec_minutes, 11=queue_seconds, 12=queue_minutes,
#  13=first_job_started, 14=last_job_completed,
#  15=head_branch, 16=event, 17=pr_number, 18=label_group

if (!exists("datafile")) datafile = "ci-metrics-data/all-runs.csv"
if (!exists("outfile"))  outfile  = "pipeline-duration.png"
if (!exists("gtitle"))   gtitle   = "CI Pipeline Execution Time (excl. queue)"
if (!exists("scriptdir")) scriptdir = "."

OUTLIER_CAP = 300  # minutes — runs above this are excluded

set terminal pngcairo size 1400,900 enhanced font "Arial,11"
set output outfile

set datafile separator ","

set xlabel "Date"
set ylabel "Execution Time (minutes)"

set xdata time
set timefmt "%Y-%m-%dT%H:%M:%SZ"
set format x "%m-%d"
set xtics rotate by -45

set key outside right top font ",10"
set grid ytics lt 0 lw 0.5 lc rgb "#dddddd"
set grid xtics lt 0 lw 0.5 lc rgb "#dddddd"

set yrange [0:OUTLIER_CAP * 1.1]

# --- Awk filters: success + has exec time + under cap ---
mz_filter = "awk -F',' 'NR>1 && $2==\"MZ-CI\" && $4==\"success\" && $10+0>0 && $10+0<=".sprintf("%d", OUTLIER_CAP)."'"
pe_filter = "awk -F',' 'NR>1 && $2==\"PE-CI\" && $4==\"success\" && $10+0>0 && $10+0<=".sprintf("%d", OUTLIER_CAP)."'"

py_weekly  = "python3 ".scriptdir."/aggregate.py --weekly --cap ".sprintf("%d", OUTLIER_CAP)
py_monthly = "python3 ".scriptdir."/aggregate.py --monthly --cap ".sprintf("%d", OUTLIER_CAP)

# Count data points
mz_count = system(mz_filter." ".datafile." | wc -l") + 0
pe_count = system(pe_filter." ".datafile." | wc -l") + 0

if (mz_count == 0 && pe_count == 0) {
    set title gtitle font ",14"
    set label 1 "No successful runs found (or all above cap)" at graph 0.5, graph 0.5 center font ",14"
    plot NaN notitle
    exit
}

# --- Monthly mean annotations ---
# Place at top of chart as text labels

# For MZ-CI
if (mz_count > 0) {
    mz_monthly_data = system(mz_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_monthly)
    label_idx = 1
    do for [line in mz_monthly_data] {
        month = word(line, 1)  # not clean — use system parsing instead
    }
}

# Use a cleaner approach: write monthly labels via a loop over system() output lines
# gnuplot's string handling is limited, so we write labels from system() directly

# Clear any previous labels
unset label

# Place monthly mean labels at top of plot
# MZ-CI monthly labels (blue)
if (mz_count > 0) {
    mz_months = system(mz_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_monthly)
    idx = 1
    do for [line in mz_months] {
        mo    = word(line, 1)
        # monthly output: month,mean,median,count — but comma-separated in one "word"
        # We need to parse differently since gnuplot word() splits on spaces
    }
}

# gnuplot's string parsing is too limited for inline CSV. Use a temp file approach instead.
# Write monthly annotations from system() into a temp file, then load them.

mz_label_file = system("mktemp")
pe_label_file = system("mktemp")

if (mz_count > 0) {
    dummy = system(mz_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_monthly." | awk -F',' '{printf \"set label \\\"MZ %s: average %.0f min, median %.0f min (%s successful runs)\\\" at \\\"%s-15T12:00:00Z\\\",".sprintf("%d", OUTLIER_CAP * 1.05)." center font \\\",9\\\" tc rgb \\\"#1565C0\\\"\\n\", $1, $2, $3, $4, $1}' > ".mz_label_file)
    load mz_label_file
}

if (pe_count > 0) {
    dummy = system(pe_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_monthly." | awk -F',' '{printf \"set label \\\"PE %s: average %.0f min, median %.0f min (%s successful runs)\\\" at \\\"%s-15T12:00:00Z\\\",".sprintf("%d", OUTLIER_CAP * 0.98)." center font \\\",9\\\" tc rgb \\\"#E65100\\\"\\n\", $1, $2, $3, $4, $1}' > ".pe_label_file)
    load pe_label_file
}

# Cleanup temp files
dummy = system("rm -f ".mz_label_file." ".pe_label_file)

# --- Title with monthly context ---
set title gtitle font ",14"

# --- Data pipes ---
# Raw points (capped)
mz_raw = "< ".mz_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | sort -t',' -k1"
pe_raw = "< ".pe_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | sort -t',' -k1"

# Weekly aggregates: timestamp,median,p75,count
mz_agg = "< ".mz_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_weekly
pe_agg = "< ".pe_filter." ".datafile." | awk -F',' '{print $5\",\"$10}' | ".py_weekly

# --- Plot ---
# Filledcurves between median and p75 for the shaded band
# Weekly agg columns: 1=timestamp, 2=median, 3=p75, 4=count

if (mz_count > 0 && pe_count > 0) {
    plot \
      mz_agg using 1:2:3 with filledcurves lc rgb "#BBDEFB" notitle, \
      pe_agg using 1:2:3 with filledcurves lc rgb "#FFE0B2" notitle, \
      mz_raw using 1:2 with points pt 7 ps 0.25 lc rgb "#90CAF9" notitle, \
      pe_raw using 1:2 with points pt 7 ps 0.25 lc rgb "#FFCC80" notitle, \
      mz_agg using 1:2 with linespoints pt 7 ps 0.7 lw 2.5 lc rgb "#1565C0" title "MZ-CI median", \
      mz_agg using 1:3 with lines lw 1.5 dt 4 lc rgb "#1565C0" title "MZ-CI p75", \
      pe_agg using 1:2 with linespoints pt 7 ps 0.7 lw 2.5 lc rgb "#E65100" title "PE-CI median", \
      pe_agg using 1:3 with lines lw 1.5 dt 4 lc rgb "#E65100" title "PE-CI p75", \
      mz_agg using 1:2:(sprintf("n=%d", column(4))) with labels offset 0,1 font ",8" tc rgb "#1565C0" notitle, \
      pe_agg using 1:2:(sprintf("n=%d", column(4))) with labels offset 0,-1 font ",8" tc rgb "#E65100" notitle
}

if (mz_count > 0 && pe_count == 0) {
    plot \
      mz_agg using 1:2:3 with filledcurves lc rgb "#BBDEFB" notitle, \
      mz_raw using 1:2 with points pt 7 ps 0.25 lc rgb "#90CAF9" notitle, \
      mz_agg using 1:2 with linespoints pt 7 ps 0.7 lw 2.5 lc rgb "#1565C0" title "Median", \
      mz_agg using 1:3 with lines lw 1.5 dt 4 lc rgb "#1565C0" title "p75", \
      mz_agg using 1:2:(sprintf("n=%d", column(4))) with labels offset 0,1 font ",8" tc rgb "#1565C0" notitle
}

if (mz_count == 0 && pe_count > 0) {
    plot \
      pe_agg using 1:2:3 with filledcurves lc rgb "#FFE0B2" notitle, \
      pe_raw using 1:2 with points pt 7 ps 0.25 lc rgb "#FFCC80" notitle, \
      pe_agg using 1:2 with linespoints pt 7 ps 0.7 lw 2.5 lc rgb "#E65100" title "Median", \
      pe_agg using 1:3 with lines lw 1.5 dt 4 lc rgb "#E65100" title "p75", \
      pe_agg using 1:2:(sprintf("n=%d", column(4))) with labels offset 0,1 font ",8" tc rgb "#E65100" notitle
}
