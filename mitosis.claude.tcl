#!/usr/bin/env tclsh
#
# Highly directed build system theorized by me and actually manifest by claude.
#
# Fits in anywhere where Skel would, with flag transmutation from GNUmakefile to build.celmag
#
# Relates mitosis.2 and could be improved / simplified.
#
# mitosis -- prototype.  tclsh 8.6+, coreutils sha256sum.
#
#   mitosis [-C dir] [-j N] [-B] [-n] [-v] [--eval-path] [VAR=value ...] [clean | TARGET...]
#
# Model: one primitive, the edge.  Files are globbed from source rows of the
# "at" table; the file DAG is (files x edges), computed.  Transformations
# append a suffix (foo.c -> foo.c.o, foo.gperf -> foo.gperf.h), so a file's
# name carries its derivation.  Cache key = hash(argv, tool identity, input
# contents, recorded dep contents), not mtime.
#
# DSL (all plain Tcl commands, variables are plain Tcl globals):
# note, this is all targeted around suffixes.
#   at DIR EXTS          where files of these types live (additive) (think vpath but flexible)
#   alias CANON NAMES    other spellings of an extension (i.e. .c++ should be treated the same as .cpp)
#   relate FROM TO ?CMD? TO starting with "." appends a suffix per file;
#                        a bare TO folds all FROM files into that one file;
#                        no CMD = ordering edge only
#   depfile EXT          outputs of this type are make-style dep files; their
#                        contents are recorded as extra inputs of the job
#                        (exists solely for .d)
#   use NAME             load a digest (named edge set, that generally processes a group of commands)
#                        REQUIRED: build.celmag must select at least one digest, there is no default
#   set-default V X      set V unless already set (env var V wins if uppercase)
#   set-add V items...   append to list variable V
#   target NAME ?opts?   a final file built from a subset of the shared objects (all of them by default)
#                          -only GLOBS   keep only objects whose originating source matches one of these
#                          -not  GLOBS   drop objects whose originating source matches one of these
#                          -with {V X..} replace variables for this target's final command
#                          -add  {V X..} append to variables for this target's final command
#                          -role ROLE    which final-edge role it fills (default: target)
#                        GLOBS are `string match` patterns on the source path, e.g. source/test/*
#                        Per-target flags only reach the final (link) command; compile flags are shared.
#   default-target NAME  same as `target NAME` (every object)
#   finalize SCRIPT      run SCRIPT after build.celmag and before planning, so a system-layer
#                        file can branch on the project's final variables and chosen digests
#
# Variables from outside: VAR=value in the environment works for any variable declared with
# set-default.  On the command line, `mitosis CFLAGS=-O0 DEBUG=1` sets VAR for this run and
# beats build.celmag and finalize scripts (like make); `VAR+=value` appends after them.
# This file carries no build policy.  Digests, toolchain defaults and flag layers all live in
# "celmag directories" found along the eval path, and without them mitosis does nothing.
#
#   eval path   MITOSIS_EVAL_PATH (colon-separated, first wins) if set, else the XDG locations:
#                 $XDG_CONFIG_HOME/mitosis           (~/.config/mitosis)
#                 $XDG_DATA_HOME/mitosis/celmag      (~/.local/share/mitosis/celmag)
#                 /etc/celmag
#                 each $XDG_DATA_DIRS entry + /mitosis/celmag   (/usr/local/share:/usr/share)
#               Only existing directories count; `mitosis --eval-path` prints what was found.
#   celmag dir  *.tcl at its top are layers, loaded in name order across the whole path;
#               a name found in an earlier directory shadows the same name in later ones (an empty
#               file disables a layer).  digest/NAME.tcl are digests, first one found wins.
#
# Layers, in order: layers from the eval path, build.celmag, finalize scripts, command line.
# (set-default is first-wins, so earlier layers win over later ones.)
#
# A build.celmag is REQUIRED; it is searched for upwards from the current directory and
# mitosis runs from the directory that holds it.  mitosis [clean | TARGET...] builds only
# the named targets (and what they need).
#
# CMD is a template, split into words at definition time.  $.ext is the
# input/output file of that type (a list for a fold), $var splices a list
# variable as separate arguments, so filenames with spaces survive.
#
# (Ideally this would be better suited to multiple executables, and the internals more separated and visually clear.)

