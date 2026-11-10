#!/usr/bin/env tclsh
#
# mitosis.tcl -- Muscular build system.
#                by Claude, and ChatGPT.
#
#   mitosis [-C dir] [-j N] [-Bnqskpdv] [--shuffle[=MODE]] [--trace] [--eval-path]
#           [VAR=value ...] [clean | TARGET...]
#   mitosis -h | --help
#
# Model: file DAG built from suffix edges. Sources are globbed from "at" rows.
# Each file carries its derivation in its name (foo.c -> foo.c.o -> foo.c.o.d).
# A job is up to date when its recorded "parts" (argv, tool identity, input
# hashes, recorded dep hashes) equal the current ones. Not mtime.
#
# The user manual is mitosis(1), displayed by `mitosis -h` or `--help`.
#
# Timing/graph data is opt-in: set MITOSIS_GRAPH=1 in the environment or use
# `set MITOSIS_GRAPH 1` in build.mitosis.tcl. Records append to
# .mitosis/timings.csv; they never participate in cache validity.
# Exit status: 0 ok, 1 only for -q "out of date", 2 failure or error.
#
# DSL (plain Tcl):
#   at DIR EXTS           where source files of these types live (additive)
#   alias CANON NAMES     treat NAMES as CANON for edge matching
#   relate FROM TO ?CMD?  suffix edge (TO starting with "." appends suffix per file;
#                         bare TO folds all FROM files into one output);
#                         no CMD = ordering edge only
#   depfile EXT           outputs of this type are make-style .d dep files
#   phase TYPE NAME       label jobs producing TYPE for timing reports
#   use NAME              load a named digest (required; no default)
#   set-default V X       set V unless already set (env var V wins)
#   set-add V items...    append to list variable V
#   target NAME ?opts?    declare a final output
#     -only GLOBS         keep only objects from sources matching these patterns
#     -not  GLOBS         drop objects from sources matching these patterns
#     -with {V X..}       replace variables for this target's link command
#     -add  {V X..}       append to variables for this target's link command
#     -role ROLE          which fold-edge role this fills (default: target)
#   default-target NAME   same as `target NAME` with all defaults
#   finalize SCRIPT       run after build.mitosis.tcl, before planning
#
# Variables: environment values are imported by set-default when the variable is
#             unset. Later layers may override with set; command-line assignments
#             are applied last and therefore win. VAR+=value appends last.
#
# Eval path (celmag directories, first wins):
#   MITOSIS_EVAL_PATH (colon-separated) if set, else:
#     $XDG_CONFIG_HOME/mitosis          (~/.config/mitosis)
#     $XDG_DATA_HOME/mitosis/celmag     (~/.local/share/mitosis/celmag)
#     /etc/celmag
#     each $XDG_DATA_DIRS entry + /mitosis/celmag
#   Only existing directories count; `mitosis --eval-path` prints the result.
#   Top-level *.tcl files are layers, loaded in name order across the path;
#   the first path containing a name wins (an empty file disables that layer).
#   digest/NAME.tcl files are digests; the first matching digest wins.
#
# Layers are loaded in this order: eval-path layers, build.mitosis.tcl,
# finalize scripts, then command-line assignments. `set-default` is first-wins.
# build.mitosis.tcl is searched upward from cwd; mitosis runs from its directory.
# build.celmag is accepted as a legacy filename when build.mitosis.tcl is absent.
#
# Target GLOBS are Tcl `string match` patterns on originating source paths,
# e.g. source/test/*. Per-target -with/-add/-only/-not options affect only the
# final fold command; compilation flags are shared.
#
# CMD template: words split at definition time.
#   $.<ext>   the input/output file of that type (list for a fold)
#   $var      splices the named list variable as separate args
#   prefix$var embedded in a word: substituted in place

# ============================================================ namespace

namespace eval mitosis {
    # Absolute path of this script, used to find the adjacent source-tree man page.
    variable script [file normalize [info script]]

    # DSL state
    variable rows    {}   ;# dir -> list-of-exts
    variable aliases {}   ;# alias-ext -> canonical-ext
    variable edges   {}   ;# {from to} -> template  (insertion ordered)
    variable order   {}   ;# ordering-only edges: list of {from to}
    variable depexts {}   ;# canonical exts whose outputs are dep files
    variable phases  {}   ;# output type -> timing phase name
    variable used    {}   ;# digest names already loaded
    variable finals  {}   ;# finalize scripts
    variable assigns {}   ;# command-line assignments: name op words ...

    # target declarations
    variable targets {}   ;# name -> option-dict
    variable tjobs   {}   ;# target-name -> job-id

    # eval path
    variable evalpath {}

    # planning products
    variable known   {}   ;# all known exts, longest first (for suffix resolution)
    variable outdirs {}   ;# dirs that receive build outputs
    variable srcdirs {}   ;# dirs that hold source files
    variable nodes   {}   ;# path -> {rel type anc job root}
    variable bytype  {}   ;# canonical-type -> list-of-paths

    # job table: immutable metadata in a dict; mutable output text in a plain array
    # J(id,field): argv ins outs deps intypes rdeps pending
    # Jout(id): accumulated stdout+stderr text (written repeatedly from event handler)
    variable J       {}   ;# id -> {argv ins outs deps intypes rdeps pending}
    variable Jout       ;# id -> string (array, not dict, for cheap append)
    array set Jout {}
    variable njobs   0
    variable ids     {}   ;# all job ids (plan order)

    # scheduler
    variable ready     {}
    variable remaining 0
    variable running   0
    variable failed    0
    variable done      0
    variable nran      0

    # flags
    variable force    0
    variable dry      0
    variable silent   0
    variable question 0
    variable printdb  0
    variable keep     0
    variable trace    0
    variable debug    0
    variable shuffle  none   ;# none | random | reverse
    variable seed     {}
    variable maxjobs  1
    variable sim      0      ;# dry or question: nothing really runs
    variable dirty    {}     ;# sim only: job ids that would run
    variable skipped  {}     ;# -k: job ids blocked by a failed dependency
    variable nfailed  0
    variable stale    0      ;# -q: something is out of date
    variable g0       {}     ;# globals present before any config was loaded

    # persistence
    variable db    {}   ;# path -> {key hash deps list}
    variable hmemo {}   ;# path -> sha256 (hash memo)
    variable tmemo {}   ;# cmd -> identity (tool memo)

    # Timing history is kept beside the content cache, not in cache keys.
    # .mitosis/timings.csv is append-only and contains job, file, group, and run rows.
    # Whole-run elapsed time includes planning and execution.
    variable timing {}
    variable timing_serial 0
    variable timing_warned 0
    variable graph 0       ;# opt-in timing history
}

