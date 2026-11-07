#!/usr/bin/env tclsh

# mitosis will recurs upwards until it finds a build.celmag
# or, mitosis file

# this file is psuedocode, arguements may not be conceptually evaluated the same. and things may be treated like macros...
# some syntax may be inconsistent, though I tried my best to keep an internal logic

# SYSTEM DEFAULT build.celmag:

source-or /etc/build.celmag (progn
  set src "source/**"
  set object "object"
  set cc cc
  set cflags "-std=c23 -O2"
  set {c++flags} "-std=c++20 -O2 -pthread"
  set cppflags "-D_GNU_SOURCE"
  set ldflags  "-lm"
  set [basename $PWD].out
)


# OVERRIDE FROM local build.celmag:

# this is some bullshit that I would love but it's highly dependant on the implementation of TCL we'd use
set ::natural-suffix .mitosis ; # should have the effect of all sets herein (at this scope) to append with .mitosis

# note on my notation, so this would be a special thing that'd look through the string list, trying to match:
# short hand arguments, e.g. -kB args, short hand argumented, e.g. -...j8 (=1?) / -...j 8 (1>=?) / -...j=8 (=1?), and...
# longhand, e.g. --help, longhand argumented (n?), e.g. --directory /path/to,
# longhand undefined lists (?+), --until 1 2 3 --here 3 4 5
# arguements here do expect a - as a definite constraint. A different system should be used for dashless
# or in otherwords, dashless would either expect a endless list with a prefixless options list (e.g. rar) or
# be a set of commands combined with some language logic for separating the two (presumably via
# some specification like below without shadowing of those defined functions without length specificaation.)
dash-option-handle (progn \
  [group "-h" "-?" "--help"] [echo "gott help you!"]
  [group "-B" "--always-make" "--always-build"] [set do-everything 1]
  [group "-C?" "--directory=?"] [cd $+1]
  [group "-"] [ set $+0 "/dev/stdin" ] ; # OH GOD $+0 AS INDEX IS SUCH A FUCKING AWESOME IDEA, but that's what my intention is here, of argv
  [group "--nonoptions--" "0"] [ set $+0 argument_filename] ; # I hope the intention here is obvious, and the extentions are obvious
  ## set argument_filename [find-if [not-regex? "^-"] [offset-by 1 $argv]] also might work
  # --nonoption-- is obviously special, "0" represents we want the first, and of course no ? or ?+ is utilized in the secondary argument
  # removing the "0" clause would result in there being allowed in all nonoptions here, and 0? would read the next after this irregardless of what it is.
  # ?+ would do the same, except it would stop at the next option. you can specify any index, so if you have five args you can designate them en masse or separately,
  # but "6" should provide you with $+0..6 such that they equal the first seven nonoption values
  # this provides flexibility, though the six
  # [group "--no-options--" "--no-nonoptions--" ] [ ... ]
  # I leave the meaning of these ((""matches"")) as an exercise to the reader
)

# note that passing v. evalling now is ambiguated throughout this file, some things are meant to be passed in lambdas while some aren't.
# I hope that the general idea pierces, it will be required to disambiguate lambdas from eval-inline for this to be a real and useful script.
if [empty? $argument_filename] eval [$argument_filename] \
    [if [exists $build.celmag] [eval [search-downwards "build.celmag"]]]

# premises

assert "Object and Source mixed... stopping. bypass with --no-assert" [expr object != src]

