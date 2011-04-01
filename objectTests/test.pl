#!/usr/bin/perl

# test.pl
# Run unit tests.

use strict;
use File::Basename;

chdir dirname $0;
chomp (my $DIR = `pwd`);

my $TESTLIBNAME = "libsystem_blocks.dylib";
my $TESTLIBPATH = "/usr/lib/system/$TESTLIBNAME";

my $BUILDDIR = "/tmp/test-$TESTLIBNAME-build";

# xterm colors
my $red = "\e[41;37m";
my $yellow = "\e[43;37m";
my $def = "\e[0m";

# clean, help
if (scalar(@ARGV) == 1) {
    my $arg = $ARGV[0];
    if ($arg eq "clean") {
        my $cmd = "rm -rf $BUILDDIR *~";
        print "$cmd\n";
        `$cmd`;
        exit 0;
    }
    elsif ($arg eq "-h" || $arg eq "-H" || $arg eq "-help" || $arg eq "help") {
        print(<<END);
usage: $0 [options] [testname ...]
       $0 clean
       $0 help

testname:
    `testname` runs a specific test. If no testnames are given, runs all tests.

options:
    ARCH=<arch>
    GC=0|1
    SDK=<sdk name>
    ROOT=/path/to/project.roots/
    
    CC=<compiler name>

    GUARDMALLOC=0|1

    BUILD=0|1
    RUN=0|1
    VERBOSE=0|1

examples:

    test installed library, x86_64, no gc
    $0

    test buildit-built root, i386 and x86_64, gc and no gc, clang compiler
    $0 ARCH=i386,x86_64 ROOT=/tmp/libclosure.roots GC=1,0 CC=clang

    test buildit-built root with iOS simulator
    $0 ARCH=i386 ROOT=/tmp/libclosure.roots SDK=iphonesimulator

    test buildit-built root on attached iOS device
    $0 ARCH=armv7 ROOT=/tmp/libclosure.roots SDK=iphoneos
END
        exit 0;
    }
}

#########################################################################
## Tests

# A "simple test" contains a single testname.m or testname.mm file
# and optionally a testname.expected-stderr file.
my %ALL_TESTS;
#my @TESTS = <<END =~ m/\S+/g;
#    __blockObjectAssign 
#    assigngc assigngcglobal assigngcivar assigngcstrongcast 
#    assignweakgc assignweakgcivar
#    block-static block_prop blockimport
#    byrefaccess byrefcopy byrefcopycopy byrefcopyid byrefcopyinner 
#    byrefcopyint byrefcopystack byrefgc byrefsanity byrefstruct 
#    c99 cast collecttest constassign copy-block-literal-rdar6439600 
#    copyconstructor copynull copyproperty copytest counting 
#    dispatch_async dispatch_call_Block_with_release enumerateObjectsUsingBlock 
#    flagsisa forin globalexpression goto hasdescriptor importedblockcopy 
#    josh k-and-r large-struct layout localisglobal macro member modglobal 
#    nestedBlock nestedId nestedSelf nestedimport 
#    notcopied nullblockisa objectRRGC objectassign orbars predicateBlock 
#    rdar6396238 rdar6405500 rdar6414583 
#    readweakgc readweakgcivar 
#    recover recovercpp recoverextra recovermany 
#    recursive-assign-int recursive-block recursive-test recursiveassign 
#    refcounting reference retainproperty retainrelease rettypepromotion 
#    returnfunctionptr shorthandexpression signature 
#    simpleassign simplemessage simpleproperty simplerelease 
#    sizeof small-struct sort structmember this tlctester 
#    varargs-bad-assign varargs variadic voidarg 
#    weakblock weakblockassign weakblockcopy weakblockrecover weakblockretain 
#END

#########################################################################
## Variables for use in complex build and run rules

# variable         # example value

# things you can multiplex on the command line
# ARCH=i386,x86_64,armv6,armv7
# SDK=system,macosx,iphoneos,iphonesimulator
# LANGUAGE=c,c++,objective-c,objective-c++
# CC=clang,gcc-4.2,llvm-gcc-4.2
# GC=0,1
# GUARDMALLOC=0,1

# things you can set once on the command line
# ROOT=/path/to/project.roots
# BUILD=0|1
# RUN=0|1
# VERBOSE=0|1



my $BUILD;
my $RUN;
my $VERBOSE;

my $crashcatch = <<'END';
// interpose-able code to catch crashes, print, and exit cleanly
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld-interposing.h>

static void catchcrash(int sig) 
{
    const char *msg;
    switch (sig) {
    case SIGILL:  msg = "CRASHED: SIGILL\\n";  break;
    case SIGBUS:  msg = "CRASHED: SIGBUS\\n";  break;
    case SIGSEGV: msg = "CRASHED: SIGSEGV\\n"; break;
    case SIGTRAP: msg = "CRASHED: SIGTRAP\\n"; break;
    case SIGABRT: msg = "CRASHED: SIGABRT\\n"; break;
    default: msg = "SIG\?\?\?\?\\n"; break;
    }
    write(STDERR_FILENO, msg, strlen(msg));
    _exit(0);
}

