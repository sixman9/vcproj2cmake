#!/usr/bin/ruby

require 'fileutils'
require 'find'
require 'pathname'

script_fqpn = File.expand_path $0
script_path = Pathname.new(script_fqpn).parent
source_root = Dir.pwd

$stdout.puts "Welcome to the guided install of vcproj2cmake!"



# Not enough testing/development, thus bail out...
# (I wanted to commit my files now, but it's not finished)
# Those who feel daring enough might decide to disable this check.
$stdout.puts "Unfortunately this script is not ready for public consumption yet, aborting!"
exit 1




$stdout.puts "Verifying cmake binary availability."
output = `cmake --version`
if not $?.success?
  $stderr.puts "ERROR: cmake binary not found, aborting - you probably need to install a CMake package!"
  exit 1
end

$stdout.puts "Creating build directory for guided installation."
build_install_dir = "#{script_path}/build_install"
if not File.exist?(build_install_dir)
  if not FileUtils.mkdir_p build_install_dir
    $stderr.puts "ERROR: couldn't create build directory, aborting!"
    exit 1
  end
end

if not Dir.chdir(build_install_dir)
  $stderr.puts "ERROR: couldn't change into build directory for guided installation, aborting!"
  exit 1
end

# I'm not sure whether it's a good idea to have Subversion fetching done
# as a build-time rule. This requires us to re-configure things multiple
# times (to provide the install target once all preconditions are
# fulfilled).
# The (possibly better) alternative would be to do SVN fetching at configure
# time.

# Hmm, we probably should also support the Qt-based GUI.
output = `ccmake --help`
if not $?.success?
  $stderr.puts "ERROR: couldn't run ccmake - perhaps it is not installed. On Debian-based Linux, installing the cmake-curses-gui package might help."
  exit 1
end

$stdout.puts "Preparing the build tree (CMake configure run) which is required for installation of vcproj2cmake components"
system "ccmake ../"
if not $?.success?
  $stderr.puts "ERROR: invocation of ccmake failed, aborting!"
  exit 1
end

system "cmake ."
if not $?.success?
  $stderr.puts
  $stderr.puts "ERROR: a CMake configure run failed, aborting!"
  $stderr.puts "Probably verification of the configuration data for installation of vcproj2cmake components failed."
  $stderr.puts "You should re-run this installer and re-configure CMake variables to contain valid references."
  $stderr.puts
  exit 1
end

$stderr.puts
$stderr.puts "Will now attempt to install vcproj2cmake components into the .vcproj-based source tree you configured."
$stderr.puts

# TODO: should check whether CMAKE_GENERATOR is Unix Makefiles,
# else do non-make handling below.

system "make all"
if not $?.success?
  $stderr.puts "ERROR: execution of all target failed!"
  exit 1
end

system "cmake ."
if not $?.success?
  $stderr.puts
  $stderr.puts "ERROR: second CMake configure run failed, aborting!"
end

system "make install"
if not $?.success?
  $stderr.puts "ERROR: installation of vcproj2cmake components into a .vcproj source tree failed!"
  exit 1
end

system "make convert_source_root_recursive"
if not $?.success?
  $stderr.puts "ERROR: hmm"
  exit 1
end

$stdout.puts "INFO: done."
$stdout.puts "Now you can attempt to run various build targets within your newly converted/configured build tree"
$stdout.puts "(which references the files within your .vcproj-based source tree)."
$stdout.puts "If building fails with various includes not found/missing,"
$stdout.puts "then you should add find_package() commands to hook scripts"
$stdout.puts "and make sure that raw include directories as originally specified in .vcproj"
$stdout.puts "map to the corresponding xxx_INCLUDE_DIR variable"
$stdout.puts "as figured out by find_package(), by adding this mapping"
$stdout.puts "to include_mappings.txt."

# TODO: change into project dir, create build subdir, run ccmake -DCMAKE_BUILD_TYPE=Debug ../
# , try to build it.
#if not Dir.chdir(proj_source_dir)
#  $stderr.puts "ERROR: couldn't change into source directory of converted project, aborting!"
#  exit 1
#end