# wildcard expands ** and *, into unique, separate strings, TCL shouldn't reck files with spaces in their name
set files.c [wildcard $src/*.c]

set files.o [prefix-directory $object [suffix .o $files.c]]

# directories is the same as saying dirname, basename exists and so does filename (must be a file, obviously.)
set directories.c [directories $files.c]

# same as prepend/prefix object/, prefix-directory just makes sure that object with or without the / works the same.
set directories.o [prefix-directory $object directories.c]


# program

# deduplicate is similar to sort | uniq, however it doesn't sort, it removes secondary mentions, first come first stay
# sort-directory-tree orders the list such that the lower directories are ordered first, for example, (/ /etc /home /etc/postfix) etc.
# this also implies a typage check, meaning that nondirectories will trigger fatal.
# does-not-exist returns the input if it doesn't exist, otherwise removes the entry from the list
# map maps $1 onto each $2, i.e. lisp (mapcar a '(b))
set directories.o.work [map does-not-exist [sort-directory-tree [deduplicate $directories.o]]]

# drop false respective elements, otherwise return [$file.c with at most (length (car)) elements
# does-not-exist? does the thing lisp does with questionmarks, returning only truth values.
# does-not-exist-and-? returns does-not-exist & does-not-exist? in as two sets of strings grouped together.
# The purpose of this is to prevent timing issues by asking all the questions at the same time and minimize
# complexity of needing to then build the prior separately, which could have a timing difference.
# as a data oriented thing, the data is undefined, and only meant to be accessed by the later two functions,
# so you can have navigational offset values.
set files.o.work.pair    [does-not-exist-and-? $file.o]
set files.o.work.truth   [truth-half $files.o.work.pair]
set files.o.work         [string-half $files.o.work.pair]

# drops each false value from file, returns a list as long as the number of trues in truth
set files.c.work [drop files.o.work.truth file.c]

# -p for the sake of MAYBE the implementation is dogshit, even though iteratively it should be fine
mkdir -p $directories.o.work.mitosis

# if compiler is newer than XX then cc-format == $cc $cflags $cppflags $ldflags $... otherwise $cc $cflags $... $cppflags $ldflags
map [cc-format $1 $2] $files.o.work $files.c.work

# is $1 newer THAN $2?
# c-link-format, note tha c++ support would require an upgrading compiler (i.e. check if file.c++ is filled to any extent and then upgrade to c++-link-format)
# same idea as cc-format though, less (i.e. none) special consideration required.
if [some? [newer $1 $output] $files.o.work] [cc-link-format $output $file.o]

end-of-script ; # this is a command

# some additional ideas
# .d files need to be addressed, hence overall abstraction of nested specification (opposite of make) would need to generalize this process
# orphan clean would be nice (note that several images of what "source" may be, but generally if we assume we have a broadspectrum group of all possible needed objects, then we can safely remove all orphaned objects (i.e. after a source rename)
# clean as a whole needs to be specified
# conditionals as the result of options need to be considered. all  Make options need to be considered as potential features
# etc.
# while we cover the backbone of simple operation, we lack proper dependency logic and inductance.
# another scripting language may be better, such as a lisp as our syntax has been ordered around that almost exclusively.

dependency logic would require a level of structural redesign

while ultimately, we care about meaningful variable names, we do need to eventually register or search those such names.
currently, registry would be the simplest, being relational meta-logic that would then reduce to the above.

i.e. for file.c:

set file.c [search-definition]

# specifies the compilation connection between .c and .o files (from to dialect)
relate .c .o "cc-format $2 $1"

# sets the internal from to parent directories, thus removing source as a base consideration making correlation easier
route {.c "source"} {.o object/source}

# say -MMD -MP for .d, we'd need a way to translate the make format to our logic, thus relating headers to truth conditions
# this is extremely difficult per the need of following parsing

# due to the second part being not-a-extension, we assume it refers to a file.
relate .o output "cc-link $2 $1"

# our root directory is always celmag.build, per divine knowledge
# thus this is "default but made explicit" for example
route {output "."}

# for this definiton, simplified
${OBJECT.dir}/%.h: %.gperf
	$(call quiet_echo,GPERF	$<)
	${QUIET}${GPERF} ${GPERFLAGS} -H $(shell basename $(basename $<))_hash -N $(shell basename $(basename $<))_lookup < $< > $@

# demonic < in > out still possible in TCL, but I'm ignoring the implementation details of that
# perhaps define {<i>o} {command ...} pipe-me-in pipe-out-to-me or likewise
# do talk about this with bishman
relate .gperf .h "gperf-format $1 --output-file $2"
route {.gperf "source"} {.h "object"}
# the above code doesn't include generating a valid list of -I...
set-concatenate cppflags [map [prepend "-I"] [directory-tree $object.dir]]

# note the reason I used tcl was it solves the "bash raped my string and ruined MY sex life!",
# essentially, you don't have to add five hundred trillion ""s, which makes it objectively better.
# this is the most important difference and is the expressive point of control.

I have used make for a while now. my biggest problem is the combinatorics need metaprogramming and the language is terrible, hence the existence of automake.
CMake/Meson do not solve real problems besides abstracting a minimal number of details involved in cross-compilation, which are real considerations, but they're wrapped feces.
while the dag of make is fine, the specification format is fundamentally head raped and can't be effectively combined.
i.e. try to define a clean, minimal graph that solves the .d problem. .c.d(.c.o), it's a fucking nightmare.
Ninja "specified itself as not-for-humans" so I just don't care about it even slightly, as a tool shouldn't say something like that, it will only show me it's for metatools and thus rapes anyone trying anything else.


Anyways, make is terrible but the best we got.
the initial of this script defines a useful set of ideas for making a fancy recursive make-like build.sh, but the below here should abstract make like function.
I want to generalize my advanced makefile system https://github.com/basedproject/skel and make it into an independent nonshit system.
I do not want to involve make. Ideally this would be compilable to a set of commands or just a set of commands and a cache.

this should be generalizable (i.e. you could compile java with only a double homocide), but in a nonshit way. I want the combinatorics laid out plainly.

This should also be incredibly biased good-defaults minded, as good defaults simplify projects. skel does this already, however it fails at many of its goals due to the fragility and maintainability of make.

while skel's organization is clever (read: I wrote it so of course I'd say this) and almost-modular, it fundamentally lacks infastructure, good code, and it suffers from extreme complexity for things that should be only a few lines and a few common-bar definitions.

This is after many different consideration sessions of this exact idea.

As far as I know, besides specific small decisions, this should be the core to an excellent and minimal idea that would retain the qualities of make while being combinatoric, expressive, and extensible without half-assing it (read: what cmake/meson/every other build system does. make is the closest due to its lexgical goal, despite being upside down)
