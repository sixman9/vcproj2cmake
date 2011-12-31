#!/usr/bin/env ruby

# Given a Visual Studio project, create a CMakeLists.txt file which optionally
# allows for ongoing side-by-side operation (e.g. on Linux, Mac)
# together with the existing static .vcproj project on the Windows side.
# Provides good support for simple DLL/Static/Executable projects,
# but custom build steps and build events are ignored.

# Author: Jesper Eskilson
# Email: jesper [at] eskilson [dot] se
# Author 2: Andreas Mohr
# Email: andi [at] lisas [period] de
# Large list of extensions:
# list _all_ configuration types, add indenting, add per-platform configuration
# of definitions, dependencies and includes, add optional includes
# to provide static content, thus allowing for a nice on-the-fly
# generation mode of operation _side-by-side_ existing and _updated_ .vcproj files,
# fully support recursive handling of all .vcproj file groups (filters).

# If you add code, please try to keep this file generic and modular,
# to enable other people to hook into a particular part easily
# and thus keep any additions specific to the requirements of your local project _separate_.

# TODO/NOTE:
# Always make sure that a simple vcproj2cmake.rb run will result in a
# fully working _self-contained_ CMakeLists.txt, no matter how small
# the current vcproj2cmake config environment is
# (i.e., it needs to work even without a single specification file)

# TODO:
# - perhaps there's a way to provide more precise/comfortable hook script handling?
# - should continue with clean separation of .vcproj content parsing and .vcproj output
#   generation (e.g. in preparation for .vcxproj support)
#   And move everything into classes (not sure about the extent of Ruby
#   support here). Create vcproj parser class(es) which works on a
#   common parser support base class, feed it some vcproj configuration
#   class, configure that class, then push it (with the vcproj settings
#   it contains) over to a CMake generator class.
# - try to come up with an ingenious way to near-_automatically_ handle those pesky repeated
#   dependency requirements of several sub projects
#   (e.g. the component-based Boost Find scripts, etc.) instead of having to manually
#   write custom hook script content (which cannot be kept synchronized
#   with changes _automatically_!!) each time due to changing components and libraries.

require 'tempfile'
require 'pathname'
require 'rexml/document'

# http://devblog.vworkapp.com/post/910714976/best-practice-for-rubys-require

$LOAD_PATH.unshift(File.dirname(__FILE__) + '/.') unless $LOAD_PATH.include?(File.dirname(__FILE__) + '/.')
$LOAD_PATH.unshift(File.dirname(__FILE__) + '/./lib') unless $LOAD_PATH.include?(File.dirname(__FILE__) + '/./lib')

require 'vcproj2cmake/util_file' # V2C_Util_File.cmp()

# load common settings
load 'vcproj2cmake_settings.rb'

# Usage: vcproj2cmake.rb <input.vc[x]proj> [<output CMakeLists.txt>] [<master project directory>]

#*******************************************************************************************************
# Check for command-line input errors
# -----------------------------------
cl_error = ""

script_name = $0

if ARGV.length < 1
   cl_error = "*** Too few arguments\n"
else
   vcproj_filename = ARGV.shift
   #puts "First arg is #{vcproj_filename}"

   # Discovered Ruby 1.8.7(?) BUG: kills extension on duplicate slashes: ".//test.ext"
   # OK: ruby-1.8.5-5.el5_4.8, KO: u10.04 ruby1.8 1.8.7.249-2 and ruby1.9.1 1.9.1.378-1
   # http://redmine.ruby-lang.org/issues/show/3882
   # TODO: add a version check to conditionally skip this cleanup effort?
   vcproj_filename = Pathname.new(vcproj_filename).cleanpath

   if File.extname(vcproj_filename) != ".vcproj"
      # The first argument on the command-line did not have a '.vcproj' extension.
      # If the local directory contains file "ARGV[0].vcproj" then use it, else error.
      # (Note:  Only '+' works here for concatenation, not '<<'.)
      vcproj_filename = vcproj_filename + ".vcproj"

      #puts "Looking for #{vcproj_filename}"
      unless FileTest.exist?(vcproj_filename)
         cl_error = "*** The first argument must be the Visual Studio project name\n"
      end
   end
end

if ARGV.length > 3
   cl_error = cl_error << "*** Too many arguments\n"
end

unless cl_error == ""
   puts %{\
*** Input Error *** #{script_name}
#{cl_error}

Usage: vcproj2cmake.rb <input.vcproj> [<output CMakeLists.txt>] [<master project directory>]
}

   exit
end

# Process the optional command-line arguments
# -------------------------------------------
# FIXME:  Variables 'output_file' and 'master_project_dir' are position-dependent on the
# command-line, if they are entered.  The script does not have a way to distinguish whether they
# were input in the wrong order.  A potential fix is to associate flags with the arguments, like
# '-i <input.vcproj> [-o <output CMakeLists.txt>] [-d <master project directory>]' and then parse
# them accordingly.  This lets them be entered in any order and removes ambiguity.
# -------------------------------------------
output_file = ARGV.shift or output_file = File.join(File.dirname(vcproj_filename), "CMakeLists.txt")

# Master (root) project dir defaults to current dir--useful for simple, single-.vcproj conversions.
$master_project_dir = ARGV.shift
if not $master_project_dir
  $master_project_dir = "."
end
#*******************************************************************************************************

### USER-CONFIGURABLE SECTION ###

# since the .vcproj multi-configuration environment has some settings
# that can be specified per-configuration (target type [lib/exe], include directories)
# but where CMake unfortunately does _NOT_ offer a configuration-specific equivalent,
# we need to fall back to using the globally-scoped CMake commands (include_directories() etc.).
# But at least let's optionally allow the user to precisely specify which configuration
# (empty [first config], "Debug", "Release", ...) he wants to have
# these settings taken from.
config_multi_authoritative = ""

$filename_map_def = "#{$v2c_config_dir_local}/define_mappings.txt"
$filename_map_dep = "#{$v2c_config_dir_local}/dependency_mappings.txt"
$filename_map_lib_dirs = "#{$v2c_config_dir_local}/lib_dirs_mappings.txt"

$myindent = 0

# global variable to indicate whether we want debug output or not
$debug = false

### USER-CONFIGURABLE SECTION END ###

master_project_location = File.expand_path $master_project_dir
p_master_proj = Pathname.new(master_project_location)

p_vcproj = Pathname.new(vcproj_filename)
# figure out a global project_dir variable from the .vcproj location
$project_dir = p_vcproj.dirname

#p_project_dir = Pathname.new($project_dir)
#p_cmakelists = Pathname.new(output_file)
#cmakelists_dir = p_cmakelists.dirname
#p_cmakelists_dir = Pathname.new(cmakelists_dir)
#p_cmakelists_dir.relative_path_from(...)

script_location = File.expand_path "#{script_name}"
p_script = Pathname.new(script_location)
script_location_relative_to_master = p_script.relative_path_from(p_master_proj)
#puts "p_script #{p_script} | p_master_proj #{p_master_proj} | script_location_relative_to_master #{script_location_relative_to_master}"

# monster HACK: set a global variable, since we need to be able
# to tell whether we're able to build a target
# (i.e. whether we have any build units i.e.
# implementation files / non-header files),
# otherwise we should not add a target since CMake will
# complain with "Cannot determine link language for target "xxx"".
$have_build_units = false


### definitely internal helpers ###
$vcproj2cmake_func_cmake = "vcproj2cmake_func.cmake"
$v2c_attribute_not_provided_marker = "V2C_NOT_PROVIDED"


def puts_debug(str)
  if $debug
    puts str
  end
end

def puts_info(str)
  # We choose to not log an INFO: prefix (reduce log spew).
  puts str
end

def puts_warn(str)
  puts "WARNING: #{str}"
end

def puts_error(str)
  $stderr.puts "ERROR: #{str}"
end

def puts_fatal(str)
  puts_error "#{str}. Aborting!"
  exit 1
end

def puts_ind(chan, str)
  chan.print ' ' * $myindent
  chan.puts str
end

