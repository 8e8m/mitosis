# 03-debug.celmag -- port of skel's 03-debug.mk for C/C++ (LFLAGS/YFLAGS have no equivalent here).
# Install as /etc/celmag/03-debug.celmag.
#
#   DEBUG=1            debugging info, warnings, no inlining; otherwise: LTO, vectorize, NDEBUG
#   SANITIZE=1         sanitizers (implies DEBUG)
#   VECTORIZED_ALL=1   report all auto-vectorization decisions
#   VECTORIZED=1       report successful auto-vectorization only
#   DO_LTO=0           disable LTO (always off when the project selects the digest "lib")
#
# Set them in the environment (DEBUG=1 mitosis), on the command line (mitosis DEBUG=1),
# or in build.celmag.  Only acts when the project selects the digest "c".

set-default DEBUG          0
set-default SANITIZE       0
set-default VECTORIZED_ALL 0
set-default VECTORIZED     0
set-default PLATFORM       $::tcl_platform(os)

# clang | gcc | unknown, by asking the compiler (cc may be either)
proc compiler-kind {cc} {
    if {[catch {exec {*}$cc --version 2>@1} out]} {return unknown}
    set out [string tolower $out]
    if {[string match *clang* $out]} {return clang}
    if {[string match *gcc* $out] || [string match "*free software foundation*" $out]} {return gcc}
    return unknown
}

# runs after build.celmag, so it sees the project's final variables and digests
finalize {
    # C/C++ only: other digests have no CC or CFLAGS to adjust
    if {"c" in $::mitosis::used} {
        set kind [compiler-kind $CC]
        set dbg  [expr {$DEBUG ne "0" || $SANITIZE ne "0"}]
        set lto  [expr {"lib" in $::mitosis::used ? 0 : [var DO_LTO 1]}]

        set pre {}   ;# goes before the user's flags, so theirs win
        set cf  {}   ;# after them, C and C++
        set lf  {}   ;# codegen flags the linker needs too (the link line carries LDFLAGS only)

        if {$dbg} {
            set pre {-fno-inline -Wall -Wextra -Wpedantic -Wshadow -Wundef -fno-omit-frame-pointer}
            switch -- $kind {
                clang {
                    if {$lto} {lappend cf -flto=thin; lappend lf -flto=thin}
                    lappend cf -glldb
                }
                gcc     {lappend cf -pg -ggdb; lappend lf -pg}
                default {lappend cf -g}
            }
        } else {
            if {$lto} {
                set f [expr {$kind eq "gcc" ? "-flto=auto" : "-flto"}]
                lappend cf $f; lappend lf $f
            }
            lappend cf -ftree-vectorize
            if {$::tcl_platform(machine) in {x86_64 amd64}} {lappend cf -march=x86-64 -mtune=generic}
            set-add CPPFLAGS -DNDEBUG
        }

        if {$SANITIZE ne "0"} {
            if {$kind eq "clang"} {
                set san {-fvisibility=hidden -fsanitize=address,leak,undefined,bounds}
                if {$PLATFORM eq "Linux"} {lappend san -fsanitize=cfi}
            } else {
                set san {-fsanitize=address,leak,undefined}
            }
            lappend cf {*}$san
            lappend lf {*}$san
        }

        if {$VECTORIZED_ALL ne "0"} {
            lappend cf {*}[expr {$kind eq "clang" ? {-Rpass=loop-vectorize -Rpass-missed=loop-vectorize} : {-fopt-info-vec-all}}]
        } elseif {$VECTORIZED ne "0"} {
            lappend cf {*}[expr {$kind eq "clang" ? {-Rpass=loop-vectorize} : {-fopt-info-vec-optimized}}]
        }

        set CFLAGS   [concat $pre $CFLAGS   $cf]
        set CXXFLAGS [concat $pre $CXXFLAGS $cf]
        set-add LDFLAGS {*}$lf
    }
}
