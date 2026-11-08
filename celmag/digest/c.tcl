# digest c -- C and C++ (and gperf), objects named by accumulated suffix (foo.c -> foo.c.o).
# Select it from build.celmag with:  use c
#
# Everything C-specific lives here, none of it in mitosis itself: the edges, the toolchain
# choice and its default flags.  `have` is a mitosis helper (is this program on PATH).

proc pick-cc {preferGcc} {
    foreach c [expr {$preferGcc ? {gcc clang} : {clang gcc}}] {if {[have $c]} {return $c}}
    return cc
}
proc cxx-of {cc} {
    switch -- $cc {clang {return clang++} gcc {return g++} default {return c++}}
}

set-default PREFER_GCC  0
set-default PREFER_MOLD 1
set-default CC          [pick-cc $PREFER_GCC]
set-default CPP         [cxx-of $CC]
set-default CFLAGS      {-std=c23 -O2}   ;# -pthread
set-default CXXFLAGS    {-std=c++20 -O2}
set-default CPPFLAGS    {}
set-default LDFLAGS     {} ;# -lc -lm -lchad
if {$PREFER_MOLD && [have mold]} {set-add LDFLAGS -fuse-ld=mold}

at source {.c .cpp .gperf .h}
at object {.gperf.h .d .o}
at .      {target}

alias .cpp {.c++ .C}
depfile .d

relate .gperf   .h      {gperf $.gperf --output-file $.h}
relate .gperf.h .c
relate .gperf.h .cpp
relate .c   {.o .d}     {$CC  -MMD -MF $.d $incdirs $CFLAGS   $CPPFLAGS -c $.c   -o $.o}
relate .cpp {.o .d}     {$CPP -MMD -MF $.d $incdirs $CXXFLAGS $CPPFLAGS -c $.cpp -o $.o}
relate .o   target      {$LD -o $target $.o $LDFLAGS}