namespace eval mitosis {
    variable rows    {}   ;# dir -> exts
    variable aliases {}   ;# alias -> canonical
    variable edges   {}   ;# {from to} -> template  (insertion ordered)
    variable order   {}   ;# ordering-only edges {from to}
    variable depexts {}
    variable used    {}
    variable finals  {}   ;# finalize scripts
    variable assigns {}   ;# command-line VAR=value / VAR+=value: name op words
    variable targets {}   ;# name -> options (-only -not -with -add -role)
    variable tjobs   {}   ;# target name -> job id
    variable evalpath {}
    variable known   {}
    variable outdirs {}
    variable srcdirs {}
    variable nodes   {}   ;# path -> {rel type anc job}
    variable bytype  {}   ;# type -> paths
    variable ids     {}
    variable njobs   0
    variable ready   {}
    variable remaining 0
    variable running 0
    variable failed  0
    variable done    0
    variable nran    0
    variable force   0
    variable dry     0
    variable maxjobs 1
    variable db      {}
    variable hmemo   {}
    variable tmemo   {}
    array set J {}
}

# ---------------------------------------------------------------- DSL

proc at {dir exts} {
    set cur {}
    if {[dict exists $::mitosis::rows $dir]} {set cur [dict get $::mitosis::rows $dir]}
    foreach e $exts {if {$e ni $cur} {lappend cur $e}}
    dict set ::mitosis::rows $dir $cur
}

proc alias {canon names} {
    foreach a $names {dict set ::mitosis::aliases $a $canon}
}

proc relate {from to {cmd {}}} {
    if {$cmd eq ""} {
        if {[list $from $to] ni $::mitosis::order} {lappend ::mitosis::order [list $from $to]}
    } else {
        dict set ::mitosis::edges [list $from $to] $cmd
    }
}

proc depfile {ext} {
    set c [mitosis::canon $ext]
    if {$c ni $::mitosis::depexts} {lappend ::mitosis::depexts $c}
}

proc use {name} {
    if {$name in $::mitosis::used} return
    set f [mitosis::find-digest $name]
    if {$f eq ""} {
        error "mitosis: no digest named '$name'\n  available: [join [mitosis::digest-names] {, }]\n  searched:  [join $::mitosis::evalpath {, }]"
    }
    lappend ::mitosis::used $name
    uplevel #0 [list source $f]
}

proc set-default {name value} {
    if {[info exists ::$name]} return
    if {[info exists ::env($name)]} {
        set ::$name [list {*}$::env($name)]
    } else {
        set ::$name $value
    }
}

proc set-add {name args} {
    if {![info exists ::$name]} {set ::$name {}}
    lappend ::$name {*}$args
}

proc target {name args} {
    array set o {-only {} -not {} -with {} -add {} -role target}
    foreach {k v} $args {
        if {![info exists o($k)]} {error "mitosis: target: unknown option '$k' (-only -not -with -add -role)"}
        set o($k) $v
    }
    if {[dict exists $::mitosis::targets $name]} {error "mitosis: target '$name' declared twice"}
    dict set ::mitosis::targets $name [array get o]
}

proc default-target {{name {}}} {if {$name ne ""} {target $name}}

proc finalize {script} {lappend ::mitosis::finals $script}

# small helpers for config files
proc have {x} {expr {[lindex [auto_execok $x] 0] ne ""}}
proc basename {p} {file tail $p}
proc nproc {} {
    if {[catch {exec nproc} n] || ![string is integer -strict $n]} {return 1}
    return $n
}
proc var {name {default {}}} {
    if {[info exists ::$name]} {return [set ::$name]}
    return $default
}

# ------------------------------------------------------------ types / paths

# ---------------------------------------------------------------- eval path

proc mitosis::xdg {name default} {
    if {[info exists ::env($name)] && [string index $::env($name) 0] eq "/"} {return $::env($name)}
    return $default
}

