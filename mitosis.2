# this would be the system base definition, structurally:
# /etc/build.celmag -> source [wildcard /etc/celmag/*.celmag]

# mitosis lives in the $PATH, and would source these files, and provide the interfaces they invoke.

# /etc/celmag/00-local-configuration.celmag [alterable]

# note some ambiguity exists among the "env and local-variables" ideally all envs would be properly prefixed with the env namespace.
# I avoided screamcase in some places, but this should be usage compatible with skel and make.
set-default PREFER_GCC 0
set-default PREFER_MOLD 1
set-default VERBOSE 0

set-default jobs [nproc]
set-default max_load [expr 1 + $jobs]

# /etc/celmag/05.c+cpp+gperf.celmag [distribution controlled]

# less flexible than 01-compile.mk
set-default PREFER_GCC 0
set-default PREFER_MOLD 1
set-default VERBOSE 0
set-default cc [if $PREFER_GCC gcc clang]
set-default cpp [if $PREFER_GCC g++ clang++]
set-default QUIET [not $VERBOSE]

if [expr $PREFER_MOLD && [set-default mold [which mold]]] {
  set-add ldflags -fuse-ld=mold
  set-defualt ld mold
}

if [set-default DEBUG 0] {
  set-add cflags -fstack-protector-strong
  set-add cxxflags -fstack-protector-strong
  if [expr $PLATFORM == Mac] {
    set-add cflags -fstack-clash-protection
    set-add cxxflags -fstack-clash-protection
    if [expr 0] {
      set-add cflags {-fPIE -pie}
      set-add cxxflags {-fPIE -pie}
    }
    set-add ldflags {-Wl,-z,relro,-z,now}
  }
  set-add cppflags -D_FORTIFY_SOURCE=3
}

# digestion orientation, fundamental ordinance

# pass-in
digest start : target source object
  # goal
  executable target
  # structual requants
  exists source
  create object [rebase object [directories [tree source]]]
  # relations
  canon-and-similar .cpp {.c++ .C}
  then .gperf .h
  then .gperf.h .c
  then .c {.d .o}
  then .cpp {.d .o}
  then .o target
  # routing
  origin source {.c .c++}
  destinity object {.h .d .o}
  destinity . {target}
  # the special cleanup target
  cleanup {.d .o target}
  # envorimental needs, after then section for procedural conditional.
  need cc
  if [expr 0 != [length $.cpp.all]] { need cpp; }
  # envorimental wants
  uses cflags cxxflags cppflags ldflags
  set-add cppflags [prepend "-I" [directories [tree object]]]
digest define
  produce "$cc -MMD -MP $cflags $cppflags $ldflags -o $.c $.o" {.c} {.d .o}
  produce "$cpp -MMD -MP $cxxflags $cppflags $ldflags -o $.cpp $.o" {.cpp} {.d .o}
  if [expr 0 == [length $.cpp.all]] \
  {produce  "$cc -o $target $.o" {.o} {target}} \
  {produce "$cpp -o $target $.o" {.o} {target}}
  produce "gperf $.gperf --output-file $.h" {.gperf} {.h}
digest end

# /etc/celmag/10.default_target.celmag [distribution controlled]

default-target [basename $PWD].out source object
# exclusive-subtarget test.out { source/test.c source/2.c source/3.c }