static void setupcrash(void) __attribute__((constructor));
static void setupcrash(void) 
{
    signal(SIGILL, &catchcrash);
    signal(SIGBUS, &catchcrash);
    signal(SIGSEGV, &catchcrash);
    signal(SIGTRAP, &catchcrash);
    signal(SIGABRT, &catchcrash);
}


static int hacked = 0;
ssize_t hacked_write(int fildes, const void *buf, size_t nbyte)
{
    if (!hacked) {
        setupcrash();
        hacked = 1;
    }
    return write(fildes, buf, nbyte);
}

DYLD_INTERPOSE(hacked_write, write);

END


#########################################################################
## Harness


# map language to buildable extensions for that language
my %extensions_for_language = (
    "c"     => ["c"],     
    "objective-c" => ["c", "m"], 
    "c++" => ["c", "cc", "cp", "cpp", "cxx", "c++"], 
    "objective-c++" => ["c", "m", "cc", "cp", "cpp", "cxx", "c++", "mm"],

    "any" => ["c", "m", "cc", "cp", "cpp", "cxx", "c++", "mm"],
    );

# map extension to languages
my %languages_for_extension = (
    "c" => ["c", "objective-c", "c++", "objective-c++"], 
    "m" => ["objective-c", "objective-c++"], 
    "mm" => ["objective-c++"], 
    "cc" => ["c++", "objective-c++"], 
    "cp" => ["c++", "objective-c++"], 
    "cpp" => ["c++", "objective-c++"], 
    "cxx" => ["c++", "objective-c++"], 
    "c++" => ["c++", "objective-c++"], 
    );

# Run some newline-separated commands like `make` would, stopping if any fail
# run("cmd1 \n cmd2 \n cmd3")
sub make {
    my $output = "";
    my @cmds = split("\n", $_[0]);
    die if scalar(@cmds) == 0;
    $? = 0;
    foreach my $cmd (@cmds) {
        chomp $cmd;
        next if $cmd =~ /^\s*$/;
        $cmd .= " 2>&1";
        print "$cmd\n" if $VERBOSE;
        $output .= `$cmd`;
        last if $?;
    }
    print "$output\n" if $VERBOSE;
    return $output;
}

sub chdir_verbose {
    my $dir = shift;
    chdir $dir || die;
    print "cd $dir\n" if $VERBOSE;
}