# directories to search, most specific first; only existing ones are kept
proc mitosis::eval-path {} {
    set raw {}
    if {[info exists ::env(MITOSIS_EVAL_PATH)]} {
        set raw [split $::env(MITOSIS_EVAL_PATH) :]
    } else {
        set cfg {}; set data {}
        if {[info exists ::env(HOME)] && $::env(HOME) ne ""} {
            set cfg  $::env(HOME)/.config
            set data $::env(HOME)/.local/share
        }
        set cfg  [xdg XDG_CONFIG_HOME $cfg]
        set data [xdg XDG_DATA_HOME $data]
        if {$cfg  ne ""} {lappend raw [file join $cfg mitosis]}
        if {$data ne ""} {lappend raw [file join $data mitosis celmag]}
        lappend raw /etc/celmag
        foreach d [split [xdg XDG_DATA_DIRS /usr/local/share:/usr/share] :] {
            if {[string index $d 0] eq "/"} {lappend raw [file join $d mitosis celmag]}
        }
    }
    set out {}
    foreach d $raw {
        if {$d eq ""} continue
        set d [file normalize $d]
        if {[file isdirectory $d] && $d ni $out} {lappend out $d}
    }
    return $out
}

proc mitosis::find-digest {name} {
    variable evalpath
    foreach d $evalpath {
        set f [file join $d digest $name.tcl]
        if {[file isfile $f] && [file readable $f]} {return $f}
    }
    return {}
}

proc mitosis::digest-names {} {
    variable evalpath
    set r {}
    foreach d $evalpath {
        foreach f [glob -nocomplain -directory [file join $d digest] *.tcl] {
            lappend r [file rootname [file tail $f]]
        }
    }
    return [lsort -unique $r]
}

# top-level *.tcl across the path, shadowed by name, in name order
proc mitosis::layer-files {} {
    variable evalpath
    set seen {}; set items {}
    foreach d $evalpath {
        foreach f [glob -nocomplain -directory $d -types {f l} *.tcl] {
            set t [file tail $f]
            if {[dict exists $seen $t]} continue
            dict set seen $t 1
            lappend items [list $t $f]
        }
    }
    return [lmap i [lsort -index 0 $items] {lindex $i 1}]
}

proc mitosis::cmplen {a b} {expr {[string length $b] - [string length $a]}}

proc mitosis::canon {e} {
    variable aliases
    if {[dict exists $aliases $e]} {return [dict get $aliases $e]}
    return $e
}

# all dotted extensions mentioned anywhere, longest first
proc mitosis::known-list {} {
    variable rows; variable aliases; variable edges; variable order
    set k {}
    dict for {d exts} $rows {lappend k {*}$exts}
    dict for {a c} $aliases {lappend k $a $c}
    dict for {key tmpl} $edges {lassign $key f to; lappend k $f {*}$to}
    foreach o $order {lappend k {*}$o}
    set r {}
    foreach e [lsort -unique $k] {if {[string index $e 0] eq "."} {lappend r $e}}
    return [lsort -command cmplen $r]
}

# longest known suffix of name, through aliases
proc mitosis::resolve {name} {
    variable known
    foreach e $known {
        set n [string length $e]
        if {[string length $name] > $n && [string range $name end-[expr {$n-1}] end] eq $e} {
            return [canon $e]
        }
    }
    return {}
}

proc mitosis::dir-for {type} {
    variable rows
    dict for {d exts} $rows {if {$type in $exts} {return $d}}
    return {}
}

proc mitosis::join-dir {d rel} {
    if {$d eq "."} {return $rel}
    return [file join $d $rel]
}

proc mitosis::out-path {type rel} {
    set d [dir-for $type]
    if {$d eq ""} {error "mitosis: no 'at' row for type '$type' (file $rel)"}
    return [join-dir $d $rel]
}

proc mitosis::find-files {dir} {
    set out [lsort [glob -nocomplain -directory $dir -types f *]]
    foreach d [lsort [glob -nocomplain -directory $dir -types d *]] {
        lappend out {*}[find-files $d]
    }
    return $out
}

proc mitosis::shq {w} {
    if {[regexp {^[A-Za-z0-9_./:=+,@%-]+$} $w]} {return $w}
    return "'[string map {' '\\''} $w]'"
}