# tiny helper, simply to save some LOC
def new_puts_ind(chan, str)
  chan.puts
  puts_ind(chan, str)
end

# Change \ to /, and remove leading ./
def normalize_path(p)
  felems = p.gsub("\\", "/").split("/")
  # DON'T eradicate single '.' !!
  felems.shift if felems[0] == "." and felems.size > 1
  File.join(felems)
end

def escape_char(in_string, esc_char)
  #puts "in_string #{in_string}"
  in_string.gsub!(/#{esc_char}/, "\\#{esc_char}")
  #puts "in_string quoted #{in_string}"
end

def escape_backslash(in_string)
  # "Escaping a Backslash In Ruby's Gsub": "The reason for this is that
  # the backslash is special in the gsub method. To correctly output a
  # backslash, 4 backslashes are needed.". Oerks - oh well, do it.
  # hrmm, seems we need some more even...
  # (or could we use single quotes (''') for that? Too lazy to retry...)
  in_string.gsub!(/\\/, "\\\\\\\\")
end

def read_mappings(filename_mappings, mappings)
  # line format is: "tag:PLATFORM1:PLATFORM2=tag_replacement2:PLATFORM3=tag_replacement3"
  if File.exists?(filename_mappings)
    #Hash[*File.read(filename_mappings).scan(/^(.*)=(.*)$/).flatten]
    File.open(filename_mappings, 'r').each do |line|
      next if line =~ /^\s*#/
      b, c = line.chomp.split(/:/)
      mappings[b] = c
    end
  else
    puts_debug "NOTE: #{filename_mappings} NOT AVAILABLE"
  end
  #puts mappings["kernel32"]
  #puts mappings["mytest"]
end

# Read mappings of both current project and source root.
# Ordering should definitely be _first_ current project,
# _then_ global settings (a local project may have specific
# settings which should _override_ the global defaults).
def read_mappings_combined(filename_mappings, mappings)
  read_mappings(filename_mappings, mappings)
  if $master_project_dir
    # read common mappings (in source root) to be used by all sub projects
    read_mappings("#{$master_project_dir}/#{filename_mappings}", mappings)
  end
end

def push_platform_defn(platform_defs, platform, defn_value)
  #puts "adding #{defn_value} on platform #{platform}"
  if platform_defs[platform].nil?
    platform_defs[platform] = Array.new
  end
  platform_defs[platform].push(defn_value)
end

def parse_platform_conversions(platform_defs, arr_defs, map_defs)
  arr_defs.each { |curr_defn|
    #puts map_defs[curr_defn]
    map_line = map_defs[curr_defn]
    if map_line.nil?
      # hmm, no direct match! Try to figure out whether any map entry
      # is a regex which would match our curr_defn
      map_defs.each do |key, value|
        if curr_defn =~ /^#{key}$/
          puts_debug "KEY: #{key} curr_defn #{curr_defn}"
          map_line = value
          break
        end
      end
    end
    if map_line.nil?
      # no mapping? --> unconditionally use the original define
      push_platform_defn(platform_defs, "ALL", curr_defn)
    else
      # Tech note: chomp on map_line should not be needed as long as
      # original constant input has already been pre-treated (chomped).
      map_line.split(/\|/).each do |platform_element|
        #puts "platform_element #{platform_element}"
        platform, replacement_defn = platform_element.split(/=/)
        if platform.empty?
          # specified a replacement without a specific platform?
          # ("tag:=REPLACEMENT")
          # --> unconditionally use it!
          platform = "ALL"
        else
          if replacement_defn.nil?
            replacement_defn = curr_defn
          end
        end
        push_platform_defn(platform_defs, platform, replacement_defn)
      end
    end
  }
end

$cmake_var_match_regex = "\\$\\{[[:alnum:]_]+\\}"
$cmake_env_var_match_regex = "\\$ENV\\{[[:alnum:]_]+\\}"

# (un)quote strings as needed
#
# Once we added a variable in the string,
# we definitely _need_ to have the resulting full string quoted
# in the generated file, otherwise we won't obey
# CMake filesystem whitespace requirements! (string _variables_ _need_ quoting)
# However, there is a strong argument to be made for applying the quotes
# on the _generator_ and not _parser_ side, since it's a CMake syntax attribute
# that such strings need quoting.
def cmake_element_handle_quoting(elem)
  # Determine whether quoting needed
  # (in case of whitespace or variable content):
  #if elem.match(/\s|#{$cmake_var_match_regex}|#{$cmake_env_var_match_regex}/)
  # Hrmm, turns out that variables better should _not_ be quoted.
  # But what we _do_ need to quote is regular strings which include
  # whitespace characters, i.e. check for alphanumeric char following
  # whitespace or the other way around.
  # Quoting rules seem terribly confusing, will need to revisit things
  # to get it all precisely correct.
  if elem.match(/[:alnum:]\s|\s[:alnum:]/)
    needs_quoting = 1
  end
  if elem.match(/".*"/)
    has_quotes = 1
  end
  if needs_quoting and not has_quotes
    return "\"#{elem}\""
  end
  if not needs_quoting and has_quotes
    return elem.gsub(/"(.*)"/, '\1')
  end
  return elem
end

# IMPORTANT NOTE: the generator/target/parser class hierarchy and _naming_
# is supposed to be eerily similar to the one used by CMake.
# Dito for naming of individual methods...
#
# Global generator: generates/manages parts which are not project-local/target-related
# local generator: has a Makefile member (which contains a list of targets),
#   then generates project files by iterating over the targets via a newly generated target generator each.
# target generator: generates targets. This is the one creating/producing the output file stream. Not provided by all generators (VS10 yes, VS7 no).


class V2C_Config_Info
  def initialize
    @type = 0
    @use_of_mfc = 0
    @use_of_atl = 0
  end

  attr_accessor :type
  attr_accessor :use_of_mfc
  attr_accessor :use_of_atl
end

class V2C_Makefile
  def initialize
    @config_info = V2C_Config_Info.new
  end

  attr_accessor :config_info
end

class V2C_SCC_Info
  def initialize
    @project_name = nil
    @local_path = nil
    @provider = nil
  end

  attr_accessor :project_name
  attr_accessor :local_path
  attr_accessor :provider
end

class V2C_Target
  def initialize
    @name = nil
    @vs_keyword = nil
    @scc_info = V2C_SCC_Info.new
  end

  attr_accessor :name
  attr_accessor :vs_keyword
  attr_accessor :scc_info
end

class V2C_BaseVCProjGlobalParser
  def initialize
    @filename_map_inc = "#{$v2c_config_dir_local}/include_mappings.txt"
    @map_includes = Hash.new
    read_mappings_includes()
  end

  attr_accessor :map_includes

  private

  def read_mappings_includes
    # These mapping files may contain things such as mapping .vcproj "Vc7/atlmfc/src/mfc"
    # into CMake "SYSTEM ${MFC_INCLUDE}" information.
    read_mappings_combined(@filename_map_inc, @map_includes)
  end
end

class V2C_CMakeSyntaxGenerator
  def initialize(out)
    @out = out
  end

  def generated_comments_level
    return $v2c_generated_comments_level
  end

  def write_empty_line
    @out.puts
  end
  # WIN32, MSVC, ...
  def write_conditional_begin(str_conditional)
    if not str_conditional.nil?
      puts_ind(@out, "if(#{str_conditional})")
      $myindent += 2
    end
  end
  def write_conditional_end(str_conditional)
    if not str_conditional.nil?
      $myindent -= 2
      puts_ind(@out, "endif(#{str_conditional})")
    end
  end
  def write_vcproj2cmake_func_comment()
    if generated_comments_level() >= 2
      puts_ind(@out, "# See function implementation/docs in #{$v2c_module_path_root}/#{$vcproj2cmake_func_cmake}")
    end
  end
end

class V2C_CMakeGlobalGenerator < V2C_CMakeSyntaxGenerator
  def put_file_header
    put_file_header_temporary_marker()
    put_file_header_cmake_minimum_version()
    put_file_header_cmake_policies()

    put_cmake_module_path()
    put_var_config_dir_local()
    put_include_vcproj2cmake_func()
    put_hook_pre()
  end
  def put_project(project_name)
    # TODO: figure out language type (C CXX etc.) and add it to project() command
    new_puts_ind(@out, "project(#{project_name})")
  end
  def put_cmake_mfc_atl_flag(config_info)
    # FIXME: do we need to actively _reset_ CMAKE_MFC_FLAG / CMAKE_ATL_FLAG
    # (i.e. best also set() it in case of 0?), since projects in subdirs shouldn't inherit?

    if config_info.use_of_mfc > 0
      new_puts_ind(@out, "set(CMAKE_MFC_FLAG #{config_info.use_of_mfc})")
    end
    # ok, there's no CMAKE_ATL_FLAG yet, AFAIK, but still prepare
    # for it (also to let people probe on this in hook includes)
    if config_info.use_of_atl > 0
      # TODO: should also set the per-configuration-type variable variant
      new_puts_ind(@out, "set(CMAKE_ATL_FLAG #{config_info.use_of_atl})")
    end
  end
  def put_hook_pre
    # this CMakeLists.txt-global optional include could be used e.g.
    # to skip the entire build of this file on certain platforms:
    # if(PLATFORM) message(STATUS "not supported") return() ...
    # (note that we appended CMAKE_MODULE_PATH _prior_ to this include()!)
    new_puts_ind(@out, "include(\"${V2C_CONFIG_DIR_LOCAL}/hook_pre.txt\" OPTIONAL)")
  end
  def put_hook_project
    if generated_comments_level() >= 2
      puts_ind(@out, "# hook e.g. for invoking Find scripts as expected by")
      puts_ind(@out, "# the _LIBRARIES / _INCLUDE_DIRS mappings created")
      puts_ind(@out, "# by your include/dependency map files.")
    end
    puts_ind(@out, "include(\"${V2C_HOOK_PROJECT}\" OPTIONAL)")
  end
  def put_hook_post_definitions
    write_empty_line()
    if generated_comments_level() >= 1
      puts_ind(@out, "# hook include after all definitions have been made")
      puts_ind(@out, "# (but _before_ target is created using the source list!)")
    end
    puts_ind(@out, "include(\"${V2C_HOOK_POST_DEFINITIONS}\" OPTIONAL)")
  end
  def put_hook_post_sources
    new_puts_ind(@out, "include(\"${V2C_HOOK_POST_SOURCES}\" OPTIONAL)")
  end
  def put_hook_post_target
    write_empty_line()
    if generated_comments_level() >= 1
      puts_ind(@out, "# e.g. to be used for tweaking target properties etc.")
    end
    puts_ind(@out, "include(\"${V2C_HOOK_POST_TARGET}\" OPTIONAL)")
  end
  def put_include_project_source_dir
    # AFAIK .vcproj implicitly adds the project root to standard include path
    # (for automatic stdafx.h resolution etc.), thus add this
    # (and make sure to add it with high priority, i.e. use BEFORE).
    new_puts_ind(@out, "include_directories(BEFORE \"${PROJECT_SOURCE_DIR}\")")
  end
  def put_configuration_types(configuration_types)
    configuration_types_list = cmake_separate_arguments(configuration_types)
    puts_ind(@out, "set(CMAKE_CONFIGURATION_TYPES \"#{configuration_types_list}\")" )
  end
  def put_var_converter_script_location(script_location_relative_to_master)
    # For the CMakeLists.txt rebuilder (automatic rebuild on file changes),
    # add handling of a script file location variable, to enable users
    # to override the script location if needed.
    write_empty_line()
    if generated_comments_level() >= 1
      puts_ind(@out, "# user override mechanism (allow defining custom location of script)")
    end
    puts_ind(@out, "if(NOT V2C_SCRIPT_LOCATION)")
    $myindent += 2
    # NOTE: we'll make V2C_SCRIPT_LOCATION express its path via
    # relative argument to global CMAKE_SOURCE_DIR and _not_ CMAKE_CURRENT_SOURCE_DIR,
    # (this provision should even enable people to manually relocate
    # an entire sub project within the source tree).
    puts_ind(@out, "set(V2C_SCRIPT_LOCATION \"${CMAKE_SOURCE_DIR}/#{script_location_relative_to_master}\")")
    $myindent -= 2
    puts_ind(@out, "endif(NOT V2C_SCRIPT_LOCATION)")
  end

  def initialize(out)
    super(out)
  end
  def put_include_MasterProjectDefaults_vcproj2cmake
    if generated_comments_level() >= 2
      @out.puts %{\

# this part is for including a file which contains
# _globally_ applicable settings for all sub projects of a master project
# (compiler flags, path settings, platform stuff, ...)
# e.g. have vcproj2cmake-specific MasterProjectDefaults_vcproj2cmake
# which then _also_ includes a global MasterProjectDefaults module
# for _all_ CMakeLists.txt. This needs to sit post-project()
# since e.g. compiler info is dependent on a valid project.
}
      puts_ind(@out, "# MasterProjectDefaults_vcproj2cmake is supposed to define generic settings")
      puts_ind(@out, "# (such as V2C_HOOK_PROJECT, defined as e.g.")
      puts_ind(@out, "# #{$v2c_config_dir_local}/hook_project.txt,")
      puts_ind(@out, "# and other hook include variables below).")
      puts_ind(@out, "# NOTE: it usually should also reset variables")
      puts_ind(@out, "# V2C_LIBS, V2C_SOURCES etc. as used below since they should contain")
      puts_ind(@out, "# directory-specific contents only, not accumulate!")
    end
    # (side note: see "ldd -u -r" on Linux for superfluous link parts potentially caused by this!)
    puts_ind(@out, "include(MasterProjectDefaults_vcproj2cmake OPTIONAL)")
  end

  private

  def put_file_header_temporary_marker
    # WARNING: since this comment header is meant to advertise
    # _generated_ vcproj2cmake files, user-side code _will_ check for this
    # particular wording to tell apart generated CMakeLists.txt from
    # custom-written ones, thus one should definitely avoid changing
    # this phrase.
    @out.puts %{\
#
# TEMPORARY Build file, AUTO-GENERATED by http://vcproj2cmake.sf.net
# DO NOT CHECK INTO VERSION CONTROL OR APPLY \"PERMANENT\" MODIFICATIONS!!
#

}
  end
  def put_file_header_cmake_minimum_version
    # Required version line to make cmake happy.
    if generated_comments_level() >= 1
      @out.puts "# >= 2.6 due to crucial set_property(... COMPILE_DEFINITIONS_* ...)"
    end
    @out.puts "cmake_minimum_required(VERSION 2.6)"
  end
  def put_file_header_cmake_policies
    # CMP0005: manual quoting of brackets in definitions doesn't seem to work otherwise,
    # in cmake 2.6.4-7.el5 with "OLD".
    @out.puts %{\
if(COMMAND cmake_policy)
  if(POLICY CMP0005)
}
    if generated_comments_level() >= 3
      @out.puts "    # automatic quoting of brackets"
    end
    @out.puts %{\
    cmake_policy(SET CMP0005 NEW)
  endif(POLICY CMP0005)

  if(POLICY CMP0011)
}
    if generated_comments_level() >= 3
      @out.puts %{\
    # we do want the includer to be affected by our updates,
    # since it might define project-global settings.
}
    end
    @out.puts %{\
    cmake_policy(SET CMP0011 OLD)
  endif(POLICY CMP0011)
  if(POLICY CMP0015)
}
    if generated_comments_level() >= 3
      @out.puts %{\
    # .vcproj contains relative paths to additional library directories,
    # thus we need to be able to cope with that
}
    end
    @out.puts %{\
    cmake_policy(SET CMP0015 NEW)
  endif(POLICY CMP0015)
endif(COMMAND cmake_policy)
}
  end
  def put_cmake_module_path
    # try to point to cmake/Modules of the topmost directory of the vcproj2cmake conversion tree.
    # This also contains vcproj2cmake helper modules (these should - just like the CMakeLists.txt -
    # be within the project tree as well, since someone might want to copy the entire project tree
    # including .vcproj conversions to a different machine, thus all v2c components should be available)
    #new_puts_ind(@out, "set(V2C_MASTER_PROJECT_DIR \"#{$master_project_dir}\")")
    new_puts_ind(@out, "set(V2C_MASTER_PROJECT_DIR \"${CMAKE_SOURCE_DIR}\")")
    # NOTE: use set() instead of list(APPEND...) to _prepend_ path
    # (otherwise not able to provide proper _overrides_)
    puts_ind(@out, "set(CMAKE_MODULE_PATH \"${V2C_MASTER_PROJECT_DIR}/#{$v2c_module_path_local}\" ${CMAKE_MODULE_PATH})")
  end
  def put_var_config_dir_local
    # "export" our internal $v2c_config_dir_local variable (to be able to reference it in CMake scripts as well)
    new_puts_ind(@out, "set(V2C_CONFIG_DIR_LOCAL \"#{$v2c_config_dir_local}\")")
  end
  def put_include_vcproj2cmake_func
    write_empty_line()
    if generated_comments_level() >= 2
      puts_ind(@out, "# include the main file for pre-defined vcproj2cmake helper functions")
      puts_ind(@out, "# This module will also include the configuration settings definitions module")
    end
    puts_ind(@out, "include(vcproj2cmake_func)")
  end
end

# analogous to CMake separate_arguments() command
def cmake_separate_arguments(array_in)
  array_in.join(";")
end

class V2C_CMakeLocalGenerator < V2C_CMakeSyntaxGenerator
  def initialize(out)
    super(out)
  end

  def write_link_directories(arr_lib_dirs, map_lib_dirs)
    if generated_comments_level() >= 3
      puts_ind(@out, "# It is said to be preferable to be able to use target_link_libraries()")
      puts_ind(@out, "# rather than the very unspecific link_directories().")
    end
    write_build_attributes("link_directories", "", arr_lib_dirs, map_lib_dirs, nil)
  end
  def write_directory_property_compile_flags(attr_opts)
    return if attr_opts.nil?
    write_empty_line()
    # Query WIN32 instead of MSVC, since AFAICS there's nothing in the
    # .vcproj to indicate tool specifics, thus these seem to
    # be settings for ANY PARTICULAR tool that is configured
    # on the Win32 side (.vcproj in general).
    str_platform = "WIN32"
    write_conditional_begin(str_platform)
    puts_ind(@out, "set_property(DIRECTORY APPEND PROPERTY COMPILE_FLAGS #{attr_opts})")
    write_conditional_end(str_platform)
  end

  # FIXME private!
  def write_build_attributes(cmake_command, element_prefix, arr_defs, map_defs, cmake_command_arg)
    # the container for the list of _actual_ dependencies as stated by the project
    all_platform_defs = Hash.new
    parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
    all_platform_defs.each { |key, arr_platdefs|
      #puts_info "arr_platdefs: #{arr_platdefs}"
      next if arr_platdefs.empty?
      arr_platdefs.uniq!
      write_empty_line()
      str_platform = key if not key.eql?("ALL")
      write_conditional_begin(str_platform)
      if cmake_command_arg.nil?
        cmake_command_arg = ""
      end
      puts_ind(@out, "#{cmake_command}(#{cmake_command_arg}")
      arr_platdefs.each do |curr_value|
        curr_value_quot = cmake_element_handle_quoting(curr_value)
        puts_ind(@out, "  #{element_prefix}#{curr_value_quot}")
      end
      puts_ind(@out, ")")
      write_conditional_end(str_platform)
    }
  end
  def write_func_v2c_post_setup(project_name, project_keyword, vs_proj_file_basename)
    # Rationale: keep count of generated lines of CMakeLists.txt to a bare minimum -
    # call v2c_post_setup(), by simply passing all parameters that are _custom_ data
    # of the current generated CMakeLists.txt file - all boilerplate handling functionality
    # that's identical for each project should be implemented by the v2c_post_setup() function
    # _internally_.
    write_vcproj2cmake_func_comment()
    puts_ind(@out, "v2c_post_setup(#{project_name}")
    if project_keyword.nil?
	project_keyword = "#{$v2c_attribute_not_provided_marker}"
    end
    puts_ind(@out, "  \"#{project_name}\" \"#{project_keyword}\"")
    puts_ind(@out, "  \"${CMAKE_CURRENT_SOURCE_DIR}/#{vs_proj_file_basename}\"")
    puts_ind(@out, "  \"${CMAKE_CURRENT_LIST_FILE}\")")
  end
end

class V2C_CMakeTargetGenerator < V2C_CMakeSyntaxGenerator
  def initialize(target, localGenerator, out)
    @target = target
    @localGenerator = localGenerator
    super(out)
  end

  def put_file_list(project_name, files_str, parent_source_group, arr_sub_sources_for_parent)
    group = files_str[:name]
    if not files_str[:arr_sub_filters].nil?
      arr_sub_filters = files_str[:arr_sub_filters]
    end
    if not files_str[:arr_files].nil?
      arr_local_sources = files_str[:arr_files].clone
    end
  
    # TODO: cmake is said to have a weird bug in case of parent_source_group being "Source Files":
    # "Re: [CMake] SOURCE_GROUP does not function in Visual Studio 8"
    #   http://www.mail-archive.com/cmake@cmake.org/msg05002.html
    if parent_source_group.nil?
      this_source_group = ""
    else
      if parent_source_group == ""
        this_source_group = group
      else
        this_source_group = "#{parent_source_group}\\\\#{group}"
      end
    end
  
    # process sub-filters, have their main source variable added to arr_my_sub_sources
    arr_my_sub_sources = Array.new
    if not arr_sub_filters.nil?
      $myindent += 2
      arr_sub_filters.each { |subfilter|
        #puts_info "writing: #{subfilter}"
        put_file_list(project_name, subfilter, this_source_group, arr_my_sub_sources)
      }
      $myindent -= 2
    end
  
    group_tag = this_source_group.clone.gsub(/( |\\)/,'_')
  
    # process our hierarchy's own files
    if not arr_local_sources.nil?
      source_files_variable = "SOURCES_files_#{group_tag}"
      new_puts_ind(@out, "set(#{source_files_variable}" )
      arr_local_sources.each { |source|
        #puts_info "quotes now: #{source}"
        source_quot = cmake_element_handle_quoting(source)
        puts_ind(@out, "  #{source_quot}")
      }
      puts_ind(@out, ")")
      # create source_group() of our local files
      if not parent_source_group.nil?
        puts_ind(@out, "source_group(\"#{this_source_group}\" FILES ${#{source_files_variable}})")
      end
    end
    if not source_files_variable.nil? or not arr_my_sub_sources.empty?
      sources_variable = "SOURCES_#{group_tag}";
      new_puts_ind(@out, "set(SOURCES_#{group_tag}")
      $myindent += 2;
      # dump sub filters...
      arr_my_sub_sources.each { |source|
        puts_ind(@out, "${#{source}}")
      }
      # ...then our own files
      if not source_files_variable.nil?
        puts_ind(@out, "${#{source_files_variable}}")
      end
      $myindent -= 2;
      puts_ind(@out, ")")
      # add our source list variable to parent return
      arr_sub_sources_for_parent.push(sources_variable)
    end
  end
  def put_sources(arr_sub_sources)
    new_puts_ind(@out, "set(SOURCES")
    $myindent += 2
    arr_sub_sources.each { |source_item|
      puts_ind(@out, "${#{source_item}}")
    }
    $myindent -= 2
    puts_ind(@out, ")")
  end
  def generate_property_compile_definitions(config_name_upper, arr_platdefs, str_platform)
      write_conditional_begin(str_platform)
      # make sure to specify APPEND for greater flexibility (hooks etc.)
      puts_ind(@out, "set_property(TARGET #{@target.name} APPEND PROPERTY COMPILE_DEFINITIONS_#{config_name_upper}")
      $myindent += 2
      # FIXME: we should probably get rid of sort() here,
      # but for now we'll keep it, to retain identically generated files.
      arr_platdefs.sort.each do |compile_defn|
	# Need to escape the value part of the key=value definition:
        if compile_defn =~ /[\(\)]+/
           escape_char(compile_defn, '\\(')
           escape_char(compile_defn, '\\)')
        end
        puts_ind(@out, compile_defn)
      end
      $myindent -= 2
      puts_ind(@out, ")")
      write_conditional_end(str_platform)
  end
  def write_property_compile_definitions(config_name, hash_defs, map_defs)
    # Convert hash into array as required by common helper functions
    # (it's probably a good idea to provide "key=value" entries
    # for more complete matching possibilities
    # within the regex matching parts done by those functions).
    arr_defs = Array.new
    hash_defs.each { |key, value|
      if value.empty?
	  arr_defs.push(key)
      else
	  arr_defs.push("#{key}=#{value}")
      end
    }
    config_name_upper = get_config_name_upcase(config_name)
    # the container for the list of _actual_ dependencies as stated by the project
    all_platform_defs = Hash.new
    parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
    all_platform_defs.each { |key, arr_platdefs|
      #puts_info "arr_platdefs: #{arr_platdefs}"
      next if arr_platdefs.empty?
      arr_platdefs.uniq!
      write_empty_line()
      str_platform = key if not key.eql?("ALL")
      generate_property_compile_definitions(config_name_upper, arr_platdefs, str_platform)
    }
  end
  def write_property_compile_flags(config_name, arr_flags, str_conditional)
    return if arr_flags.empty?
    config_name_upper = get_config_name_upcase(config_name)
    write_empty_line()
    write_conditional_begin(str_conditional)
    puts_ind(@out, "set_property(TARGET #{@target.name} APPEND PROPERTY COMPILE_FLAGS_#{config_name_upper}")
    arr_flags.each do |compile_flag|
      puts_ind(@out, "  #{compile_flag}")
    end
    puts_ind(@out, ")")
    write_conditional_end(str_conditional)
  end
  def write_link_libraries(arr_dependencies, map_dependencies)
    @localGenerator.write_build_attributes("target_link_libraries", "", arr_dependencies, map_dependencies, @target.name)
  end
  def set_properties_vs_scc(scc_info)
    # Keep source control integration in our conversion!
    # FIXME: does it really work? Then reply to
    # http://www.itk.org/Bug/view.php?id=10237 !!

    # If even scc_info.project_name is unavailable,
    # then we can bail out right away...
    return if scc_info.project_name.nil?

    if scc_info.local_path
      escape_backslash(scc_info.local_path)
      escape_char(scc_info.local_path, '"')
    end
    if scc_info.provider
      escape_char(scc_info.provider, '"')
    end
    write_empty_line()
    local_generator.write_vcproj2cmake_func_comment()
    # hmm, perhaps need to use CGI.escape since chars other than just '"' might need to be escaped?
    # NOTE: needed to clone() this string above since otherwise modifying (same) source object!!
    # We used to escape_char('"') below, but this was problematic
    # on VS7 .vcproj generator since that one is BUGGY (GIT trunk
    # 201007xx): it should escape quotes into XMLed "&quot;" yet
    # it doesn't. Thus it's us who has to do that and pray that it
    # won't fail on us... (but this bogus escaping within
    # CMakeLists.txt space might lead to severe trouble
    # with _other_ IDE generators which cannot deal with a raw "&quot;").
    # If so, one would need to extend v2c_target_set_properties_vs_scc()
    # to have a CMAKE_GENERATOR branch check, to support all cases.
    # Or one could argue that the escaping should better be done on
    # CMake-side code (i.e. in v2c_target_set_properties_vs_scc()).
    # Note that perhaps we should also escape all other chars
    # as in CMake's EscapeForXML() method.
    scc_info.project_name.gsub!(/"/, "&quot;")
    puts_ind(@out, "v2c_target_set_properties_vs_scc(#{@target.name} \"#{scc_info.project_name}\" \"#{scc_info.local_path}\" \"#{scc_info.provider}\")")
  end

  private

  def get_config_name_upcase(config_name)
    # need to also convert config names with spaces into underscore variants, right?
    config_name.clone.upcase.gsub(/ /,'_')
  end

  def set_property(target, property, value)
    puts_ind(@out, "set_property(TARGET #{target} PROPERTY #{property} \"#{value}\")")
  end
end

$vc8_prop_var_scan_regex = "\\$\\(([[:alnum:]_]+)\\)"
$vc8_prop_var_match_regex = "\\$\\([[:alnum:]_]+\\)"

$vc8_value_separator_regex = "[;,]"

def vc8_parse_file(project_name, file_xml, arr_sources)
  f = normalize_path(file_xml.attributes["RelativePath"])

  ## Ignore header files
  #return if f =~ /\.(h|H|lex|y|ico|bmp|txt)$/
  # No we should NOT ignore header files: if they aren't added to the target,
  # then VS won't display them in the file tree.
  return if f =~ /\.(lex|y|ico|bmp|txt)$/


  # Ignore files which have the ExcludedFromBuild attribute set to TRUE
  excluded_from_build = false
  file_xml.elements.each("FileConfiguration") { |file_config_xml|
    #file_config.elements.each('Tool[@Name="VCCLCompilerTool"]') { |compiler_xml|
    #  if compiler_xml.attributes["UsePrecompiledHeader"]
    #}
    excl_build = file_config_xml.attributes["ExcludedFromBuild"]
    if not excl_build.nil? and excl_build.downcase == "true"
      excluded_from_build = true
      return # no complex handling, just return
    end
  }

  # Ignore files with custom build steps
  included_in_build = true
  file_xml.elements.each("FileConfiguration/Tool") { |tool_xml|
    if tool_xml.attributes["Name"] == "VCCustomBuildTool"
      included_in_build = false
      return # no complex handling, just return
    end
  }

  # Verbosely ignore IDL generated files
  if f =~/_(i|p).c$/
    # see file_mappings.txt comment above
    puts_info "#{project_name}::#{f} is an IDL generated file: skipping! FIXME: should be platform-dependent."
    included_in_build = false
    return # no complex handling, just return
  end

  # Verbosely ignore .lib "sources"
  if f =~ /\.lib$/
    # probably these entries are supposed to serve as dependencies
    # (i.e., non-link header-only include dependency, to ensure
    # rebuilds in case of foreign-library header file changes).
    # Not sure whether these were added by users or
    # it's actually some standard MSVS mechanism... FIXME
    puts_info "#{project_name}::#{f} registered as a \"source\" file!? Skipping!"
    included_in_build = false
    return # no complex handling, just return
  end

  if not excluded_from_build and included_in_build
    if $v2c_validate_vcproj_ensure_files_ok
      # TODO: perhaps we need to add a permissions check, too?
      if not File.exist?("#{$project_dir}/#{f}")
        puts_error "File #{f} as listed in project #{project_name} does not exist!? (perhaps filename with wrong case, or wrong path, ...)"
        if $v2c_validate_vcproj_abort_on_error > 0
          puts_fatal "Improper original file - will abort and NOT write a broken CMakeLists.txt. Please fix .vcproj content!"
        end
      end
    end
    arr_sources.push(f)
    if not $have_build_units
      if f =~ /\.(c|C)/
        $have_build_units = true
      end
    end
  end
end

Files_str = Struct.new(:name, :arr_sub_filters, :arr_files)

def vc8_get_config_name(config_xml)
  config_xml.attributes["Name"].split("|")[0]
end

def vc8_get_configuration_types(project_xml, configuration_types)
  project_xml.elements.each("Configurations/Configuration") { |config_xml|
    config_name = vc8_get_config_name(config_xml)
    configuration_types.push(config_name)
  }
end

def vc8_parse_file_list(project_name, vcproj_filter, files_str)
  file_group_name = vcproj_filter.attributes["Name"]
  if file_group_name.nil?
    file_group_name = "COMMON"
  end
  files_str[:name] = file_group_name
  puts_debug "parsing files group #{files_str[:name]}"

  vcproj_filter.elements.each("Filter") { |subfilter|
    # skip file filters that have a SourceControlFiles property
    # that's set to false, i.e. files which aren't under version
    # control (such as IDL generated files).
    # This experimental check might be a little rough after all...
    # yes, FIXME: on Win32, these files likely _should_ get listed
    # after all. We should probably do a platform check in such
    # cases, i.e. add support for a file_mappings.txt
    attr_scfiles = subfilter.attributes["SourceControlFiles"]
    if not attr_scfiles.nil? and attr_scfiles.downcase == "false"
      puts_info "#{files_str[:name]}: SourceControlFiles set to false, listing generated files? --> skipping!"
      next
    end
    attr_scname = subfilter.attributes["Name"]
    if not attr_scname.nil? and attr_scname == "Generated Files"
      # Hmm, how are we supposed to handle Generated Files?
      # Most likely we _are_ supposed to add such files
      # and set_property(SOURCE ... GENERATED) on it.
      puts_info "#{files_str[:name]}: encountered a filter named Generated Files --> skipping! (FIXME)"
      next
    end
    # TODO: fetch filter regex if available, then have it generated as source_group(REGULAR_EXPRESSION "regex" ...).
    # attr_filter_regex = subfilter.attributes["Filter"]
    if files_str[:arr_sub_filters].nil?
      files_str[:arr_sub_filters] = Array.new
    end
    subfiles_str = Files_str.new
    files_str[:arr_sub_filters].push(subfiles_str)
    vc8_parse_file_list(project_name, subfilter, subfiles_str)
  }

  arr_sources = Array.new
  vcproj_filter.elements.each("File") { |file_xml|
    vc8_parse_file(project_name, file_xml, arr_sources)
  } # |file|

  if not arr_sources.empty?
    files_str[:arr_files] = arr_sources
  end
end

# See also
# "How to: Use Environment Variables in a Build"
#   http://msdn.microsoft.com/en-us/library/ms171459.aspx
# "Macros for Build Commands and Properties"
#   http://msdn.microsoft.com/en-us/library/c02as0cs%28v=vs.71%29.aspx
def vc8_handle_config_variables(str, arr_config_var_handling)
  # http://langref.org/all-languages/pattern-matching/searching/loop-through-a-string-matching-a-regex-and-performing-an-action-for-each-match
  str_scan_copy = str.dup # create a deep copy of string, to avoid "`scan': string modified (RuntimeError)"
  str_scan_copy.scan(/#{$vc8_prop_var_scan_regex}/) {
    config_var = $1
    # MSVS Property / Environment variables are documented to be case-insensitive,
    # thus implement insensitive match:
    config_var_upcase = config_var.upcase
    config_var_replacement = ""
    case config_var_upcase
      when /CONFIGURATIONNAME/
      	config_var_replacement = "${CMAKE_CFG_INTDIR}"
      when /PLATFORMNAME/
        config_var_emulation_code = <<EOF
  if(NOT v2c_VS_PlatformName)
    if(CMAKE_CL_64)
      set(v2c_VS_PlatformName "x64")
    else(CMAKE_CL_64)
      if(WIN32)
        set(v2c_VS_PlatformName "Win32")
      endif(WIN32)
    endif(CMAKE_CL_64)
  endif(NOT v2c_VS_PlatformName)
EOF
        arr_config_var_handling.push(config_var_emulation_code)
	config_var_replacement = "${v2c_VS_PlatformName}"
        # InputName is said to be same as ProjectName in case input is the project.
      when /INPUTNAME|PROJECTNAME/
      	config_var_replacement = "${PROJECT_NAME}"
        # See ProjectPath reasoning below.
      when /INPUTFILENAME|PROJECTFILENAME/
        # config_var_replacement = "${PROJECT_NAME}.vcproj"
	config_var_replacement = "${v2c_VS_#{config_var}}"
      when /OUTDIR/
        # FIXME: should extend code to do executable/library/... checks
        # and assign CMAKE_LIBRARY_OUTPUT_DIRECTORY / CMAKE_RUNTIME_OUTPUT_DIRECTORY
        # depending on this.
        config_var_emulation_code = <<EOF
  set(v2c_CS_OutDir "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
EOF
	config_var_replacement = "${v2c_VS_OutDir}"
      when /PROJECTDIR/
	config_var_replacement = "${PROJECT_SOURCE_DIR}"
      when /PROJECTPATH/
        # ProjectPath emulation probably doesn't make much sense,
        # since it's a direct path to the MSVS-specific .vcproj file
        # (redirecting to CMakeLists.txt file likely isn't correct/useful).
	config_var_replacement = "${v2c_VS_ProjectPath}"
      when /SOLUTIONDIR/
        # Probability of SolutionDir being identical to CMAKE_SOURCE_DIR
	# (i.e. the source root dir) ought to be strongly approaching 100%.
	config_var_replacement = "${CMAKE_SOURCE_DIR}"
      when /TARGETPATH/
        config_var_emulation_code = ""
        arr_config_var_handling.push(config_var_emulation_code)
	config_var_replacement = "${v2c_VS_TargetPath}"
      else
        # FIXME: for unknown variables, we need to provide CMake code which derives the
	# value from the environment ($ENV{VAR}), since AFAIR these MSVS Config Variables will
	# get defined via environment variable, via a certain ordering (project setting overrides
	# env var, or some such).
	# TODO: In fact we should probably provide support for a property_var_mappings.txt file -
	# a variable that's relevant here would e.g. be QTDIR (an entry in that file should map
	# it to QT_INCLUDE_DIR or some such, for ready perusal by a find_package(Qt4) done by a hook script).
	# WARNING: note that _all_ existing variable syntax elements need to be sanitized into
	# CMake-compatible syntax, otherwise they'll end up verbatim in generated build files,
	# which may confuse build systems (make doesn't care, but Ninja goes kerB00M).
        puts_warn "Unknown/user-custom config variable name #{config_var} encountered in line '#{str}' --> TODO?"

        #str.gsub!(/\$\(#{config_var}\)/, "${v2c_VS_#{config_var}}")
	# For now, at least better directly reroute from environment variables:
	config_var_replacement = "$ENV{#{config_var}}"
      end
      if config_var_replacement != ""
        puts_info "Replacing MSVS configuration variable $(#{config_var}) by #{config_var_replacement}."
        str.gsub!(/\$\(#{config_var}\)/, config_var_replacement)
      end
  }

  #puts_info "str is now #{str}"
  return str
end

################
#     MAIN     #
################

# write into temporary file, to avoid corrupting previous CMakeLists.txt due to disk space or failure issues
tmpfile = Tempfile.new('vcproj2cmake')

File.open(tmpfile.path, "w") { |out|

  $global_generator = V2C_CMakeGlobalGenerator.new(out)

  $global_generator.put_file_header()

  File.open(vcproj_filename) { |io|
    parser_base = V2C_BaseVCProjGlobalParser.new

    doc = REXML::Document.new io

    arr_config_var_handling = Array.new

    syntax_generator = V2C_CMakeSyntaxGenerator.new(out)

    doc.elements.each("VisualStudioProject") { |project_xml|

      # HACK: for now, have one global instance of the local generator
      local_generator = V2C_CMakeLocalGenerator.new(out)

      target = V2C_Target.new

      target.name = project_xml.attributes["Name"]
      target.vs_keyword = project_xml.attributes["Keyword"]

      # we can handle the following target stuff outside per-config handling (reason: see comment above)
      scc_info = V2C_SCC_Info.new
      if not project_xml.attributes["SccProjectName"].nil?
        scc_info.project_name = project_xml.attributes["SccProjectName"].clone
        # hrmm, turns out having SccProjectName is no guarantee that both SccLocalPath and SccProvider
        # exist, too... (one project had SccProvider missing)
        if not project_xml.attributes["SccLocalPath"].nil?
          scc_info.local_path = project_xml.attributes["SccLocalPath"].clone
        end
        if not project_xml.attributes["SccProvider"].nil?
          scc_info.provider = project_xml.attributes["SccProvider"].clone
        end
      end

      $have_build_units = false

      configuration_types = Array.new
      vc8_get_configuration_types(project_xml, configuration_types)

      main_files = Files_str.new
      project_xml.elements.each("Files") { |files|
      	vc8_parse_file_list(target.name, files, main_files)
      }

      # we likely shouldn't declare this, since for single-configuration
      # generators CMAKE_CONFIGURATION_TYPES shouldn't be set
      ## configuration types need to be stated _before_ declaring the project()!
      #out.puts
      #$global_generator.put_configuration_types(configuration_types)

      $global_generator.put_project(target.name)

      ## sub projects will inherit, and we _don't_ want that...
      # DISABLED: now to be done by MasterProjectDefaults_vcproj2cmake module if needed
      #puts_ind(out, "# reset project-local variables")
      #puts_ind(out, "set( V2C_LIBS )")
      #puts_ind(out, "set( V2C_SOURCES )")

      $global_generator.put_include_MasterProjectDefaults_vcproj2cmake()

      $global_generator.put_hook_project()

      # HACK: for now, have one global instance of the target generator
      $target_generator = V2C_CMakeTargetGenerator.new(target, local_generator, out)

      arr_sub_sources = Array.new
      $target_generator.put_file_list(target.name, main_files, nil, arr_sub_sources)

      if not arr_sub_sources.empty?
        # add a ${V2C_SOURCES} variable to the list, to be able to append
        # all sorts of (auto-generated, ...) files to this list within
        # hook includes, _right before_ creating the target with its sources.
        arr_sub_sources.push("V2C_SOURCES")
      else
        puts_warn "#{target.name}: no source files at all!? (header-based project?)"
      end

      $global_generator.put_include_project_source_dir()

      $global_generator.put_hook_post_sources()

      # ARGH, we have an issue with CMake not being fully up to speed with
      # multi-configuration generators (e.g. .vcproj):
      # it should be able to declare _all_ configuration-dependent settings
      # in a .vcproj file as configuration-dependent variables
      # (just like set_property(... COMPILE_DEFINITIONS_DEBUG ...)),
      # but with configuration-specific(!) include directories on .vcproj side,
      # there's currently only a _generic_ include_directories() command :-(
      # (dito with target_link_libraries() - or are we supposed to create an imported
      # target for each dependency, for more precise configuration-specific library names??)
      # Thus we should specifically specify include_directories() where we can
      # discern the configuration type (in single-configuration generators using
      # CMAKE_BUILD_TYPE) and - in the case of multi-config generators - pray
      # that the authoritative configuration has an AdditionalIncludeDirectories setting
      # that matches that of all other configs, since we're unable to specify
      # it in a configuration-specific way :(

      if config_multi_authoritative.empty?
	project_configuration_first_xml = project_xml.elements["Configurations/Configuration"].next_element
	if not project_configuration_first_xml.nil?
          config_multi_authoritative = vc8_get_config_name(project_configuration_first_xml)
	end
      end

      # target type (library, executable, ...) in .vcproj can be configured per-config
      # (or, in other words, different configs are capable of generating _different_ target _types_
      # for the _same_ target), but in CMake this isn't possible since _one_ target name
      # maps to _one_ target type and we _need_ to restrict ourselves to using the project name
      # as the exact target name (we are unable to define separate PROJ_lib and PROJ_exe target names,
      # since other .vcproj file contents always link to our target via the main project name only!!).
      # Thus we need to declare the target variable _outside_ the scope of per-config handling :(
      target_name = nil

      project_xml.elements.each("Configurations/Configuration") { |config_xml|
        config_name = vc8_get_config_name(config_xml)

	build_type_condition = ""
	if config_multi_authoritative == config_name
	  build_type_condition = "CMAKE_CONFIGURATION_TYPES OR CMAKE_BUILD_TYPE STREQUAL \"#{config_name}\""
	else
	  # YES, this condition is supposed to NOT trigger in case of a multi-configuration generator
	  build_type_condition = "CMAKE_BUILD_TYPE STREQUAL \"#{config_name}\""
	end

	syntax_generator.write_empty_line()
	syntax_generator.write_conditional_begin(build_type_condition)

	config_info = V2C_Config_Info.new

        config_info.type = config_xml.attributes["ConfigurationType"].to_i

        # 0 == no MFC
        # 1 == static MFC
        # 2 == shared MFC
	# FUTURE NOTE: MSVS7 has UseOfMFC, MSVS10 has UseOfMfc (see CMake MSVS generators)
	# --> we probably should _not_ switch to case insensitive matching on
	# attributes (see e.g.
	# http://fossplanet.com/f14/rexml-translate-xpath-28868/ ),
	# but rather implement version-specific parser classes due to
	# the differing XML configurations
	# (e.g. do this via a common base class, then add derived ones
	# to implement any differences).
        config_info.use_of_mfc = config_xml.attributes["UseOfMFC"].to_i
        config_info.use_of_atl = config_xml.attributes["UseOfATL"].to_i

	$global_generator.put_cmake_mfc_atl_flag(config_info)

        hash_defines = Hash.new
        arr_flags = Array.new
        config_xml.elements.each('Tool[@Name="VCCLCompilerTool"]') { |compiler_xml|
          attr_incdir = compiler_xml.attributes["AdditionalIncludeDirectories"]
          attr_defines = compiler_xml.attributes["PreprocessorDefinitions"]
          attr_opts = compiler_xml.attributes["AdditionalOptions"]

	  if not attr_incdir.nil?
            arr_includes = Array.new
            include_dirs = attr_incdir.split(/#{$vc8_value_separator_regex}/).sort.each { |elem_inc_dir|
                elem_inc_dir = normalize_path(elem_inc_dir).strip
		elem_inc_dir = vc8_handle_config_variables(elem_inc_dir, arr_config_var_handling)
                #puts_info "include is '#{elem_inc_dir}'"
                arr_includes.push(elem_inc_dir)
            }
            local_generator.write_build_attributes("include_directories", "", arr_includes, parser_base.map_includes, nil)
          end

	  if not attr_defines.nil?
            attr_defines.split(/#{$vc8_value_separator_regex}/).each { |elem_define|
              str_define_key, str_define_value = elem_define.strip.split(/=/)
	      # Since a Hash will indicate nil for any non-existing key,
	      # we do need to fill in _empty_ value for our _existing_ key.
              if str_define_value.nil?
		str_define_value = ""
              end
              hash_defines[str_define_key] = str_define_value
            }
          end

	  # Oh well, we might eventually want to provide a full-scale
	  # translation of various compiler switches to their
	  # counterparts on compilers of various platforms, but for
	  # now, let's simply directly pass them on to the compiler on the
	  # Win32 side.
	  if not attr_opts.nil?
	     local_generator.write_directory_property_compile_flags(attr_opts)

	    # TODO: add translation table for specific compiler flag settings such as MinimalRebuild:
	    # simply make reverse use of existing translation table in CMake source.
	    # FIXME: Aww crap, that AdditionalOptions handling part here is actually a _duplicate_
	    # of the part above, if not for the fact that it will end up as target- rather
	    # than directory-related property. This needs to be resolved eventually,
	    # but for now we'll just keep it like this until we have isolated parser/generator classes.
	    # At least I now moved it into the same section which already handles the same thing above:
	    arr_flags = attr_opts.split(";")
          end
        }

	# FIXME: hohumm, the position of this hook include is outdated, need to update it
	$global_generator.put_hook_post_definitions()

        # create a target only in case we do have any meat at all
        #if not main_files[:arr_sub_filters].empty? or not main_files[:arr_files].empty?
        #if not arr_sub_sources.empty?
        if $have_build_units

          # first add source reference, then do linker setup, then create target

	  $target_generator.put_sources(arr_sub_sources)

	  # parse linker configuration...
          arr_dependencies = Array.new
	  arr_lib_dirs = Array.new
          config_xml.elements.each('Tool[@Name="VCLinkerTool"]') { |linker_xml|
            attr_deps = linker_xml.attributes["AdditionalDependencies"]
            if attr_deps and attr_deps.length > 0
              attr_deps.split.each { |elem_lib_dep|
                elem_lib_dep = normalize_path(elem_lib_dep).strip
                arr_dependencies.push(File.basename(elem_lib_dep, ".lib"))
              }
            end

            attr_lib_dirs = linker_xml.attributes["AdditionalLibraryDirectories"]
            if attr_lib_dirs and attr_lib_dirs.length > 0
              attr_lib_dirs.split(/#{$vc8_value_separator_regex}/).each { |elem_lib_dir|
                elem_lib_dir = normalize_path(elem_lib_dir).strip
		  # FIXME: handle arr_config_var_handling appropriately.
		elem_lib_dir = vc8_handle_config_variables(elem_lib_dir, arr_config_var_handling)
		#puts_info "lib dir is '#{elem_lib_dir}'"
                arr_lib_dirs.push(elem_lib_dir)
              }
            end
	    # TODO: support AdditionalOptions! (mention via
	    # CMAKE_SHARED_LINKER_FLAGS / CMAKE_MODULE_LINKER_FLAGS / CMAKE_EXE_LINKER_FLAGS
	    # depending on target type, and make sure to filter out options pre-defined by CMake platform
	    # setup modules)
          }

	  # write link_directories() (BEFORE establishing a target!)
          arr_lib_dirs.push("${V2C_LIB_DIRS}")

          map_lib_dirs = Hash.new
          read_mappings_combined($filename_map_lib_dirs, map_lib_dirs)
	  local_generator.write_link_directories(arr_lib_dirs, map_lib_dirs)

          # FIXME: should use a macro like rosbuild_add_executable(),
          # http://www.ros.org/wiki/rosbuild/CMakeLists ,
          # https://kermit.cse.wustl.edu/project/robotics/browser/trunk/vendor/ros/core/rosbuild/rosbuild.cmake?rev=3
          # to be able to detect non-C++ file types within a source file list
          # and add a hook to handle them specially.

          # see VCProjectEngine ConfigurationTypes enumeration
    	  case config_info.type
          when 1       # typeApplication (.exe)
            target_name = target.name
            #puts_ind(out, "add_executable_vcproj2cmake( #{target.name} WIN32 ${SOURCES} )")
            # TODO: perhaps for real cross-platform binaries (i.e.
            # console apps not needing a WinMain()), we should detect
            # this and not use WIN32 in this case...
	    # Well, this probably is related to the .vcproj Keyword attribute ("Win32Proj", "MFCProj", "ATLProj", "MakeFileProj" etc.).
            new_puts_ind(out, "add_executable( #{target.name} WIN32 ${SOURCES} )")
          when 2    # typeDynamicLibrary (.dll)
            target_name = target.name
            #puts_ind(out, "add_library_vcproj2cmake( #{target.name} SHARED ${SOURCES} )")
            # add_library() docs: "If no type is given explicitly the type is STATIC or  SHARED
            #                      based on whether the current value of the variable
            #                      BUILD_SHARED_LIBS is true."
            # --> Thus we would like to leave it unspecified for typeDynamicLibrary,
            #     and do specify STATIC for explicitly typeStaticLibrary targets.
            # However, since then the global BUILD_SHARED_LIBS variable comes into play,
            # this is a backwards-incompatible change, thus leave it for now.
            # Or perhaps make use of new V2C_TARGET_LINKAGE_{SHARED|STATIC}_LIB
            # variables here, to be able to define "SHARED"/"STATIC" externally?
            new_puts_ind(out, "add_library( #{target.name} SHARED ${SOURCES} )")
          when 4    # typeStaticLibrary
            target_name = target.name
            #puts_ind(out, "add_library_vcproj2cmake( #{target.name} STATIC ${SOURCES} )")
            new_puts_ind(out, "add_library( #{target.name} STATIC ${SOURCES} )")
          when 0    # typeUnknown (utility)
            puts_warn "Project type 0 (typeUnknown - utility) is a _custom command_ type and thus probably cannot be supported easily. We will not abort and thus do write out a file, but it probably needs fixup (hook scripts?) to work properly. If this project type happens to use VCNMakeTool tool, then I would suggest to examine BuildCommandLine/ReBuildCommandLine/CleanCommandLine attributes for clues on how to proceed."
	  else
          #when 10    # typeGeneric (Makefile) [and possibly other things...]
            # TODO: we _should_ somehow support these project types...
            puts_fatal "Project type #{config_info.type} not supported."
          end

	  # write target_link_libraries() in case there's a valid target
          if not target_name.nil?
            arr_dependencies.push("${V2C_LIBS}")

            map_dependencies = Hash.new
            read_mappings_combined($filename_map_dep, map_dependencies)
	    $target_generator.write_link_libraries(arr_dependencies, map_dependencies)
          end # not target_name.nil?
        end # not arr_sub_sources.empty?

	$global_generator.put_hook_post_target()

	syntax_generator.write_conditional_end(build_type_condition)

        # NOTE: the commands below can stay in the general section (outside of
        # build_type_condition above), but only since they define
        # configuration-_specific_ settings only!
        if not target_name.nil?
          if config_info.use_of_mfc == 2
            hash_defines["_AFXEXT"] = ""
	    hash_defines["_AFXDLL"] = ""
          end

          map_defines = Hash.new
          read_mappings_combined($filename_map_def, map_defines)
	  syntax_generator.write_conditional_begin("TARGET #{target_name}")
          $target_generator.write_property_compile_definitions(config_name, hash_defines, map_defines)
    	  # Original compiler flags are MSVC-only, of course. TODO: provide an automatic conversion towards gcc?
          $target_generator.write_property_compile_flags(config_name, arr_flags, "MSVC")
	  syntax_generator.write_conditional_end("TARGET #{target_name}")
        end
      } # [END per-config handling]

      if not target_name.nil?
	$target_generator.set_properties_vs_scc(scc_info)

        # TODO: might want to set a target's FOLDER property, too...
        # (and perhaps a .vcproj has a corresponding attribute
        # which indicates that?)

        # TODO: perhaps there are useful Xcode (XCODE_ATTRIBUTE_*) properties to convert?
      end # not target_name.nil?

      $global_generator.put_var_converter_script_location(script_location_relative_to_master)
      local_generator.write_func_v2c_post_setup(target.name, target.vs_keyword, p_vcproj.basename)
    }
  }
  # Close file, since Fileutils.mv on an open file will barf on XP
  out.close
}

# make sure to close that one as well...
tmpfile.close

# Since we're forced to fumble our source tree (a definite no-no in all other cases!)
# by writing our CMakeLists.txt there, use a write-back-when-updated approach
# to make sure we only write back the live CMakeLists.txt in case anything did change.
# This is especially important in case of multiple concurrent builds on a shared
# source on NFS mount.

configuration_changed = false
have_old_file = false
if File.exists?(output_file)
  have_old_file = true
  if not V2C_Util_File.cmp(tmpfile.path, output_file)
    configuration_changed = true
  end
else
  configuration_changed = true
end

if configuration_changed
  if have_old_file
    # move away old file
    V2C_Util_File.mv(output_file, output_file + ".previous")
  end
  # activate our version
  # [for chmod() comments, see our $v2c_cmakelists_create_permissions settings variable]
  V2C_Util_File.chmod($v2c_cmakelists_create_permissions, tmpfile.path)
  V2C_Util_File.mv(tmpfile.path, output_file)

  puts_info %{\
Wrote #{output_file}
Finished. You should make sure to have all important v2c settings includes such as vcproj2cmake_defs.cmake somewhere in your CMAKE_MODULE_PATH
}
else
  puts_info "No settings changed, #{output_file} not updated."
  # tmpfile will auto-delete when finalized...

  # Some make dependency mechanisms might require touching (timestamping) the unchanged(!) file
  # to indicate that it's up-to-date,
  # however we won't do this here since it's not such a good idea.
  # Any user who needs that should do a manual touch subsequently.
end
