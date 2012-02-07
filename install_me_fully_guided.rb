#!/usr/bin/ruby

require 'fileutils'
require 'find'
require 'pathname'

script_fqpn = File.expand_path $0
script_path = Pathname.new(script_fqpn).parent
source_root = Dir.pwd

def log_info(str)
  # We choose to not log an INFO: prefix (reduce log spew).
  $stdout.puts str
end

def log_error(str); $stderr.puts "ERROR: #{str}" end

def log_fatal(str); log_error "#{str}. Aborting!"; exit 1 end

log_info 'Welcome to the guided install of vcproj2cmake!'



# Not enough testing/development, thus bail out...
# (I wanted to commit my files now, but it's not finished)
# Those who feel daring enough might decide to disable this check.
log_fatal 'Unfortunately this script is not ready for public consumption yet'




log_info 'Verifying cmake binary availability.'
output = `cmake --version`
if not $?.success?
  log_fatal 'cmake binary not found - you probably need to install a CMake package'
end

log_info 'Creating build directory for guided installation.'
build_install_dir = "#{script_path}/build_install"
if not File.exist?(build_install_dir)
  if not FileUtils.mkdir_p build_install_dir
    log_fatal 'could not create build directory'
  end
end

if not Dir.chdir(build_install_dir)
  log_fatal 'could not change into build directory for guided installation'
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
  log_fatal 'could not run ccmake - perhaps it is not installed. On Debian-based Linux, installing the cmake-curses-gui package might help.'
end

log_info 'Preparing the build tree (CMake configure run) which is required for installation of vcproj2cmake components'
system 'ccmake ../'
if not $?.success?
  log_fatal 'invocation of ccmake failed'
end

system 'cmake .'
if not $?.success?
  $stderr.puts
  log_fatal \
    'a CMake configure run failed\n' \
    'Probably verification of the configuration data for installation of vcproj2cmake components failed.\n' \
    'You should re-run this installer and re-configure CMake variables to contain valid references.\n\n'
end

log_info ''
log_info 'Will now attempt to install vcproj2cmake components into the .vcproj-based source tree you configured.'
log_info ''

# TODO: should check whether CMAKE_GENERATOR is Unix Makefiles,
# else do non-make handling below.

system 'make all'
if not $?.success?
  log_fatal 'execution of all target failed'
end

system 'cmake .'
if not $?.success?
  log_error
  log_fatal 'second CMake configure run failed'
end

system 'make install'
if not $?.success?
  log_fatal 'installation of vcproj2cmake components into a .vcproj source tree failed'
end

system 'make convert_source_root_recursive'
if not $?.success?
  log_fatal 'hmm'
end

$stdout.puts 'INFO: done.'
$stdout.puts 'Now you can attempt to run various build targets within your newly converted/configured build tree'
$stdout.puts '(which references the files within your .vcproj-based source tree).'
$stdout.puts 'If building fails with various includes not found/missing,'
$stdout.puts 'then you should add find_package() commands to hook scripts'
$stdout.puts 'and make sure that raw include directories as originally specified in .vcproj'
$stdout.puts 'map to the corresponding xxx_INCLUDE_DIR variable'
$stdout.puts 'as figured out by find_package(), by adding this mapping'
$stdout.puts 'to include_mappings.txt.'

# TODO: change into project dir, create build subdir, run ccmake -DCMAKE_BUILD_TYPE=Debug ../
# , try to build it.
#if not Dir.chdir(proj_source_dir)
#  $stderr.puts "ERROR: couldn't change into source directory of converted project, aborting!"
#  exit 1
#end