# ----------------------------------------------------------- template expand

proc mitosis::lookup {v locals} {
    if {[dict exists $locals $v]} {return [dict get $locals $v]}
    if {[info exists ::$v]} {return [set ::$v]}
    error "mitosis: undefined variable \$$v in a command template"
}

proc mitosis::expand {tmpl ph locals} {
    set map {}
    foreach k [lsort -command cmplen [dict keys $ph]] {
        lappend map $k [join [dict get $ph $k] " "]
    }
    set out {}
    foreach w $tmpl {
        if {[dict exists $ph $w]} {lappend out {*}[dict get $ph $w]; continue}
        if {[regexp {^\$([A-Za-z_][A-Za-z0-9_]*)$} $w -> v]} {
            lappend out {*}[lookup $v $locals]
            continue
        }
        set s [string map $map $w]
        while {[regexp {\$([A-Za-z_][A-Za-z0-9_]*)} $s all v]} {
            set s [string map [list $all [join [lookup $v $locals] " "]] $s]
        }
        lappend out $s
    }
    return $out
}

# ------------------------------------------------------------------ planning

proc mitosis::add-node {path rel type anc job root} {
    variable nodes; variable bytype
    dict set nodes $path [dict create rel $rel type $type anc $anc job $job root $root]
    dict lappend bytype $type $path
}

proc mitosis::any-anc {paths ext} {
    variable nodes
    foreach p $paths {if {$ext in [dict get $nodes $p anc]} {return 1}}
    return 0
}

proc mitosis::new-job {id argv ins outs} {
    variable J; variable ids; variable nodes
    set deps {}; set types {}
    foreach p $ins {
        lappend types [dict get $nodes $p type]
        set pj [dict get $nodes $p job]
        if {$pj ne "" && $pj ni $deps} {lappend deps $pj}
    }
    set J($id,argv) $argv
    set J($id,ins) $ins
    set J($id,outs) $outs
    set J($id,deps) $deps
    set J($id,intypes) [lsort -unique $types]
    set J($id,rdeps) {}
    set J($id,out) {}
    lappend ids $id
}