# ============================================================ DSL
# These run at global scope (sourced from build.mitosis.tcl), so they write
# directly to ::mitosis:: variables.

proc at {dir exts} {
    set cur {}
    if {[dict exists $::mitosis::rows $dir]} { set cur [dict get $::mitosis::rows $dir] }
    foreach e $exts { if {$e ni $cur} { lappend cur $e } }
    dict set ::mitosis::rows $dir $cur
}

proc alias {canon names} {
    foreach a $names { dict set ::mitosis::aliases $a $canon }
}

proc relate {from to {cmd {}}} {
    if {$cmd eq ""} {
        if {[list $from $to] ni $::mitosis::order} {
            lappend ::mitosis::order [list $from $to]
        }
    } else {
        dict set ::mitosis::edges [list $from $to] $cmd
    }
}

proc depfile {ext} {
    set c [mitosis::canon $ext]
    if {$c ni $::mitosis::depexts} { lappend ::mitosis::depexts $c }
}

# Label jobs by output type. The digest owns these labels; the core does not
# infer compiler or linker semantics from suffixes.
proc phase {type name} {
    dict set ::mitosis::phases [mitosis::canon $type] $name
}

proc use {name} {
    if {$name in $::mitosis::used} return
    set f [mitosis::find-digest $name]
    if {$f eq ""} {
        error "mitosis: no digest '$name'\n  available: [join [mitosis::digest-names] {, }]\n  searched:  [join $::mitosis::evalpath {, }]"
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
    if {![info exists ::$name]} { set ::$name {} }
    lappend ::$name {*}$args
}

proc target {name args} {
    set opts {-only {} -not {} -with {} -add {} -role target}
    foreach {k v} $args {
        if {![dict exists $opts $k]} { error "mitosis: target: unknown option '$k'" }
        dict set opts $k $v
    }
    if {[dict exists $::mitosis::targets $name]} { error "mitosis: target '$name' declared twice" }
    dict set ::mitosis::targets $name $opts
}

proc default-target {{name {}}} { if {$name ne ""} { target $name } }

proc finalize {script} { lappend ::mitosis::finals $script }

# Convenience helpers available in config files
proc have     {x}         { expr {[lindex [auto_execok $x] 0] ne ""} }
proc basename {p}         { file tail $p }
proc nproc    {}          {
    if {[catch {exec nproc} n] || ![string is integer -strict $n]} { return 1 }
    return $n
}
proc var {name {default {}}} {
    if {[info exists ::$name]} { return [set ::$name] }
    return $default
}

# ============================================================ job accessors
# J is a dict of dicts.  Accessors keep call sites clean.

proc mitosis::jget {id field} {
    variable J
    dict get [dict get $J $id] $field
}

proc mitosis::jset {id field val} {
    variable J
    dict set J $id $field $val
}

proc mitosis::jincr {id field {amt 1}} {
    variable J
    set new [expr {[dict get [dict get $J $id] $field] + $amt}]
    dict set J $id $field $new
    return $new
}

proc mitosis::jlappend {id field args} {
    variable J
    set cur [dict get [dict get $J $id] $field]
    dict set J $id $field [lappend cur {*}$args]
}

# ============================================================ eval path

proc mitosis::xdg-dir {envvar default} {
    if {[info exists ::env($envvar)] && [string index $::env($envvar) 0] eq "/"} {
        return $::env($envvar)
    }
    return $default
}

proc mitosis::eval-path {} {
    set raw {}
    if {[info exists ::env(MITOSIS_EVAL_PATH)]} {
        set raw [split $::env(MITOSIS_EVAL_PATH) :]
    } else {
        set home ""
        if {[info exists ::env(HOME)]} { set home $::env(HOME) }
        set cfg  [xdg-dir XDG_CONFIG_HOME  [expr {$home ne "" ? "$home/.config"       : ""}]]
        set data [xdg-dir XDG_DATA_HOME    [expr {$home ne "" ? "$home/.local/share"  : ""}]]
        if {$cfg  ne ""} { lappend raw [file join $cfg  mitosis] }
        if {$data ne ""} { lappend raw [file join $data mitosis celmag] }
        lappend raw /etc/celmag
        foreach d [split [xdg-dir XDG_DATA_DIRS /usr/local/share:/usr/share] :] {
            if {[string index $d 0] eq "/"} { lappend raw [file join $d mitosis celmag] }
        }
    }
    set out {}
    foreach d $raw {
        if {$d eq ""} continue
        set d [file normalize $d]
        if {[file isdirectory $d] && $d ni $out} { lappend out $d }
    }
    return $out
}

proc mitosis::find-digest {name} {
    variable evalpath
    foreach d $evalpath {
        set f [file join $d digest $name.tcl]
        if {[file isfile $f] && [file readable $f]} { return $f }
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

# Top-level *.tcl layers: shadowed by name (earlier path wins), sorted by filename.
proc mitosis::layer-files {} {
    variable evalpath
    set seen {}
    set items {}
    foreach d $evalpath {
        foreach f [glob -nocomplain -directory $d -types {f l} *.tcl] {
            set t [file tail $f]
            if {[dict exists $seen $t]} continue
            dict set seen $t 1
            lappend items [list $t $f]
        }
    }
    return [lmap i [lsort -index 0 $items] { lindex $i 1 }]
}

# ============================================================ type / suffix system

proc mitosis::cmplen {a b} { expr {[string length $b] - [string length $a]} }

proc mitosis::canon {e} {
    variable aliases
    if {[dict exists $aliases $e]} { return [dict get $aliases $e] }
    return $e
}

# All dotted extensions mentioned in the DSL, longest first (for greedy suffix match).
proc mitosis::known-list {} {
    variable rows
    variable aliases
    variable edges
    variable order
    set k {}
    dict for {d exts}    $rows    { lappend k {*}$exts }
    dict for {a c}       $aliases { lappend k $a $c }
    dict for {key tmpl}  $edges   { lassign $key f to; lappend k $f {*}$to }
    foreach o $order               { lappend k {*}$o }
    set r {}
    foreach e [lsort -unique $k] {
        if {[string index $e 0] eq "."} { lappend r $e }
    }
    return [lsort -command cmplen $r]
}

# Longest known suffix of name, through aliases.
proc mitosis::resolve {name} {
    variable known
    foreach e $known {
        set n [string length $e]
        if {[string length $name] > $n &&
            [string range $name end-[expr {$n-1}] end] eq $e} {
            return [canon $e]
        }
    }
    return {}
}

proc mitosis::dir-for {type} {
    variable rows
    set type [canon $type]
    dict for {d exts} $rows {
        foreach ext $exts {
            if {[canon $ext] eq $type} { return $d }
        }
    }
    return {}
}

proc mitosis::path-join {d rel} {
    if {$d eq "."} { return $rel }
    return [file join $d $rel]
}

proc mitosis::out-path {type rel} {
    set d [dir-for $type]
    if {$d eq ""} { error "mitosis: no 'at' row for type '$type' (file $rel)" }
    return [path-join $d $rel]
}

# Recursive file scan (Tcl's glob doesn't recurse).
proc mitosis::find-files {dir} {
    set out [lsort [glob -nocomplain -directory $dir -types f *]]
    foreach d [lsort [glob -nocomplain -directory $dir -types d *]] {
        lappend out {*}[find-files $d]
    }
    return $out
}

# Shell-safe quoting (display / dry-run only).
proc mitosis::shq {w} {
    if {[regexp {^[A-Za-z0-9_./:=+,@%-]+$} $w]} { return $w }
    return "'[string map {' '\\''} $w]'"
}

# ============================================================ template expansion

proc mitosis::lookup {v locals} {
    if {[dict exists $locals $v]} { return [dict get $locals $v] }
    if {[info exists ::$v]}       { return [set ::$v] }
    error "mitosis: undefined variable \$$v in command template"
}

# Expand a pre-split command template.
# ph:     placeholder dict (literal token -> replacement word-list)
# locals: variable overrides for this invocation
proc mitosis::expand {tmpl ph locals} {
    # String-map for in-word substitution: longest placeholder first to avoid partials.
    set smap {}
    foreach k [lsort -command cmplen [dict keys $ph]] {
        lappend smap $k [join [dict get $ph $k] " "]
    }
    set out {}
    foreach w $tmpl {
        if {[dict exists $ph $w]} {
            # Exact placeholder: splice word-list.
            lappend out {*}[dict get $ph $w]
        } elseif {[regexp {^\$([A-Za-z_][A-Za-z0-9_]*)$} $w -> v]} {
            # Bare $var: splice word-list.
            lappend out {*}[lookup $v $locals]
        } else {
            # Mixed word: apply placeholder map, then variable substitution.
            set s [string map $smap $w]
            while {[regexp {\$([A-Za-z_][A-Za-z0-9_]*)} $s all v]} {
                set s [string map [list $all [join [lookup $v $locals] " "]] $s]
            }
            lappend out $s
        }
    }
    return $out
}

# ============================================================ planning

proc mitosis::add-node {path rel type anc job root} {
    variable nodes
    variable bytype
    dict set nodes $path [dict create rel $rel type $type anc $anc job $job root $root]
    dict lappend bytype $type $path
}

proc mitosis::any-anc-of-type {paths ext} {
    variable nodes
    foreach p $paths { if {$ext in [dict get [dict get $nodes $p] anc]} { return 1 } }
    return 0
}

proc mitosis::new-job {id argv ins outs {outtypes {}}} {
    variable J
    variable nodes
    variable phases
    set deps {}
    set types {}
    foreach p $ins {
        set n [dict get $nodes $p]
        lappend types [dict get $n type]
        set pj [dict get $n job]
        if {$pj ne "" && $pj ni $deps} { lappend deps $pj }
    }
    if {![llength $outtypes]} {
        foreach p $outs {
            if {[dict exists $nodes $p]} { lappend outtypes [dict get $nodes $p type] }
        }
    }
    set outtypes [lmap type $outtypes { canon $type }]
    set groups {}
    foreach type $outtypes {
        if {[dict exists $phases $type]} {
            set name [dict get $phases $type]
            if {$name ni $groups} { lappend groups $name }
        }
    }
    if {![llength $groups]} {
        set jobphase generate
    } elseif {[llength $groups] == 1} {
        set jobphase [lindex $groups 0]
    } else {
        set jobphase mixed
    }
    dict set J $id [dict create \
        argv     $argv \
        ins      $ins \
        outs     $outs \
        outtypes [lsort -unique $outtypes] \
        deps     $deps \
        intypes  [lsort -unique $types] \
        phase    $jobphase \
        timing   {} \
        rdeps    {} \
        pending  0 \
    ]
}

# Does target opts dict include the object from source root?
proc mitosis::wants {opts root} {
    set only [dict get $opts -only]
    if {[llength $only]} {
        set ok 0
        foreach g $only { if {[string match $g $root]} { set ok 1; break } }
        if {!$ok} { return 0 }
    }
    foreach g [dict get $opts -not] { if {[string match $g $root]} { return 0 } }
    return 1
}

proc mitosis::plan {} {
    variable rows
    variable edges
    variable order
    variable known
    variable targets
    variable nodes
    variable bytype
    variable J
    variable Jout
    variable ids
    variable tjobs
    variable outdirs
    variable srcdirs
    variable njobs

    # Reset planning state.
    set nodes {}; set bytype {}; set J {}; array unset Jout; array set Jout {}
    set ids {}; set tjobs {}; set njobs 0

    set known [known-list]

    # Identify output dirs (dirs that receive built files).
    # Must be done before source scanning so we can exclude them.
    set outdirs {}
    dict for {key tmpl} $edges {
        lassign $key from to
        foreach t $to {
            set ty [expr {[string index $t 0] eq "." ? [resolve x$from$t] : $t}]
            set d  [dir-for $ty]
            if {$d eq ""} { error "mitosis: no 'at' row for output of: relate $from $to" }
            if {$d ni $outdirs} { lappend outdirs $d }
        }
    }

    # Default -I flags: every 'at' dir except ".", output dirs included, because
    # generated headers (foo.gperf -> foo.gperf.h) live in output dirs.
    # Override by setting ::incdirs in build.mitosis.tcl.
    if {![info exists ::incdirs]} {
        set ::incdirs {}
        dict for {d exts} $rows { if {$d ne "."} { lappend ::incdirs -I$d } }
    }

    # Seed queue with source files.
    set queue {}
    set srcdirs {}
    dict for {d exts} $rows {
        if {$d in $outdirs} continue
        if {![file isdirectory $d]} { error "mitosis: source directory '$d' does not exist" }
        if {$d ni $srcdirs} { lappend srcdirs $d }
        foreach f [find-files $d] {
            set rel [string range $f [expr {[string length $d]+1}] end]
            set ty  [resolve $rel]
            if {$ty ne "" && [lsearch -exact [lmap e $exts { canon $e }] $ty] >= 0} {
                add-node $f $rel $ty [list $ty] {} $f
                dbg "source $f ($ty)"
                lappend queue $f
            }
        }
    }

    # Per-file suffix edges: propagate to fixpoint over the queue.
    set i 0
    while {$i < [llength $queue]} {
        set p [lindex $queue $i]; incr i
        set n [dict get $nodes $p]
        dict for {key tmpl} $edges {
            lassign $key from to
            if {[string index [lindex $to 0] 0] ne "."} continue
            if {[canon $from] ne [dict get $n type]}    continue
            set anc [dict get $n anc]
            if {[llength $anc] > 12} { error "mitosis: suffix chain too long at $p (cycle?)" }
            set id [incr njobs]
            set ph [dict create "\$$from" [list $p]]
            set outs {}
            foreach t $to {
                set rel2 [dict get $n rel]$t
                set ty   [resolve x[canon $from]$t]
                set o    [out-path $ty $rel2]
                dict set ph "\$$t" [list $o]
                lappend outs $o
                add-node $o $rel2 $ty [concat $anc $ty] $id [dict get $n root]
                lappend queue $o
            }
            new-job $id [expand $tmpl $ph {}] [list $p] $outs
            lappend ids $id
            dbg "job $id: [join $outs] <- $p"
        }
    }

    # Fold edges: collect objects into each declared target.
    dict for {key tmpl} $edges {
        lassign $key from to
        if {[string index [lindex $to 0] 0] eq "."} continue
        set role [lindex $to 0]
        set all  {}
        if {[dict exists $bytype [canon $from]]} {
            set all [lsort [dict get $bytype [canon $from]]]
        }
        if {![llength $all]} {
            error "mitosis: nothing for '$from' (no sources under: [join $srcdirs {, }])"
        }
        set found 0
        dict for {tname opts} $targets {
            if {[dict get $opts -role] ne $role} continue
            incr found
            set src {}
            foreach p $all {
                if {[wants $opts [dict get [dict get $nodes $p] root]]} { lappend src $p }
            }
            if {![llength $src]} { error "mitosis: target '$tname' selects no inputs" }
            if {[dict exists $tjobs $tname]} {
                error "mitosis: target '$tname' is produced more than once"
            }
            set o  [path-join [dir-for $role] $tname]
            set ph [dict create "\$$from" $src "\$$role" [list $o]]
            # Default linker: c++ if any C++ ancestor, else cc.
            set locals {}
            if {![info exists ::LD]} {
                set ld [expr {[any-anc-of-type $src .cpp] ? [var CPP c++] : [var CC cc]}]
                dict set locals LD [list $ld]
            }
            dict for {k v} [dict get $opts -with] { dict set locals $k $v }
            dict for {k v} [dict get $opts -add] {
                set cur [expr {[dict exists $locals $k] ? [dict get $locals $k] : [var $k]}]
                dict set locals $k [concat $cur $v]
            }
            set id [incr njobs]
            dict set tjobs $tname $id
            new-job $id [expand $tmpl $ph $locals] $src [list $o] [list $role]
            lappend ids $id
            dbg "job $id: target $tname <- [llength $src] inputs"
        }
        if {!$found} { error "mitosis: no target of role '$role' declared" }
    }

    # Ordering edges: jobs reading type B wait for all producers of type A.
    foreach o $order {
        lassign $o a b
        set a [canon $a]; set b [canon $b]
        set prod {}
        if {[dict exists $bytype $a]} {
            foreach p [dict get $bytype $a] {
                set j [dict get [dict get $nodes $p] job]
                if {$j ne "" && $j ni $prod} { lappend prod $j }
            }
        }
        set added 0
        foreach id $ids {
            if {$b in [jget $id intypes]} {
                foreach j $prod {
                    if {$j != $id && $j ni [jget $id deps]} { jlappend $id deps $j; incr added }
                }
            }
        }
        dbg "order $a -> $b: $added dependencies added"
    }
}

# Restrict to named targets (all if empty) and wire up scheduler counts.
# The full J dict is preserved — select only filters which ids get run.
# This is essential: dep IDs must remain valid even if the dep isn't in
# the selected set (it just finishes instantly as "already done").
proc mitosis::select {names} {
    variable J
    variable ids
    variable tjobs

    if {[llength $names]} {
        # Walk transitive deps of the named targets.
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
            lappend stack {*}[jget $id deps]
        }
        # Keep plan order among selected ids.
        set sel {}
        foreach id $ids { if {[dict exists $seen $id]} { lappend sel $id } }
        set ids $sel
    }

    # Wire rdeps and pending. The selection is dependency-closed, so every
    # dep of a selected job is itself selected.
    foreach id $ids { jset $id rdeps {}; jset $id pending [llength [jget $id deps]] }
    foreach id $ids {
        foreach d [jget $id deps] { jlappend $d rdeps $id }
    }
}

# ============================================================ diagnostics

proc mitosis::dbg {msg} {
    variable debug
    variable question
    if {$debug && !$question} { puts "mitosis: debug: $msg" }
}

# ============================================================ hashing / cache

proc mitosis::hash-files {files} {
    variable hmemo
    set todo {}
    foreach f $files {
        if {![dict exists $hmemo $f]} {
            if {[file isfile $f]} { lappend todo $f } else { dict set hmemo $f MISSING }
        }
    }
    # Batch sha256sum (64 files at a time to stay under arg-list limits).
    for {set i 0} {$i < [llength $todo]} {incr i 64} {
        set chunk [lrange $todo $i [expr {$i+63}]]
        foreach line [split [exec sha256sum -- {*}$chunk] \n] {
            if {[string length $line] < 68} continue
            # "<hash>  <filename>"
            dict set hmemo [string range $line 66 end] [string range $line 0 63]
        }
    }
    set r {}
    foreach f $files { lappend r [dict get $hmemo $f] }
    return $r
}

proc mitosis::tool-id {cmd} {
    variable tmemo
    if {![dict exists $tmemo $cmd]} {
        set p [lindex [auto_execok $cmd] 0]
        if {$p ne "" && [file exists $p]} {
            dict set tmemo $cmd [list $p [file size $p] [file mtime $p]]
        } else {
            dict set tmemo $cmd [list $cmd unresolved]
        }
    }
    return [dict get $tmemo $cmd]
}

# Everything a job's result depends on, as a dict. Stored in the db after a
# successful run and compared field by field later, which is both the cache
# test and the explanation for --trace (no hashing of the key needed).
proc mitosis::job-parts {id extradeps} {
    set argv [jget $id argv]
    set ins  [jget $id ins]
    set ih {}
    foreach p $ins h [hash-files $ins] { dict set ih $p $h }
    set dh {}
    foreach p $extradeps h [hash-files $extradeps] { dict set dh $p $h }
    return [dict create argv $argv tool [tool-id [lindex $argv 0]] ins $ih deps $dh]
}

# Why must this job run? Returns "" when it is up to date.
# In sim mode (-n, -q) nothing really runs, so a job whose dependency would
# run is itself assumed to run.
proc mitosis::judge {id} {
    variable db
    variable force
    variable sim
    variable dirty
    set outs [jget $id outs]
    if {$force} { return "forced rebuild (-B)" }
    foreach o $outs { if {![file isfile $o]} { return "output missing: $o" } }
    if {$sim} {
        foreach d [jget $id deps] {
            if {[dict exists $dirty $d]} {
                return "runs after: [lindex [jget $d outs] 0]"
            }
        }
    }
    set k [lindex $outs 0]
    if {![dict exists $db $k] || ![dict exists [dict get $db $k] parts]} {
        return "no cache record"
    }
    set rec [dict get $db $k]
    set old [dict get $rec parts]
    set new [job-parts $id [dict get $rec deps]]
    if {[dict get $old argv] ne [dict get $new argv]} { return "command line changed" }
    if {[dict get $old tool] ne [dict get $new tool]} {
        return "tool changed: [lindex [dict get $new tool] 0]"
    }
    foreach {sect what} {ins input deps dependency} {
        if {![dict exists $old $sect]} { return "$what list changed" }
        set before [dict get $old $sect]
        set after [dict get $new $sect]
        dict for {p h} $before {
            if {![dict exists $after $p]} { return "$what removed: $p" }
            if {[dict get $after $p] ne $h} { return "$what changed: $p" }
        }
        dict for {p h} $after {
            if {![dict exists $before $p]} { return "$what added: $p" }
        }
    }
    return ""
}

# Make-style dep file; returns deps not already among ins.
proc mitosis::parse-depfile {file ins} {
    if {[catch {open $file r} fd]} { return {} }
    set t [read $fd]
    close $fd
    set t [string map [list "\\\r\n" " " "\\\n" " "] $t]
    set colon [string first : $t]
    if {$colon < 0} { return {} }
    set line [lindex [split [string range $t [expr {$colon+1}] end] \n] 0]
    set line [string map [list "\\ " \x01] $line]
    set deps {}
    foreach w [regexp -all -inline {\S+} $line] {
        set w [string map [list \x01 " "] $w]
        if {$w ni $ins && $w ni $deps} { lappend deps $w }
    }
    return $deps
}

proc mitosis::db-load {} {
    variable db
    set db {}
    if {![file exists .mitosis/db]} return
    if {[catch {open .mitosis/db r} fd]} return
    set d [read $fd]
    close $fd
    if {![catch {dict size $d}]} { set db $d }
}

proc mitosis::db-save {} {
    variable db
    file mkdir .mitosis
    set fd [open .mitosis/db.tmp w]
    puts $fd $db
    close $fd
    file rename -force .mitosis/db.tmp .mitosis/db
}

# ============================================================ scheduler

proc mitosis::print-job {id} {
    variable silent
    if {$silent} return
    set argv [jget $id argv]
    if {[var VERBOSE 0] ni {0 {} false no}} {
        puts [join [lmap w $argv { shq $w }] " "]
    } else {
        puts [format "%-10s %s" [file tail [lindex $argv 0]] [lindex [jget $id outs] 0]]
    }
}

# ============================================================ timing history

# CSV is intentionally dependency-free. All fields are quoted so paths and
# command outputs containing commas, quotes, or whitespace remain unambiguous.
proc mitosis::csv-field {value} {
    return "\"[string map [list \" \"\"] $value]\""
}

proc mitosis::timing-write {values} {
    variable graph
    variable timing_warned
    if {!$graph} return
    variable silent
    if {$timing_warned} return
    set path [file join .mitosis timings.csv]
    set ch ""
    if {[catch {
        file mkdir .mitosis
        set header [expr {![file exists $path] || [file size $path] == 0}]
        set ch [open $path a]
        fconfigure $ch -translation lf -encoding utf-8
        if {$header} {
            puts $ch {record,run_id,timestamp_ms,job_id,output,phase,status,elapsed_us,work_us,jobs,source_file,source_lines,source_files}
        }
        set row {}
        foreach value $values { lappend row [csv-field $value] }
        puts $ch [join $row ,]
        close $ch
        set ch ""
    } message]} {
        if {$ch ne ""} { catch {close $ch} }
        set timing_warned 1
        if {!$silent} { puts stderr "mitosis: warning: cannot write timing history: $message" }
    }
}

# Count logical text lines without loading a source file into memory. This is
# telemetry only: an unreadable file must never break an otherwise valid build.
proc mitosis::count-lines {path} {
    if {![file isfile $path] || [catch {open $path r} ch]} { return 0 }
    set count 0
    if {[catch {
        while {[gets $ch line] >= 0} { incr count }
        close $ch
    }]} {
        catch {close $ch}
        return 0
    }
    return $count
}

proc mitosis::timing-start {} {
    variable graph
    variable timing
    if {!$graph} return
    variable timing_serial
    variable timing_warned
    set timing_warned 0
    set started_us [clock clicks -microseconds]
    set started_ms [clock milliseconds]
    incr timing_serial
    set run_id "[pid]-$started_ms-$timing_serial"
    set timing [dict create \
        run_id $run_id started_ms $started_ms started_us $started_us \
        groups {} jobs 0 work_us 0 source_files 0 source_lines 0]
}

# Called immediately before spawning a real job. Input LOC is measured only
# for compile jobs; generators and linkers are not misreported as source LOC.
proc mitosis::timing-job-start {id} {
    variable graph
    if {!$graph} return
    set phase [jget $id phase]
    set source_rows {}
    set source_lines 0
    if {$phase eq "compile"} {
        foreach path [jget $id ins] {
            if {![file isfile $path]} continue
            set lines [count-lines $path]
            lappend source_rows [list $path $lines]
            incr source_lines $lines
        }
    }
    jset $id timing [dict create \
        phase $phase started_ms [clock milliseconds] \
        started_us [clock clicks -microseconds] \
        source_rows $source_rows source_files [llength $source_rows] \
        source_lines $source_lines]
}

# Record an executed job whether it succeeded, failed, or could not be spawned.
proc mitosis::timing-job-finish {id status finished_us} {
    variable graph
    variable timing
    if {!$graph} return
    set sample [jget $id timing]
    if {$sample eq ""} return

    set started_us [dict get $sample started_us]
    set started_ms [dict get $sample started_ms]
    set elapsed [expr {max(0, $finished_us - $started_us)}]
    set phase [dict get $sample phase]
    set outs [jget $id outs]
    set output [lindex $outs 0]
    set source_rows [dict get $sample source_rows]
    set source_files [dict get $sample source_files]
    set source_lines [dict get $sample source_lines]
    set run_id [dict get $timing run_id]

    # Job rows record command duration. File rows make the source path, LOC,
    # and associated compile-job duration directly graphable.
    timing-write [list job $run_id $started_ms $id $output $phase $status \
        $elapsed $elapsed 1 "" $source_lines $source_files]
    foreach item $source_rows {
        lassign $item path lines
        timing-write [list file $run_id $started_ms $id $output $phase $status \
            $elapsed "" "" $path $lines 1]
    }

    if {![dict exists $timing groups $phase]} {
        set group [dict create first_us $started_us last_us $finished_us \
            work_us 0 jobs 0 source_files 0 source_lines 0 failed 0]
    } else {
        set group [dict get $timing groups $phase]
        if {$started_us < [dict get $group first_us]} { dict set group first_us $started_us }
        if {$finished_us > [dict get $group last_us]} { dict set group last_us $finished_us }
    }
    dict incr group work_us $elapsed
    dict incr group jobs
    dict incr group source_files $source_files
    dict incr group source_lines $source_lines
    if {$status ne "success"} { dict set group failed 1 }
    dict set timing groups $phase $group
    dict incr timing jobs
    dict incr timing work_us $elapsed
    dict incr timing source_files $source_files
    dict incr timing source_lines $source_lines
}

# Emit per-phase wall spans plus summed worker time, then the whole-run wall
# time. With parallel jobs these are intentionally different measurements.
proc mitosis::timing-finish {status finished_us} {
    variable graph
    variable timing
    if {!$graph} return
    set run_id [dict get $timing run_id]
    set started_ms [dict get $timing started_ms]
    set groups [dict get $timing groups]
    dict for {phase group} $groups {
        set wall [expr {[dict get $group last_us] - [dict get $group first_us]}]
        set group_status [expr {[dict get $group failed] ? "failed" : "success"}]
        timing-write [list group $run_id $started_ms "" "" $phase $group_status \
            $wall [dict get $group work_us] [dict get $group jobs] "" \
            [dict get $group source_lines] [dict get $group source_files]]
    }
    set elapsed [expr {$finished_us - [dict get $timing started_us]}]
    timing-write [list run $run_id $started_ms "" "" all $status $elapsed \
        [dict get $timing work_us] [dict get $timing jobs] "" \
        [dict get $timing source_lines] [dict get $timing source_files]]
}

proc mitosis::finish-job {id} {
    variable remaining
    variable ready
    incr remaining -1
    foreach r [jget $id rdeps] {
        if {[jincr $r pending -1] == 0} { lappend ready $r }
    }
    # No pump here: callers pump, which avoids re-entrancy.
}

# -k: everything downstream of a failed job can never run.
proc mitosis::skip-rdeps {id} {
    variable remaining
    variable skipped
    foreach r [jget $id rdeps] {
        if {[dict exists $skipped $r]} continue
        dict set skipped $r 1
        incr remaining -1
        dbg "not run: [lindex [jget $r outs] 0] (depends on failed [lindex [jget $id outs] 0])"
        skip-rdeps $r
    }
}

proc mitosis::fail-job {id} {
    variable failed
    variable nfailed
    variable remaining
    variable db
    variable keep
    set failed 1
    incr nfailed
    incr remaining -1
    foreach o [jget $id outs] { file delete -force $o }
    dict unset db [lindex [jget $id outs] 0]
    puts stderr "mitosis: FAILED: [lindex [jget $id outs] 0]"
    if {$keep} { skip-rdeps $id }
}

proc mitosis::succeed-job {id} {
    variable db
    variable depexts
    variable hmemo
    set outs [jget $id outs]
    set ins  [jget $id ins]
    # Outputs changed on disk: forget their memoized hashes.
    foreach o $outs { set hmemo [dict remove $hmemo $o] }
    set extra {}
    foreach o $outs {
        if {[resolve $o] in $depexts} { lappend extra {*}[parse-depfile $o $ins] }
    }
    set extra [lsort -unique $extra]
    dict set db [lindex $outs 0] [dict create parts [job-parts $id $extra] deps $extra]
    dbg "recorded [lindex $outs 0] with [llength $extra] extra dependencies"
    finish-job $id
}

proc mitosis::start-job {id why} {
    variable running
    variable nran
    variable Jout
    variable hmemo
    variable trace
    set outs [jget $id outs]
    foreach o $outs {
        file mkdir [file dirname $o]
        set hmemo [dict remove $hmemo $o]
    }
    if {$trace} { puts "mitosis: [lindex $outs 0]: $why" }
    print-job $id
    incr nran
    timing-job-start $id
    if {[catch {open |[list {*}[jget $id argv] 2>@1] r} ch]} {
        timing-job-finish $id launch-failed [clock clicks -microseconds]
        puts stderr "mitosis: cannot run: $ch"
        fail-job $id
        return
    }
    set Jout($id) ""
    fconfigure $ch -blocking 0
    incr running
    fileevent $ch readable [list ::mitosis::on-readable $id $ch]
}

proc mitosis::on-readable {id ch} {
    variable running
    variable Jout
    append Jout($id) [read $ch]
    if {![eof $ch]} return
    fileevent $ch readable {}
    fconfigure $ch -blocking 1
    set rc [catch {close $ch}]
    incr running -1
    if {$Jout($id) ne ""} { puts -nonewline stderr $Jout($id) }
    timing-job-finish $id [expr {$rc ? "failed" : "success"}] [clock clicks -microseconds]
    if {$rc} { fail-job $id } else { succeed-job $id }
    pump
}

# Take the next ready job according to --shuffle.
proc mitosis::pick-ready {} {
    variable ready
    variable shuffle
    switch -- $shuffle {
        reverse { set i end }
        random  { set i [expr {int(rand() * [llength $ready])}] }
        default { set i 0 }
    }
    set id [lindex $ready $i]
    set ready [lreplace $ready $i $i]
    return $id
}

proc mitosis::check-stall {} {
    variable running
    variable failed
    variable keep
    variable remaining
    variable ready
    variable done
    if {$done || $running > 0} return
    if {($failed && !$keep) || $remaining == 0} { set done 1; return }
    if {![llength $ready]} {
        puts stderr "mitosis: dependency cycle detected"
        set failed 1
        set done 1
    }
}

proc mitosis::pump {} {
    variable silent
    variable ready
    variable running
    variable failed
    variable keep
    variable maxjobs
    variable done
    variable dry
    variable question
    variable trace
    variable dirty
    variable stale
    while {!$done && !($failed && !$keep) && $running < $maxjobs && [llength $ready]} {
        set id [pick-ready]
        set out [lindex [jget $id outs] 0]
        set why [judge $id]
        if {$why eq ""} {
            dbg "up to date: $out"
            finish-job $id
        } elseif {$question} {
            dbg "out of date: $out ($why)"
            set stale 1
            set done 1
        } elseif {$dry} {
            dict set dirty $id 1
            if {$trace} { puts "mitosis: $out: $why" }
            if {!$silent} {
                puts [join [lmap w [jget $id argv] { shq $w }] " "]
            }
            finish-job $id
        } else {
            dbg "out of date: $out ($why)"
            start-job $id $why
        }
    }
    check-stall
}

proc mitosis::run {} {
    variable ids
    variable ready
    variable remaining
    variable running
    variable failed
    variable done
    variable nran
    variable nfailed
    variable stale
    variable maxjobs
    variable dry
    variable question
    variable silent
    variable keep
    variable sim
    variable dirty
    variable skipped
    variable shuffle
    variable seed
    variable graph

    set ready {}
    set dirty {}
    set skipped {}
    foreach id $ids { if {[jget $id pending] == 0} { lappend ready $id } }
    set remaining [llength $ids]
    set running 0
    set failed 0
    set done 0
    set nran 0
    set nfailed 0
    set stale 0
    set sim [expr {$dry || $question}]
    set maxjobs [var jobs 1]
    if {![string is integer -strict $maxjobs] || $maxjobs < 1} { set maxjobs 1 }

    if {$shuffle eq "random"} {
        if {$seed eq ""} { set seed [expr {[clock milliseconds] % 1000000}] }
        expr {srand($seed)}
        if {!$silent && !$question} { puts stderr "mitosis: shuffle seed $seed" }
    }

    db-load
    pump
    if {!$done} { vwait ::mitosis::done }

    if {!$sim} {
        if {$graph} { timing-finish [expr {$failed ? "failed" : "success"}] [clock clicks -microseconds] }
        db-save
    }
    if {$question} { return $stale }
    if {$failed} {
        puts stderr "mitosis: $nfailed failed, [expr {$remaining + [dict size $skipped]}] not run"
        return 2
    }
    if {!$dry && !$silent} {
        set total [llength $ids]
        puts "mitosis: $total jobs, $nran run, [expr {$total - $nran}] up to date"
    }
    return 0
}

# ============================================================ clean

proc mitosis::prune-empty {d} {
    foreach sub [glob -nocomplain -directory $d -types d *] { prune-empty $sub }
    if {![llength [glob -nocomplain -directory $d -types {f d l} *]]} {
        catch { file delete $d }
    }
}

proc mitosis::clean {} {
    variable ids
    variable outdirs
    set planned {}
    foreach id $ids { foreach o [jget $id outs] { dict set planned $o 1 } }
    foreach o [dict keys $planned] { file delete -force $o }
    foreach d $outdirs {
        if {$d eq "." || ![file isdirectory $d]} continue
        foreach f [find-files $d] {
            if {![dict exists $planned $f]} { puts "orphan: $f"; file delete -force $f }
        }
        prune-empty $d
    }
    file delete -force .mitosis
    return 0
}

# ============================================================ -p

# Everything the build was told and what it planned, as (mostly) valid DSL.
proc mitosis::print-db {} {
    variable rows
    variable aliases
    variable edges
    variable order
    variable depexts
    variable phases
    variable used
    variable targets
    variable evalpath
    variable nodes
    variable ids
    variable g0
    puts "# mitosis data base"
    puts "# eval path: [join $evalpath {, }]"
    puts "# digests: $used"
    puts "\n# variables"
    foreach v [lsort [info globals]] {
        if {$v in $g0 || [array exists ::$v]} continue
        puts "$v = [set ::$v]"
    }
    puts "\n# rules"
    dict for {d exts} $rows { puts [list at $d $exts] }
    dict for {a c} $aliases { puts [list alias $c $a] }
    foreach e $depexts { puts [list depfile $e] }
    dict for {type name} $phases { puts [list phase $type $name] }
    dict for {key tmpl} $edges { puts [list relate {*}$key $tmpl] }
    foreach o $order { puts [list relate {*}$o] }
    dict for {n opts} $targets { puts [list target $n {*}$opts] }
    puts "\n# files"
    dict for {p n} $nodes {
        puts "# $p  type [dict get $n type]  derivation [join [dict get $n anc] { > }]"
    }
    puts "\n# jobs"
    foreach id $ids {
        puts "# job $id, after jobs: [jget $id deps]"
        puts "[join [jget $id outs] { }]: [join [jget $id ins] { }]"
        puts "\t[join [lmap w [jget $id argv] { shq $w }] { }]"
    }
    puts "\n# end of data base"
}

# ============================================================ main

proc mitosis::usage {{hint 0}} {
    puts -nonewline stderr \
        "usage: mitosis \[-C dir\] \[-j N\] \[-Bnqskpdv\] \[--shuffle\[=MODE\]\] \[--trace\] \[--eval-path\] \[VAR=value ...\] \[clean | TARGET...\]"
    if {$hint} { puts stderr "; see 'mitosis -h'" } else { puts stderr "" }
}

proc mitosis::manual {} {
    variable script

    set man [auto_execok man]
    if {$man eq ""} {
        puts stderr "mitosis: cannot display mitosis(1): 'man' was not found"
        puts stderr "install a manual-page viewer and the mitosis.1 manual"
        return 2
    }

    # In a source checkout, prefer the man page beside this script. Installed
    # copies normally find mitosis(1) through the system's manual search path.
    set local [file join [file dirname $script] mitosis.1]
    set page [expr {[file isfile $local] ? $local : "mitosis"}]

    # Preserve the caller's terminal on all three standard streams so man can
    # select MANPAGER/PAGER (normally less or more) and provide interactive paging.
    if {[catch {exec {*}$man $page <@stdin >@stdout 2>@stderr} message options]} {
        if {[dict exists $options -errorcode]} {
            set ec [dict get $options -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} { return [lindex $ec 2] }
        }
        puts stderr "mitosis: could not display mitosis(1): $message"
        return 2
    }
    return 0
}

proc mitosis::find-root {} {
    set d [pwd]
    while 1 {
        if {[file isfile [file join $d build.mitosis.tcl]] ||
            [file isfile [file join $d build.celmag]]} { return $d }
        set p [file dirname $d]
        if {$p eq $d} { return {} }
        set d $p
    }
}

# One-letter flags. Returns 1 if c was a flag.
proc mitosis::set-flag {c} {
    variable force
    variable dry
    variable silent
    variable question
    variable printdb
    variable keep
    variable trace
    variable debug
    switch -- $c {
        B { set force 1 }
        n { set dry 1 }
        s { set silent 1 }
        q { set question 1 }
        p { set printdb 1 }
        k { set keep 1 }
        d { set debug 1; set trace 1 }
        v { set ::VERBOSE 1 }
        default { return 0 }
    }
    return 1
}

proc mitosis::set-shuffle {mode} {
    variable shuffle
    variable seed
    if {[string is integer -strict $mode]} { set shuffle random; set seed $mode; return 1 }
    if {$mode in {none random reverse}} { set shuffle $mode; return 1 }
    puts stderr "mitosis: bad --shuffle mode '$mode' (none, random, reverse, or an integer seed)"
    return 0
}

proc mitosis::main {argv} {
    variable evalpath
    variable assigns
    variable finals
    variable targets
    variable used
    variable trace
    variable printdb
    variable question
    variable dry
    variable graph
    variable g0

    set g0 [info globals]
    set cmd build
    set dir {}
    set jopt {}
    set names {}
    set longflags {silent s quiet s question q print-data-base p
                   just-print n dry-run n recon n keep-going k}

    while {[llength $argv]} {
        set argv [lassign $argv a]
        if {[regexp {^--([^=]+)(=(.*))?$} $a -> opt eq val]} {
            if {[dict exists $longflags $opt]} {
                set-flag [dict get $longflags $opt]
            } elseif {$opt eq "help"} {
                return [manual]
            } elseif {$opt eq "trace"} {
                set trace 1
            } elseif {$opt eq "eval-path"} {
                set cmd evalpath
            } elseif {$opt eq "shuffle"} {
                if {![set-shuffle [expr {$eq eq "" ? "random" : $val}]]} { return 2 }
            } else {
                puts stderr "mitosis: unknown option '$a'"; usage 1; return 2
            }
        } elseif {[regexp {^-[A-Za-z]+[0-9]*$} $a]} {
            set chars [split [string range $a 1 end] ""]
            set n [llength $chars]
            for {set i 0} {$i < $n} {incr i} {
                set c [lindex $chars $i]
                if {$c eq "h"} { return [manual] }
                if {[set-flag $c]} continue
                if {$c in {C j}} {
                    # Value is the rest of the cluster, else the next word.
                    set v [join [lrange $chars [expr {$i+1}] end] ""]
                    if {$v eq ""} {
                        if {![llength $argv]} {
                            puts stderr "mitosis: option -$c needs an argument"; usage 1; return 2
                        }
                        set argv [lassign $argv v]
                    }
                    if {$c eq "C"} { set dir $v } else { set jopt $v }
                    break
                }
                puts stderr "mitosis: unknown option '-$c'"; usage 1; return 2
            }
        } elseif {[regexp {^[A-Za-z_][A-Za-z0-9_]*\+?=} $a]} {
            regexp {^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$} $a -> k plus v
            lappend assigns $k [expr {$plus eq "+" ? "+=" : "="}] [regexp -all -inline {\S+} $v]
        } elseif {[string index $a 0] eq "-"} {
            puts stderr "mitosis: unknown option '$a'"; usage 1; return 2
        } elseif {$a eq "clean"} {
            set cmd clean
        } else {
            lappend names $a
        }
    }

    # Eval path before any cd (relative entries are relative to invocation dir).
    set evalpath [eval-path]
    if {$cmd eq "evalpath"} { puts [join $evalpath \n]; return 0 }

    if {$dir ne ""} { cd $dir }

    set root [find-root]
    if {$root eq ""} { error "mitosis: no build.mitosis.tcl (or legacy build.celmag) found in [pwd] or any parent" }
    cd $root
    set ::PWD [pwd]

    if {![llength $evalpath]} {
        error "mitosis: no eval-path directory exists (no digests available).\n  Install them or point MITOSIS_EVAL_PATH at celmag directories (colon-separated)."
    }

    # Command-line = assignments take effect first so set-default skips them.
    foreach {k op v} $assigns { if {$op eq "="} { set ::$k $v } }

    # Load eval-path layers, then the project configuration.
    foreach f [layer-files] { uplevel #0 [list source $f] }
    set buildfile [file join $root build.mitosis.tcl]
    if {![file isfile $buildfile]} { set buildfile [file join $root build.celmag] }
    uplevel #0 [list source $buildfile]

    # Import the environment/default only if no layer or project set it.
    # This also lets build.mitosis.tcl use `set-default MITOSIS_GRAPH 1`.
    set-default MITOSIS_GRAPH 0

    if {![llength $used]} {
        error "mitosis: build.mitosis.tcl must call 'use NAME' (available: [join [digest-names] {, }])"
    }

    # Finalize scripts run after build.mitosis.tcl, before planning.
    foreach script $finals { uplevel #0 $script }

    if {![info exists ::jobs]} { set ::jobs [nproc] }

    # Command-line assignments beat everything (both = and +=).
    foreach {k op v} $assigns {
        if {$op eq "="} { set ::$k $v } else { lappend ::$k {*}$v }
    }

    if {![dict size $targets]} { target [file tail [pwd]].out }

    if {$jopt ne ""} { set ::jobs $jopt }

    if {![string is boolean -strict $::MITOSIS_GRAPH]} {
        error "mitosis: MITOSIS_GRAPH must be a boolean (0 or 1)"
    }
    set ::mitosis::graph [expr {$::MITOSIS_GRAPH ? 1 : 0}]

    # Start before planning so the run row includes planning and execution.
    if {$graph && !$dry && !$question && $cmd eq "build"} {
        timing-start
    }

    plan
    if {$printdb && !$question} { print-db }

    if {$cmd eq "clean"} { select {}; return [clean] }
    select $names
    return [run]
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[catch {mitosis::main $argv} rc]} {
        puts stderr $rc
        exit 2
    }
    exit $rc
}
