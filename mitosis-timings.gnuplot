# Mitosis timing history.
# Usage:
#   gnuplot -e "CSV='.mitosis/timings.csv'; PNG='mitosis-timings.png'" \
#       mitosis-timings.gnuplot
#
# if you see:
# Could not find/open font when opening font "arial", using internal non-scalable font
# set in your .bashrc:
# export export GDFONTPATH=/usr/share/fonts/corefonts
#
# CSV columns:
#   1 record, 2 run_id, 3 timestamp_ms, 4 job_id, 5 output, 6 phase,
#   7 status, 8 elapsed_us, 9 work_us, 10 jobs, 11 source_file,
#   12 source_lines, 13 source_files

if (!exists("CSV")) CSV = ".mitosis/timings.csv"
if (!exists("PNG")) PNG = "mitosis-timings.png"
# Optional exact run-id filter for job/group/source panels; empty means all history.
if (!exists("RUN_ID")) RUN_ID = ""

set datafile separator comma
# Pick an available PNG terminal: pngcairo if built in, else libgd's png.
if (strstrt(GPVAL_TERMINALS, "pngcairo") > 0) {
    set terminal pngcairo size 1800,1200 enhanced font "Sans,10"
} else {
    if (strstrt(GPVAL_TERMINALS, " png ") > 0 || strstrt(GPVAL_TERMINALS, "\npng ") > 0) {
        set terminal png size 1800,1200 enhanced
    } else {
        print "mitosis-timings: this gnuplot has neither pngcairo nor png; install a gnuplot built with cairo or gd"
        exit status 1
    }
}
set output PNG
set multiplot layout 2,2 rowsfirst title "Mitosis build timing history"
set grid ytics
set style fill solid 0.65 border

# Whole-build wall time over history.
set title "Whole-build wall time"
set xlabel "Build start"
set ylabel "Seconds"
set xdata time
set timefmt "%s"
set format x "%H:%M:%S"
set key off
plot CSV using ($3/1000.0):(strcol(1) eq "run" ? $8/1000000.0 : 1/0) \
    with linespoints linewidth 2 pointsize 1.4 title "build wall time"
unset xdata
set format x "%g"

# Phase wall span versus summed worker time. These differ under parallelism.
set title "Phase wall time vs summed job time"
set xlabel "Phase"
set ylabel "Milliseconds"
set xtics rotate by -20
set key top left
set style histogram clustered gap 1
set style data histograms
plot CSV using (strcol(1) eq "group" && (RUN_ID eq "" || strcol(2) eq RUN_ID) ? $8/1000.0 : 1/0):xticlabels((strcol(1) eq "group" && (RUN_ID eq "" || strcol(2) eq RUN_ID)) ? sprintf("%s %s", strcol(6), strftime("%H:%M:%S", $3/1000.0)) : "") \
        title "phase wall", \
     CSV using (strcol(1) eq "group" && (RUN_ID eq "" || strcol(2) eq RUN_ID) ? $9/1000.0 : 1/0):xticlabels((strcol(1) eq "group" && (RUN_ID eq "" || strcol(2) eq RUN_ID)) ? sprintf("%s %s", strcol(6), strftime("%H:%M:%S", $3/1000.0)) : "") \
        title "summed job time"
unset xtics
unset style histogram
unset style data
set xtics autofreq norotate

# Direct translation-unit LOC against its compile duration.
set title "Compile time vs direct source lines"
set xlabel "Source lines (headers excluded)"
set ylabel "Compile milliseconds"
set key off
plot CSV using (strcol(1) eq "file" && strcol(6) eq "compile" && (RUN_ID eq "" || strcol(2) eq RUN_ID) ? $12 : 1/0):($8/1000.0) \
        with points pointsize 1.5 title "translation units", \
     CSV using (strcol(1) eq "file" && strcol(6) eq "compile" && (RUN_ID eq "" || strcol(2) eq RUN_ID) ? $12 : 1/0):($8/1000.0):(strcol(11)) \
        with labels offset char 1,1 notitle

# Individual executed job durations, including link jobs.
set title "Individual job duration"
set xlabel "Output"
set ylabel "Milliseconds"
set xtics rotate by -45
set key off
plot CSV using (strcol(1) eq "job" && (RUN_ID eq "" || strcol(2) eq RUN_ID) ? $8/1000.0 : 1/0):xticlabels((strcol(1) eq "job" && (RUN_ID eq "" || strcol(2) eq RUN_ID)) ? sprintf("%s %s", strcol(5), strftime("%H:%M:%S", $3/1000.0)) : "") \
    with boxes title "job duration"

unset multiplot
set output