proc mitosis::plan {} {
    variable rows; variable edges; variable order; variable known
    variable nodes; variable bytype; variable J; variable ids
    variable outdirs; variable srcdirs; variable njobs
    variable targets; variable tjobs

    set nodes {}; set bytype {}; set ids {}; set njobs 0; array unset J
    set known [known-list]

    if {![info exists ::incdirs]} {
        set ::incdirs [lmap d [dict keys $rows] {if {$d eq "."} continue; format -I%s $d}]
    }

    # rows that receive outputs; every other row is a source row
    set outdirs {}
    dict for {key tmpl} $edges {
        lassign $key from to
        foreach t $to {
            if {[string index $t 0] eq "."} {set ty [resolve x$from$t]} else {set ty $t}
            set d [dir-for $ty]
            if {$d eq ""} {error "mitosis: no 'at' row for the output of: relate $from $to"}
            if {$d ni $outdirs} {lappend outdirs $d}
        }
    }

    # sources
    set queue {}; set srcdirs {}
    dict for {d exts} $rows {
        if {$d in $outdirs} continue
        if {![file isdirectory $d]} {error "mitosis: source directory '$d' does not exist"}
        lappend srcdirs $d
        foreach f [find-files $d] {
            set rel [string range $f [expr {[string length $d]+1}] end]
            set ty [resolve $rel]
            if {$ty ne "" && $ty in $exts} {
                add-node $f $rel $ty [list $ty] {} $f
                lappend queue $f
            }
        }
    }

    # per-file edges, to a fixpoint over (virtual) names
    set i 0
    while {$i < [llength $queue]} {
        set p [lindex $queue $i]; incr i
        set n [dict get $nodes $p]
        dict for {key tmpl} $edges {
            lassign $key from to
            if {[string index [lindex $to 0] 0] ne "."} continue
            if {[canon $from] ne [dict get $n type]} continue
            if {[llength [dict get $n anc]] > 12} {error "mitosis: suffix chain too long at $p (cycle in edges?)"}
            set id [incr njobs]
            set ph [dict create "\$$from" [list $p]]
            set outs {}
            foreach t $to {
                set rel2 [dict get $n rel]$t
                set ty [resolve $rel2]
                set o [out-path $ty $rel2]
                dict set ph "\$$t" [list $o]
                lappend outs $o
                add-node $o $rel2 $ty [concat [dict get $n anc] $ty] $id [dict get $n root]
                lappend queue $o
            }
            new-job $id [expand $tmpl $ph {}] [list $p] $outs
        }
    }

    # folds: the objects of each declared target into that target's file
    set tjobs {}
    dict for {key tmpl} $edges {
        lassign $key from to
        if {[string index [lindex $to 0] 0] eq "."} continue
        set t [lindex $to 0]
        set all {}
        if {[dict exists $bytype [canon $from]]} {set all [lsort [dict get $bytype [canon $from]]]}
        if {![llength $all]} {
            error "mitosis: nothing to build for '$from' (no sources under: [join $srcdirs {, }])"
        }
        set found 0
        dict for {tname topt} $targets {
            if {[dict get $topt -role] ne $t} continue
            incr found
            set src {}
            foreach p $all {if {[wants $topt [dict get $nodes $p root]]} {lappend src $p}}
            if {![llength $src]} {error "mitosis: target '$tname' selects no inputs"}
            set o [join-dir [dir-for $t] $tname]
            if {[dict exists $tjobs $tname]} {error "mitosis: target '$tname' is produced twice"}
            set ph [dict create "\$$from" $src "\$$t" [list $o]]
            set locals {}
            if {![info exists ::LD]} {
                dict set locals LD [list [expr {[any-anc $src .cpp] ? [var CPP c++] : [var CC cc]}]]
            }
            dict for {k v} [dict get $topt -with] {dict set locals $k $v}
            dict for {k v} [dict get $topt -add] {
                if {[dict exists $locals $k]} {set cur [dict get $locals $k]} else {set cur [var $k]}
                dict set locals $k [concat $cur $v]
            }
            set id [incr njobs]
            dict set tjobs $tname $id
            new-job $id [expand $tmpl $ph $locals] $src [list $o]
        }
        if {!$found} {error "mitosis: no target of role '$t' is declared"}
    }

    # ordering edges: every job reading type B waits for all producers of type A
    foreach o $order {
        lassign $o a b
        set a [canon $a]; set b [canon $b]
        set prod {}
        if {[dict exists $bytype $a]} {
            foreach p [dict get $bytype $a] {
                set j [dict get $nodes $p job]
                if {$j ne "" && $j ni $prod} {lappend prod $j}
            }
        }
        foreach id $ids {
            if {$b in $J($id,intypes)} {
                foreach j $prod {
                    if {$j != $id && $j ni $J($id,deps)} {lappend J($id,deps) $j}
                }
            }
        }
    }
}

# does target options topt want the object that came from source root?
proc mitosis::wants {topt root} {
    set only [dict get $topt -only]
    if {[llength $only]} {
        set ok 0
        foreach g $only {if {[string match $g $root]} {set ok 1; break}}
        if {!$ok} {return 0}
    }
    foreach g [dict get $topt -not] {if {[string match $g $root]} {return 0}}
    return 1
}

# restrict the plan to the named targets (all if none) and wire up the scheduler counts
proc mitosis::select {names} {
    variable J; variable ids; variable tjobs
    if {[llength $names]} {
        set stack {}
        foreach nm $names {
            if {![dict exists $tjobs $nm]} {
                error "mitosis: unknown target '$nm' (declared: [join [dict keys $tjobs] {, }])"
            }
            lappend stack [dict get $tjobs $nm]
        }
        set seen {}
        while {[llength $stack]} {
            set stack [lassign $stack id]
            if {[dict exists $seen $id]} continue
            dict set seen $id 1
            lappend stack {*}$J($id,deps)
        }
        set ids [lsort -integer [dict keys $seen]]
    }
    foreach id $ids {set J($id,rdeps) {}}
    foreach id $ids {
        set J($id,pending) [llength $J($id,deps)]
        foreach d $J($id,deps) {lappend J($d,rdeps) $id}
    }
}

# ------------------------------------------------------------ hashing / cache