# Return test names from the command line.
# Returns all tests if no tests were named.
sub gettests {
    my @tests;

    foreach my $arg (@ARGV) {
        push @tests, $arg  if ($arg !~ /=/  &&  $arg !~ /^-/);
    }

    opendir(my $dir, $DIR) || die;
    while (my $file = readdir($dir)) {
        my ($name, $ext) = ($file =~ /^([^.]+)\.([^.]+)$/);
        next if ! $languages_for_extension{$ext};

        open(my $in, "< $file") || die "$file";
        my $contents = join "", <$in>;
        die if defined $ALL_TESTS{$name};
        $ALL_TESTS{$name} = $ext  if ($contents =~ m#^[/*\s]*TEST_#m);
        close($in);
    }
    closedir($dir);

    if (scalar(@tests) == 0) {
        @tests = keys %ALL_TESTS;
    }

    @tests = sort @tests;

    return @tests;
}


# Turn a C compiler name into a C++ compiler name.
sub cplusplus {
    my ($c) = @_;
    if ($c =~ /cc/) {
        $c =~ s/cc/\+\+/;
        return $c;
    }
    return $c . "++";                         # e.g. clang => clang++
}

# Returns an array of all sdks from `xcodebuild -showsdks`
sub getsdks {
    return ("system", `xcodebuild -showsdks` =~ /-sdk (.+)$/mg);
}

# Returns whether the given sdk supports GC
sub supportsgc {
    my ($sdk) = @_;
    return 1 if $sdk eq "system";
    return 1 if $sdk =~ /^macosx/;
    return 0 if $sdk =~ /^iphone/;
    die;
}

# print text with a colored prefix on each line
sub colorprint {
    my $color = shift;
    while (my @lines = split("\n", shift)) {
        for my $line (@lines) {
            chomp $line;
            print "$color $def$line\n";
        }
    }
}

sub rewind {
    seek($_[0], 0, 0);
}

# parse name=value,value pairs
sub readconditions {
    my ($conditionstring) = @_;

    my %results;
    my @conditions = ($conditionstring =~ /\w+=(?:[^\s,]+,?)+/g);
    for my $condition (@conditions) {
        my ($name, $values) = ($condition =~ /(\w+)=(.+)/);
        $results{$name} = [split ',', $values];
    }

    return %results;
}

# Get the name of the system SDK from sw_vers
sub systemsdkname {
    my @lines = `/usr/bin/sw_vers`;
    my $name;
    my $vers;
    for my $line (@lines) {
        ($name) = ($line =~ /^ProductName:\s+(.*)/)  if !$name;
        ($vers) = ($line =~ /^ProductVersion:\s+(.*)/)  if !$vers;
    }
    
    $name =~ s/ //g;
    $name = lc($name);
    my $internal = "";
    if (-d "/usr/local/include/objc") {
        if ($name eq "macosx") {
            $internal = "internal";
        } else {
            $internal = ".internal";
        }
    }
    return $name . $vers . $internal;
}

sub check_output {
    my %C = %{shift()};
    my $name = shift;
    my @output = @_;

    my %T = %{$C{"TEST_$name"}};
    my @original_output = @output;

    # Run result-checking passes, reducing @output each time
    my $xit = 1;
    my $bad = "";
    my $warn = "";
    my $runerror = $T{TEST_RUN_OUTPUT};
    filter_verbose(\@output);
    $bad |= filter_guardmalloc(\@output) if ($C{GUARDMALLOC});
    $bad |= filter_valgrind(\@output) if ($C{VALGRIND});
    $bad = filter_expected(\@output, \%C, $name) if ($bad eq "");
    $bad = filter_bad(\@output)  if ($bad eq "");
    $warn = filter_warn(\@output);

    # OK line should be the only one left
    $bad = "(output not 'OK: $name')" if ($bad eq ""  &&  (scalar(@output) != 1  ||  $output[0] !~ /^OK: $name/));
    
    if ($bad ne "") {
        my $red = "\e[41;37m";
        my $def = "\e[0m";
        print "${red}FAIL: /// test '$name' \\\\\\$def\n";
        colorprint($red, @original_output);
        print "${red}FAIL: \\\\\\ test '$name' ///$def\n";
        print "${red}FAIL: $name: $bad$def\n";
        $xit = 0;
    } 
    elsif ($warn ne "") {
        my $yellow = "\e[43;37m";
        my $def = "\e[0m";
        print "${yellow}PASS: /// test '$name' \\\\\\$def\n";
        colorprint($yellow, @original_output);
        print "${yellow}PASS: \\\\\\ test '$name' ///$def\n";
        print "PASS: $name (with warnings)\n";
    }
    else {
        print "PASS: $name\n";
    }
    return $xit;
}

sub filter_expected
{
    my $outputref = shift;
    my %C = %{shift()};
    my $name = shift;

    my %T = %{$C{"TEST_$name"}};
    my $check = $T{TEST_RUN_OUTPUT}  ||  return "";

    my $bad = "";

    my $output = join("\n", @$outputref) . "\n";
    if ($output !~ /$check/s) {
	$bad = "(run output does not match TEST_RUN_OUTPUT)";
	@$outputref = ("FAIL: $name");
    } else {
	@$outputref = ("OK: $name");  # pacify later filter
    }

    return $bad;
}

sub filter_bad
{
    my $outputref = shift;
    my $bad = "";

    my @new_output;
    for my $line (@$outputref) {
	if ($line =~ /^BAD: (.*)/) {
	    $bad = "(failed)";
	} else {
	    push @new_output, $line;
	}
    }

    @$outputref = @new_output;
    return $bad;
}

sub filter_warn
{
    my $outputref = shift;
    my $warn = "";

    my @new_output;
    for my $line (@$outputref) {
	if ($line !~ /^WARN: (.*)/) {
	    push @new_output, $line;
        } else {
	    $warn = "(warned)";
	}
    }

    @$outputref = @new_output;
    return $warn;
}

sub filter_verbose
{
    my $outputref = shift;

    my @new_output;
    for my $line (@$outputref) {
	if ($line !~ /^VERBOSE: (.*)/) {
	    push @new_output, $line;
	}
    }

    @$outputref = @new_output;
}

sub filter_valgrind
{
    my $outputref = shift;
    my $errors = 0;
    my $leaks = 0;

    my @new_output;
    for my $line (@$outputref) {
	if ($line =~ /^Approx: do_origins_Dirty\([RW]\): missed \d bytes$/) {
	    # --track-origins warning (harmless)
	    next;
	}
	if ($line =~ /^UNKNOWN __disable_threadsignal is unsupported. This warning will not be repeated.$/) {
	    # signals unsupported (harmless)
	    next;
	}
	if ($line =~ /^UNKNOWN __pthread_sigmask is unsupported. This warning will not be repeated.$/) {
	    # signals unsupported (harmless)
	    next;
	}
	if ($line !~ /^^\.*==\d+==/) {
	    # not valgrind output
	    push @new_output, $line;
	    next;
	}

	my ($errcount) = ($line =~ /==\d+== ERROR SUMMARY: (\d+) errors/);
	if (defined $errcount  &&  $errcount > 0) {
	    $errors = 1;
	}

	(my $leakcount) = ($line =~ /==\d+==\s+(?:definitely|possibly) lost:\s+([0-9,]+)/);
	if (defined $leakcount  &&  $leakcount > 0) {
	    $leaks = 1;
	}
    }

    @$outputref = @new_output;

    my $bad = "";
    $bad .= "(valgrind errors)" if ($errors);
    $bad .= "(valgrind leaks)" if ($leaks);
    return $bad;
}

sub filter_guardmalloc
{
    my $outputref = shift;
    my $errors = 0;

    my @new_output;
    for my $line (@$outputref) {
	if ($line =~ /^GuardMalloc: /) {
	    # guardmalloc prologue
	    next;
	}
	if ($line !~ /^GuardMalloc\[[^\]]+\]: /) {
	    # not guardmalloc output
	    push @new_output, $line;
	    next;
	}

	$errors = 1;
    }

    @$outputref = @new_output;

    my $bad = "";
    $bad .= "(guardmalloc errors)" if ($errors);
    return $bad;
}