proc mitosis::sha256-text {text} {
    return [string range [exec sha256sum << $text] 0 63]
}

proc mitosis::hash-files {files} {
    variable hmemo
    set todo {}
    foreach f $files {
        if {[dict exists $hmemo $f]} continue
        if {[file isfile $f]} {lappend todo $f} else {dict set hmemo $f MISSING}
    }
    for {set i 0} {$i < [llength $todo]} {incr i 64} {
        set chunk [lrange $todo $i [expr {$i+63}]]
        foreach line [split [exec sha256sum -- {*}$chunk] \n] {
            dict set hmemo [string range $line 66 end] [string range $line 0 63]
        }
    }
    set r {}
    foreach f $files {lappend r [dict get $hmemo $f]}
    return $r
}

proc mitosis::tool-id {cmd} {
    variable tmemo
    if {![dict exists $tmemo $cmd]} {
        set p [lindex [auto_execok $cmd] 0]
        if {$p ne "" && [file exists $p]} {
            set v [list $p [file size $p] [file mtime $p]]
        } else {
            set v [list $cmd unresolved]
        }
        dict set tmemo $cmd $v
    }
    return [dict get $tmemo $cmd]
}

proc mitosis::job-key {id deps} {
    variable J
    return [sha256-text [list $J($id,argv) [tool-id [lindex $J($id,argv) 0]] \
        [hash-files $J($id,ins)] [hash-files $deps]]]
}

proc mitosis::job-clean {id} {
    variable J; variable db; variable force
    if {$force} {return 0}
    foreach o $J($id,outs) {if {![file exists $o]} {return 0}}
    set k [lindex $J($id,outs) 0]
    if {![dict exists $db $k]} {return 0}
    set rec [dict get $db $k]
    return [expr {[dict get $rec key] eq [job-key $id [dict get $rec deps]]}]
}

# make-style dep file: "target: dep dep \<newline> dep" -> list of deps (minus own inputs)
proc mitosis::parse-depfile {file ins} {
    if {[catch {set fd [open $file r]}]} {return {}}
    set t [read $fd]; close $fd
    set t [string map [list "\\\r\n" " " "\\\n" " "] $t]
    set i [string first : $t]
    if {$i < 0} {return {}}
    set line [lindex [split [string range $t [expr {$i+1}] end] \n] 0]
    set line [string map [list "\\ " \u0001] $line]
    set deps {}
    foreach w [regexp -all -inline {\S+} $line] {
        set w [string map [list \u0001 " "] $w]
        if {$w ni $ins && $w ni $deps} {lappend deps $w}
    }
    return $deps
}

proc mitosis::db-load {} {
    variable db
    set db {}
    if {![file exists .mitosis/db]} return
    set fd [open .mitosis/db r]; set d [read $fd]; close $fd
    if {![catch {dict size $d}]} {set db $d}
}

proc mitosis::db-save {} {
    variable db
    file mkdir .mitosis
    set fd [open .mitosis/db.tmp w]; puts $fd $db; close $fd
    file rename -force .mitosis/db.tmp .mitosis/db
}

# ----------------------------------------------------------------- scheduler

proc mitosis::say {id} {
    variable J
    set v [var VERBOSE 0]
    if {$v ni {0 {} false no}} {
        puts [join [lmap w $J($id,argv) {shq $w}] " "]
    } else {
        puts [format "%-8s %s" [file tail [lindex $J($id,argv) 0]] [lindex $J($id,outs) 0]]
    }
}

proc mitosis::finish {id} {
    variable J; variable ready; variable remaining
    incr remaining -1
    foreach r $J($id,rdeps) {
        if {[incr J($r,pending) -1] == 0} {lappend ready $r}
    }
}

proc mitosis::fail {id} {
    variable J; variable failed; variable db
    set failed 1
    foreach o $J($id,outs) {file delete -force $o}
    dict unset db [lindex $J($id,outs) 0]
    puts stderr "mitosis: FAILED: [lindex $J($id,outs) 0]"
}