sub gather_simple {
    my $CREF = shift;
    my %C = %{$CREF};
    my $name = shift;
    chdir_verbose $DIR;

    my $ext = $ALL_TESTS{$name};
    my $file = "$name.$ext";
    return 0 if !$file;

    # search file for 'TEST_CONFIG' or '#include "test.h"'
    # also collect other values:
    # TEST_CONFIG test conditions
    # TEST_ENV environment prefix
    # TEST_CFLAGS compile flags
    # TEST_BUILD build instructions
    # TEST_BUILD_OUTPUT expected build stdout/stderr
    # TEST_RUN_OUTPUT expected run stdout/stderr
    open(my $in, "< $file") || die;
    my $contents = join "", <$in>;
    
    my $test_h = ($contents =~ /^\s*#\s*(include|import)\s*"test\.h"/m);
    my $disabled = ($contents =~ /\bTEST_DISABLED\b/m);
    my $crashes = ($contents =~ /\bTEST_CRASHES\b/m);
    my ($conditionstring) = ($contents =~ /\bTEST_CONFIG\b(.*)$/m);
    my ($envstring) = ($contents =~ /\bTEST_ENV\b(.*)$/m);
    my ($cflags) = ($contents =~ /\bTEST_CFLAGS\b(.*)$/m);
    my ($buildcmd) = ($contents =~ /TEST_BUILD\n(.*?\n)END[ *\/]*\n/s);
    my ($builderror) = ($contents =~ /TEST_BUILD_OUTPUT\n(.*?\n)END[ *\/]*\n/s);
    my ($runerror) = ($contents =~ /TEST_RUN_OUTPUT\n(.*?\n)END[ *\/]*\n/s);

    return 0 if !$test_h && !$disabled && !$crashes && !defined($conditionstring) && !defined($envstring) && !defined($cflags) && !defined($buildcmd) && !defined($builderror) && !defined($runerror);

    if ($disabled) {
        print "${yellow}SKIP: $name (disabled by TEST_DISABLED)$def\n";
        return 0;
    }

    # check test conditions

    my $run = 1;
    my %conditions = readconditions($conditionstring);
    if (! $conditions{LANGUAGE}) {
        # implicit language restriction from file extension
        $conditions{LANGUAGE} = $languages_for_extension{$ext};
    }
    for my $condkey (keys %conditions) {
        my @condvalues = @{$conditions{$condkey}};

        # special case: RUN=0 does not affect build
        if ($condkey eq "RUN"  &&  @condvalues == 1  &&  $condvalues[0] == 0) {
            $run = 0;
            next;
        }

        my $testvalue = $C{$condkey};
        next if !defined($testvalue);
        # testvalue is the configuration being run now
        # condvalues are the allowed values for this test

        # special case: look up the name of SDK "system" 
        if ($condkey eq "SDK"  &&  $testvalue eq "system") {
            $testvalue = systemsdkname();
        }
        
        my $ok = 0;
        for my $condvalue (@condvalues) {

            # special case: objc and objc++
            if ($condkey eq "LANGUAGE") {
                $condvalue = "objective-c" if $condvalue eq "objc";
                $condvalue = "objective-c++" if $condvalue eq "objc++";
            }

            $ok = 1  if ($testvalue eq $condvalue);

            # special case: SDK allows prefixes, and "system" is "macosx"
            if ($condkey eq "SDK") {
                $ok = 1  if ($testvalue =~ /^$condvalue/);
                $ok = 1  if ($testvalue eq "system"  &&  "macosx" =~ /^$condvalue/);
            }

            # special case: CC and CXX allow substring matches
            if ($condkey eq "CC"  ||  $condkey eq "CXX") {
                $ok = 1  if ($testvalue =~ /$condvalue/);
            }

            last if $ok;
        }

        if (!$ok) {
            my $plural = (@condvalues > 1) ? "one of: " : "";
            print "SKIP: $name ($condkey=$testvalue, but test requires $plural", join(' ', @condvalues), ")\n";
            return 0;
        }
    }

    # builderror is multiple REs separated by OR
    if (defined $builderror) {
        $builderror =~ s/\nOR\n/\n|/sg;
        $builderror = "^(" . $builderror . ")\$";
    }
    # runerror is multiple REs separated by OR
    if (defined $runerror) {
        $runerror =~ s/\nOR\n/\n|/sg;
        $runerror = "^(" . $runerror . ")\$";
    }

    # save some results for build and run phases
    $$CREF{"TEST_$name"} = {
        TEST_BUILD => $buildcmd, 
        TEST_BUILD_OUTPUT => $builderror, 
        TEST_CRASHES => $crashes, 
        TEST_RUN_OUTPUT => $runerror, 
        TEST_CFLAGS => $cflags,
        TEST_ENV => $envstring,
        TEST_RUN => $run, 
    };

    return 1;
}

# Builds a simple test
sub build_simple {
    my %C = %{shift()};
    my $name = shift;
    my %T = %{$C{"TEST_$name"}};
    chdir_verbose "$C{DIR}/$name.build";

    my $ext = $ALL_TESTS{$name};
    my $file = "$DIR/$name.$ext";

    if ($T{TEST_CRASHES}) {
        `echo '$crashcatch' > crashcatch.c`;
        make("$C{COMPILE_C} -dynamiclib -o libcrashcatch.dylib -x c crashcatch.c");
        die "$?" if $?;
    }

    my $cmd = $T{TEST_BUILD} ? eval "return \"$T{TEST_BUILD}\"" : "$C{COMPILE}   $T{TEST_CFLAGS} $file -o $name.out";

    my $output = make($cmd);

    my $ok;
    if (my $builderror = $T{TEST_BUILD_OUTPUT}) {
        # check for expected output and ignore $?
        if ($output =~ /$builderror/s) {
            $ok = 1;
        } else {
            print "${red}FAIL: /// test '$name' \\\\\\$def\n";
            colorprint $red, $output;
            print "${red}FAIL: \\\\\\ test '$name' ///$def\n";                
            print "${red}FAIL: $name (build output does not match TEST_BUILD_OUTPUT)$def\n";
            $ok = 0;
        }
    } elsif ($?) {
        print "${red}FAIL: /// test '$name' \\\\\\$def\n";
        colorprint $red, $output;
        print "${red}FAIL: \\\\\\ test '$name' ///$def\n";                
        print "${red}FAIL: $name (build failed)$def\n";
        $ok = 0;
    } elsif ($output ne "") {
        print "${red}FAIL: /// test '$name' \\\\\\$def\n";
        colorprint $red, $output;
        print "${red}FAIL: \\\\\\ test '$name' ///$def\n";                
        print "${red}FAIL: $name (unexpected build output)$def\n";
        $ok = 0;
    } else {
        $ok = 1;
    }

    
    if ($ok) {
        foreach my $file (glob("*.out *.dylib *.bundle")) {
            make("dsymutil $file");
        }
    }

    return $ok;
}

# Run a simple test (testname.out, with error checking of stdout and stderr)
sub run_simple {
    my %C = %{shift()};
    my $name = shift;
    my %T = %{$C{"TEST_$name"}};

    if (! $T{TEST_RUN}) {
        print "PASS: $name (build only)\n";
        return 1;
    }
    else {
        chdir_verbose "$C{DIR}/$name.build";
    }

    my $env = "$C{ENV} $T{TEST_ENV}";
    if ($T{TEST_CRASHES}) {
        $env .= " DYLD_INSERT_LIBRARIES=libcrashcatch.dylib";
    }

    my $output;

    if ($C{ARCH} =~ /^arm/ && `unamep -p` !~ /^arm/) {
        # run on iOS device

        my $remotedir = "/var/root/test/" . basename($C{DIR}) . "/$name.build";
        my $remotedyld = " DYLD_LIBRARY_PATH=$remotedir";
        $remotedyld .= ":/var/root/test/"  if ($C{TESTLIB} ne $TESTLIBPATH);

        # elide host-specific paths
        $env =~ s/DYLD_LIBRARY_PATH=\S+//;
        $env =~ s/DYLD_ROOT_PATH=\S+//;

        my $cmd = "ssh iphone 'cd $remotedir && $remotedyld $env ./$name.out'";
        $output = make("$cmd");
    }
    else {
        # run locally

        my $cmd = "$env ./$name.out";
        $output = make("sh -c '$cmd 2>&1' 2>&1");
        # need extra sh level to capture "sh: Illegal instruction" after crash
        # fixme fail if $? except tests that expect to crash
    }

    return check_output(\%C, $name, split("\n", $output));
}


sub make_one_config {
    my $configref = shift;
    my $root = shift;
    my %C = %{$configref};

    $C{LANGUAGE} = "objective-c"  if $C{LANGUAGE} eq "objc";
    $C{LANGUAGE} = "objective-c++"  if $C{LANGUAGE} eq "objc++";
    
    # Look up SDK
    # Try exact match first.
    # Then try lexically-last prefix match (so "macosx" => "macosx10.7internal").
    my @sdks = getsdks();
    if ($VERBOSE) {
        print "Installed SDKs: @sdks\n";
    }
    my $exactsdk = undef;
    my $prefixsdk = undef;
    foreach my $sdk (@sdks) {
        my $SDK = $C{SDK};
        $exactsdk = $sdk  if ($sdk eq $SDK);
        # check for digits to prevent e.g. "iphone" => "iphonesimulator4.2"
        $prefixsdk = $sdk  if ($sdk =~ /^$SDK[0-9]/  &&  $sdk gt $prefixsdk);
    }
    if ($exactsdk) {
        $C{SDK} = $exactsdk;
    } elsif ($prefixsdk) {
        $C{SDK} = $prefixsdk;
    } else {
        die "unknown SDK '$C{SDK}'\nInstalled SDKs: @sdks\n";
    }

    # set the config name now, after massaging the language and sdk, 
    # but before adding other settings
    my $configname = config_name(%C);
    die if ($configname =~ /'/);
    die if ($configname =~ /\//);
    die if ($configname =~ / /);
    $C{DIR} = "$BUILDDIR/$configname";
    ($C{NAME} = $configname) =~ s/~/ /g;

    $C{SDK_PATH} = "/";
    if ($C{SDK} ne "system") {
        ($C{SDK_PATH}) = (`xcodebuild -version -sdk $C{SDK} Path` =~ /^\s*(.+?)\s*$/);
    }

    # Look up test library (possible in root or SDK_PATH)
    
    if (-e (glob "$root/*~dst")[0]) {
        $root = (glob "$root/*~dst")[0];
    }
    
    if (-e "$root/$C{SDK_PATH}$TESTLIBPATH") {
        $C{TESTLIB} = "$root/$C{SDK_PATH}$TESTLIBPATH";
    } elsif (-e "$root$TESTLIBPATH") {
        $C{TESTLIB} = "$root$TESTLIBPATH";
    } elsif (-e "$root/$TESTLIBNAME") {
        $C{TESTLIB} = "$root/$TESTLIBNAME";
    } elsif ($C{ARCH} =~ /^arm/  &&  $root eq "/") {
        # dylib in shared cache only
        $C{TESTLIB} = $TESTLIBPATH;
    } else {
        die "No $TESTLIBNAME in root '$root' and sdk '$C{SDK_PATH}'\n";
    }

    # Look up compilers
    $C{CXX} = cplusplus($C{CC});
    if ($BUILD) {
        my $oldcc = $C{CC};
        my $oldcxx = $C{CXX};

        if (-e $C{CC}) {
            # use it
        } elsif (-e "$C{SDK_PATH}/$C{CC}") {
            $C{CC} = "$C{SDK_PATH}/$C{CC}";
        } elsif ($C{SDK} eq "system"  &&  -e "/usr/bin/$C{CC}") {
            $C{CC} = "/usr/bin/$C{CC}";
        } elsif ($C{SDK} eq "system") {
            $C{CC}  = `xcrun -find $C{CC} 2>/dev/null`;
            chomp $C{CC};
        } else {
            $C{CC}  = `xcrun -sdk $C{SDK} -find $C{CC} 2>/dev/null`;
            chomp $C{CC};
        }

        if (-e $C{CXX}) {
            # use it
        } elsif (-e "$C{SDK_PATH}/$C{CXX}") {
            $C{CXX} = "$C{SDK_PATH}/$C{CXX}";
        } elsif ($C{SDK} eq "system"  &&  -e "/usr/bin/$C{CXX}") {
            $C{CXX} = "/usr/bin/$C{CXX}";
        } elsif ($C{SDK} eq "system") {
            $C{CXX}  = `xcrun -find $C{CXX} 2>/dev/null`;
            chomp $C{CXX};
        } else {
            $C{CXX}  = `xcrun -sdk $C{SDK} -find $C{CXX} 2>/dev/null`;
            chomp $C{CXX};
        }

        die "No compiler '$oldcc' in SDK '$C{SDK}'\n" if ! -e $C{CC};
        die "No compiler '$oldcxx' '$C{CXX}' in SDK '$C{SDK}'\n" if ! -e $C{CXX};
    }
    
    
    # Populate cflags

    # save-temps so dsymutil works so debug info works
    my $cflags = "-I$DIR -W -Wall -Wshorten-64-to-32 -g -save-temps -Os -arch $C{ARCH} ";
    my $objcflags = "";
    
    if ($C{SDK} ne "system") {
        $cflags .= " -isysroot '$C{SDK_PATH}'";
        $cflags .= " '-Wl,-syslibroot,$C{SDK_PATH}'";
    }
    
    if ($C{SDK} =~ /^iphoneos[0-9]/  &&  $cflags !~ /-miphoneos-version-min/) {
        my ($vers) = ($C{SDK} =~ /^iphoneos([0-9]+\.[0-9+])/);
        $cflags .= " -miphoneos-version-min=$vers";
    }
    if ($C{SDK} =~ /^iphonesimulator[0-9]/  &&  $cflags !~ /-D__IPHONE_OS_VERSION_MIN_REQUIRED/) {
        my ($vers) = ($C{SDK} =~ /^iphonesimulator([0-9]+\.[0-9+])/);
        $vers = int($vers * 10000);  # 4.2 => 42000
        $cflags .= " -D__IPHONE_OS_VERSION_MIN_REQUIRED=$vers";
    }
    if ($C{SDK} =~ /^iphonesimulator/) {
        $objcflags .= " -fobjc-abi-version=2 -fobjc-legacy-dispatch";
    }
    
    if ($root ne "/") {
        my $library_path = dirname($C{TESTLIB});
        $cflags .= " -L$library_path";
        $cflags .= " -isystem '$root/usr/include'";
        $cflags .= " -isystem '$root/usr/local/include'";
        
        if ($C{SDK_PATH} ne "/") {
            $cflags .= " -isystem '$root/$C{SDK_PATH}/usr/include'";
            $cflags .= " -isystem '$root/$C{SDK_PATH}/usr/local/include'";
        }
    }

    if ($C{CC} =~ /clang/) {
        $cflags .= " -Qunused-arguments -fno-caret-diagnostics";
    }
    
    # Populate objcflags
    
    $objcflags .= " -lobjc";
    if ($C{GC}) {
        $objcflags .= " -fobjc-gc";
    }
    if (supportsgc($C{SDK})) {
        $objcflags .= " -lauto";
    }    
    
    # Populate ENV_PREFIX
    $C{ENV} = "LANG=C";
    $C{ENV} .= " VERBOSE=1"  if $VERBOSE;
    if ($root ne "/") {
        my $library_path = dirname($C{TESTLIB});
        die "no spaces allowed in root" if $library_path =~ /\s+/;
        $C{ENV} .= " DYLD_LIBRARY_PATH=$library_path"  if ($library_path ne "/usr/lib");
    }
    if ($C{SDK_PATH} ne "/") {
        die "no spaces allowed in sdk" if $C{SDK_PATH} =~ /\s+/;
        $C{ENV} .= " DYLD_ROOT_PATH=$C{SDK_PATH}";
    }
    if ($C{GUARDMALLOC}) {
        $ENV{GUARDMALLOC} = "1";  # checked by tests and errcheck.pl
        $C{ENV} .= " DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib";
    }
    if ($C{SDK} =~ /^iphonesimulator[0-9]/) {
        my ($vers) = ($C{SDK} =~ /^iphonesimulator([0-9]+\.[0-9+])/);
        $C{ENV} .= 
            " CFFIXED_USER_HOME=$ENV{HOME}/Library/Application\\ Support/iPhone\\ Simulator/$vers" . 
            " IPHONE_SIMULATOR_ROOT=$C{SDK_PATH}" .
            " IPHONE_SHARED_RESOURCES_DIRECTORY=$ENV{HOME}/Library/Application\\ Support/iPhone\\ Simulator/$vers";        
    }

    # Populate compiler commands
    $C{COMPILE_C}   = "LANG=C '$C{CC}'  $cflags -x c -std=gnu99";
    $C{COMPILE_CXX} = "LANG=C '$C{CXX}' $cflags -x c++";
    $C{COMPILE_M}   = "LANG=C '$C{CC}'  $cflags $objcflags -x objective-c -std=gnu99";
    $C{COMPILE_MM}  = "LANG=C '$C{CXX}' $cflags $objcflags -x objective-c++";
    
    $C{COMPILE} = $C{COMPILE_C}    if $C{LANGUAGE} eq "c";
    $C{COMPILE} = $C{COMPILE_CXX}  if $C{LANGUAGE} eq "c++";
    $C{COMPILE} = $C{COMPILE_M}    if $C{LANGUAGE} eq "objective-c";
    $C{COMPILE} = $C{COMPILE_MM}   if $C{LANGUAGE} eq "objective-c++";
    die "unknown language '$C{LANGUAGE}'\n" if !defined $C{COMPILE};

    ($C{COMPILE_NOGC} = $C{COMPILE}) =~ s/-fobjc-gc\S*//;

    %$configref = %C;
}    

sub make_configs {
    my ($root, %args) = @_;

    my @results = ({});  # start with one empty config

    for my $key (keys %args) {
        my @newresults;
        my @values = @{$args{$key}};
        for my $configref (@results) {
            my %config = %{$configref};
            for my $value (@values) {
                my %newconfig = %config;
                $newconfig{$key} = $value;
                push @newresults, \%newconfig;
            }
        }
        @results = @newresults;
    }

    for my $configref(@results) {
        make_one_config($configref, $root);
    }

    return @results;
}

sub config_name {
    my %config = @_;
    my $name = "";
    for my $key (sort keys %config) {
        $name .= '~'  if $name ne "";
        $name .= "$key=$config{$key}";
    }
    return $name;
}

sub run_one_config {
    my %C = %{shift()};
    my @tests = @_;

    # Build and run
    my $testcount = 0;
    my $failcount = 0;

    my @gathertests;
    foreach my $test (@tests) {
        if ($VERBOSE) {
            print "\nGATHER $test\n";
        }

        if ($ALL_TESTS{$test}) {
            gather_simple(\%C, $test) || next;  # not pass, not fail
            push @gathertests, $test;
        } else {
            die "No test named '$test'\n";
        }
    }

    my @builttests;
    if (!$BUILD) {
        @builttests = @gathertests;
        $testcount = scalar(@gathertests);
    } else {
        my $configdir = $C{DIR};
        print $configdir, "\n"  if $VERBOSE;
        mkdir $configdir  || die;

        foreach my $test (@gathertests) {
            if ($VERBOSE) {
                print "\nBUILD $test\n";
            }
            mkdir "$configdir/$test.build"  || die;
            
            if ($ALL_TESTS{$test}) {
                $testcount++;
                if (!build_simple(\%C, $test)) {
                    $failcount++;
                } else {
                    push @builttests, $test;
                }
            } else {
                die "No test named '$test'\n";
            }
        }
    }
    
    if (!$RUN  ||  !scalar(@builttests)) {
        # nothing to do
    }
    else {
        if ($C{ARCH} =~ /^arm/ && `unamep -p` !~ /^arm/) {
            # upload all tests to iOS device
            make("RSYNC_PASSWORD=alpine rsync -av $C{DIR} rsync://root\@localhost:10873/root/var/root/test/");
            die "Couldn't rsync tests to device\n" if ($?);

            # upload library to iOS device
            if ($C{TESTLIB} ne $TESTLIBPATH) {
                # hack - send thin library because device may use lib=armv7 
                # even though app=armv6, and we want to set the lib's arch
                make("lipo -output /tmp/$TESTLIBNAME -thin $C{ARCH} $C{TESTLIB}  ||  cp $C{TESTLIB} /tmp/$TESTLIBNAME");
                die "Couldn't thin $C{TESTLIB} to $C{ARCH}\n" if ($?);
                make("RSYNC_PASSWORD=alpine rsync -av /tmp/$TESTLIBNAME rsync://root\@localhost:10873/root/var/root/test/");
                die "Couldn't rsync $C{TESTLIB} to device\n" if ($?);
            }
        }

        foreach my $test (@builttests) {
            print "\nRUN $test\n"  if ($VERBOSE);
            
            if ($ALL_TESTS{$test})
            {
                if (!run_simple(\%C, $test)) {
                    $failcount++;
                }
            } else {
                die "No test named '$test'\n";
            }
        }
    }
    
    return ($testcount, $failcount);
}



# Return value if set by "$argname=value" on the command line
# Return $default if not set.
sub getargs {
    my ($argname, $default) = @_;

    foreach my $arg (@ARGV) {
        my ($value) = ($arg =~ /^$argname=(.+)$/);
        return [split ',', $value] if defined $value;
    }

    return [$default];
}

# Return 1 or 0 if set by "$argname=1" or "$argname=0" on the 
# command line. Return $default if not set.
sub getbools {
    my ($argname, $default) = @_;

    my @values = @{getargs($argname, $default)};
    return [( map { ($_ eq "0") ? 0 : 1 } @values )];
}

sub getarg {
    my ($argname, $default) = @_;
    my @values = @{getargs($argname, $default)};
    die "Only one value allowed for $argname\n"  if @values > 1;
    return $values[0];
}

sub getbool {
    my ($argname, $default) = @_;
    my @values = @{getbools($argname, $default)};
    die "Only one value allowed for $argname\n"  if @values > 1;
    return $values[0];
}


# main
my %args;


my $default_arch = (`/usr/sbin/sysctl hw.optional.x86_64` eq "hw.optional.x86_64: 1\n") ? "x86_64" : "i386";
$args{ARCH} = getargs("ARCH", 0);
$args{ARCH} = getargs("ARCHS", $default_arch)  if !@{$args{ARCH}}[0];

$args{SDK} = getargs("SDK", "system");

$args{GC} = getbools("GC", 0);
$args{LANGUAGE} = [ map { lc($_) } @{getargs("LANGUAGE", "objective-c")} ];

$args{CC} = getargs("CC", "llvm-gcc-4.2");

$args{GUARDMALLOC} = getbools("GUARDMALLOC", 0);

$BUILD = getbool("BUILD", 1);
$RUN = getbool("RUN", 1);
$VERBOSE = getbool("VERBOSE", 0);

my $root = getarg("ROOT", "/");

my @tests = gettests();

print "note: -----\n";
print "note: testing root $root\n";

my @configs = make_configs($root, %args);

print "note: -----\n";
print "note: testing ", scalar(@configs), " configurations:\n";
for my $configref (@configs) {
    my $configname = $$configref{NAME};
    print "note: configuration $configname\n";
}

if ($BUILD) {
    `rm -rf '$BUILDDIR'`;
    mkdir "$BUILDDIR" || die;
}

my $failed = 0;

my $testconfigs = @configs;
my $failconfigs = 0;
my $testcount = 0;
my $failcount = 0;
for my $configref (@configs) {
    my $configname = $$configref{NAME};
    print "note: -----\n";
    print "note: \nnote: $configname\nnote: \n";

    (my $t, my $f) = eval { run_one_config($configref, @tests); };
    if ($@) {
        chomp $@;
        print "${red}FAIL: $configname${def}\n";
        print "${red}FAIL: $@${def}\n";
        $failconfigs++;
    } else {
        my $color = ($f ? $red : "");
        print "note:\n";
        print "${color}note: $configname$def\n";
        print "${color}note: $t tests, $f failures$def\n";
        $testcount += $t;
        $failcount += $f;
        $failconfigs++ if ($f);
    }
}

print "note: -----\n";
my $color = ($failconfigs ? $red : "");
print "${color}note: $testconfigs configurations, $failconfigs with failures$def\n";
print "${color}note: $testcount tests, $failcount failures$def\n";

$failed = ($failconfigs ? 1 : 0);

exit ($failed ? 1 : 0);