proc mitosis::succeed {id} {
    variable J; variable db; variable depexts; variable hmemo
    set deps {}
    foreach o $J($id,outs) {
        set hmemo [dict remove $hmemo $o]
        if {[resolve $o] in $depexts} {set deps [parse-depfile $o $J($id,ins)]}
    }
    dict set db [lindex $J($id,outs) 0] [dict create key [job-key $id $deps] deps $deps]
    finish $id
}

proc mitosis::start {id} {
    variable J; variable running; variable nran; variable hmemo
    foreach o $J($id,outs) {
        file mkdir [file dirname $o]
        set hmemo [dict remove $hmemo $o]
    }
    say $id
    incr nran
    if {[catch {open |[list {*}$J($id,argv) 2>@1] r} ch]} {
        set J($id,out) "mitosis: cannot run: $ch\n"
        puts -nonewline stderr $J($id,out)
        fail $id
        return
    }
    fconfigure $ch -blocking 0
    incr running
    fileevent $ch readable [list ::mitosis::readable $id $ch]
}

proc mitosis::readable {id ch} {
    variable J; variable running
    append J($id,out) [read $ch]
    if {![eof $ch]} return
    fileevent $ch readable {}
    fconfigure $ch -blocking 1
    set rc [catch {close $ch}]
    incr running -1
    if {$J($id,out) ne ""} {puts -nonewline stderr $J($id,out)}
    if {$rc} {fail $id} else {succeed $id}
    pump
}

proc mitosis::check-done {} {
    variable running; variable failed; variable remaining; variable ready; variable done
    if {$running > 0} return
    if {$failed || $remaining == 0} {set done 1; return}
    if {![llength $ready]} {
        puts stderr "mitosis: dependency cycle among jobs"
        set failed 1; set done 1
    }
}

proc mitosis::pump {} {
    variable ready; variable running; variable failed; variable maxjobs; variable dry
    while {!$failed && $running < $maxjobs && [llength $ready]} {
        set ready [lassign $ready id]
        if {$dry} {
            variable J
            puts [join [lmap w $J($id,argv) {shq $w}] " "]
            finish $id
        } elseif {[job-clean $id]} {
            finish $id
        } else {
            start $id
        }
    }
    check-done
}

proc mitosis::run {} {
    variable ids; variable J; variable ready; variable remaining; variable running
    variable failed; variable done; variable nran; variable maxjobs; variable dry
    set ready {}
    foreach id $ids {if {$J($id,pending) == 0} {lappend ready $id}}
    set remaining [llength $ids]
    set running 0; set failed 0; set done 0; set nran 0
    set maxjobs [var jobs 1]
    if {![string is integer -strict $maxjobs] || $maxjobs < 1} {set maxjobs 1}
    db-load
    pump
    if {!$done} {vwait ::mitosis::done}
    if {!$dry} {
        db-save
        if {!$failed} {puts "mitosis: [llength $ids] jobs, $nran run, [expr {[llength $ids]-$nran}] up to date"}
    }
    return $failed
}

# --------------------------------------------------------------------- clean

proc mitosis::prune {d} {
    foreach s [glob -nocomplain -directory $d -types d *] {prune $s}
    if {![llength [glob -nocomplain -directory $d -types {f d l} *]]} {catch {file delete $d}}
}

proc mitosis::clean {} {
    variable J; variable ids; variable outdirs
    set planned {}
    foreach id $ids {foreach o $J($id,outs) {dict set planned $o 1}}
    foreach o [dict keys $planned] {file delete -force $o}
    foreach d $outdirs {
        if {$d eq "." || ![file isdirectory $d]} continue
        foreach f [find-files $d] {
            if {![dict exists $planned $f]} {puts "orphan: $f"; file delete -force $f}
        }
        prune $d
    }
    file delete -force .mitosis
    return 0
}

# ---------------------------------------------------------------------- main

proc mitosis::usage {{add "0"}} {
    puts -nonewline stderr "usage: mitosis \[-C dir\] \[-j N\] \[-B\] \[-n\] \[-v\] \[--eval-path\] \[VAR=value ...\] \[clean | TARGET...\]"
    if {$add} { puts "; see --help"; } else { puts ""; }
}
proc mitosis::long-usage {} {
    usage
    puts stderr {
	Build files according to a build.celmag found upward from the current directory
	(mitosis runs from the directory containing it).

	Options:
	-C DIR        Change to DIR before doing anything.
	-j N          Run up to N jobs in parallel.
	-B            Unconditionally rebuild, ignoring cached results.
	-n            Dry run: print commands without executing them.
	-v            Verbose output.
	--eval-path   Print the celmag directories found on the eval path and exit.

	Arguments:
	VAR=value     Set VAR for this run, overriding build.celmag and finalize scripts.
	VAR+=value    Append to VAR after build.celmag and finalize scripts have run.
	clean         Remove build outputs.
	TARGET...     Build only the named targets (and their dependencies).

	Without a target, the default targets are built.

	-- See the mitosis executable file for precise documentation and programmatic details.
	-- Authored by Claude and E.M.
    }
}

proc mitosis::find-root {} {
    set d [pwd]
    while 1 {
        if {[file exists [file join $d build.celmag]]} {return $d}
        set p [file dirname $d]
        if {$p eq $d} {return {}}
        set d $p
    }
}

proc mitosis::main {argv} {
    variable force; variable dry; variable evalpath
    variable assigns; variable finals
    set cmd build; set dir {}; set jopt {}; set names {}
    while {[llength $argv]} {
        set a [lindex $argv 0]; set argv [lrange $argv 1 end]
        switch -regexp -- $a {
            {^-h$}          {usage "1"; return 0}
	    {^--help$}      {long-usage; return 0}
            {^-B$}          {set force 1}
            {^-n$}          {set dry 1}
            {^-v$}          {set ::VERBOSE 1}
            {^-C$}          {set dir [lindex $argv 0]; set argv [lrange $argv 1 end]}
            {^-j$}          {set jopt [lindex $argv 0]; set argv [lrange $argv 1 end]}
            {^-j[0-9]+$}    {set jopt [string range $a 2 end]}
            {^clean$}       {set cmd clean}
            {^--eval-path$} {set cmd evalpath}
            {^[A-Za-z_][A-Za-z0-9_]*\+?=} {
                regexp {^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$} $a -> k plus v
                lappend assigns $k [expr {$plus eq "+" ? "+=" : "="}] [regexp -all -inline {\S+} $v]
            }
            {^-}            {puts stderr "mitosis: unknown option '$a'"; usage "1"; return 2}
            default         {lappend names $a}
        }
    }
    set evalpath [eval-path]      ;# before any cd: relative entries mean relative to here
    if {$cmd eq "evalpath"} {puts [join $evalpath \n]; return 0}
    if {$dir ne ""} {cd $dir}
    set root [find-root]
    if {$root eq ""} {error "mitosis: no build.celmag in [pwd] or any parent directory"}
    cd $root
    set ::PWD [pwd]
    if {![llength $evalpath]} {
        error "mitosis: no eval-path directory exists, so there are no digests to work with.\n  Install them (install.sh) or point MITOSIS_EVAL_PATH at celmag directories (colon-separated)."
    }

    # command-line VAR=value first, so set-default skips them and derived defaults follow them
    foreach {k op v} $assigns {if {$op eq "="} {set ::$k $v}}

    # layers from the eval path (set-default is first-wins), then the project's build.celmag
    foreach f [layer-files] {uplevel #0 [list source $f]}
    uplevel #0 [list source [file join $root build.celmag]]
    if {![llength $mitosis::used]} {
        error "mitosis: build.celmag must select a digest with 'use NAME' (available: [join [digest-names] {, }])"
    }
    foreach script $finals {uplevel #0 $script}
    if {![info exists ::jobs]} {set ::jobs [nproc]}

    # the command line beats everything, as with make
    foreach {k op v} $assigns {
        if {$op eq "="} {set ::$k $v} else {lappend ::$k {*}$v}
    }
    if {![dict size $mitosis::targets]} {target [file tail [pwd]].out}
    if {$jopt ne ""} {set ::jobs $jopt}

    plan
    if {$cmd eq "clean"} {select {}; return [clean]}
    select $names
    return [run]
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[catch {mitosis::main $argv} rc]} {
        puts stderr $rc
        exit 1
    }
    exit $rc
}
