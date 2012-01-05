#!/usr/bin/env ruby

# Given a Visual Studio project, create a CMakeLists.txt file which optionally
# allows for ongoing side-by-side operation (e.g. on Linux, Mac)
# together with the existing static .vcproj project on the Windows side.
# Provides good support for simple DLL/Static/Executable projects,
# but custom build steps and build events are currently ignored.

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
# fully working almost completely _self-contained_ CMakeLists.txt,
# no matter how small the current vcproj2cmake config environment is
# (i.e., it needs to work even without a single specification file
# other than vcproj2cmake_func.cmake)
#
# Useful check: use different versions of this project, then diff resulting
# changes in generated CMakeLists.txt content - this should provide a nice
# opportunity to spot bugs which crept in from version to version.
#
# Tracing (ltrace -s255 -S -tt -f ruby) reveals that overall execution time
# of this script horribly dwarfs ruby startup time (0.3s vs. 1.9s, on 1.8.7).
# IOW, there's nothing much we can do, other than increasing efforts to integrate
# vcproj2cmake_recursive.rb here, too
# (which should eventually be done for .sln Global / Local generator reasons anyway),
# to eliminate a huge number of wasteful Ruby startups.

# TODO:
# - perhaps there's a way to provide more precise/comfortable hook script handling?
# - should finish clean separation of .vcproj content parsing and .vcproj output
#   generation (e.g. in preparation for .vcxproj support)
#   We now have .vcproj parser class(es) which work on a
#   common parser support base class, get fed a vcproj configuration class
#   (well, build cfg, actually), configure that class.
#   We then push it (with the .vcproj-gathered settings it contains)
#   over to a CMake generator class.
# - possibly add parser or generator functionality
#   for build systems other than .vcproj/.vcxproj/CMake? :)
# - try to come up with an ingenious way to near-_automatically_ handle
#   those pesky repeated dependency requirements of several sub projects
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
   str_vcproj_filename = ARGV.shift
   #puts "First arg is #{str_vcproj_filename}"

   # Discovered Ruby 1.8.7(?) BUG: kills extension on duplicate slashes: ".//test.ext"
   # OK: ruby-1.8.5-5.el5_4.8, KO: u10.04 ruby1.8 1.8.7.249-2 and ruby1.9.1 1.9.1.378-1
   # http://redmine.ruby-lang.org/issues/show/3882
   # TODO: add a version check to conditionally skip this cleanup effort?
   vcproj_filename = Pathname.new(str_vcproj_filename).cleanpath

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

# global variable to indicate whether we want debug output or not
$debug = false

# Initial number of spaces for indenting
$indent_num_spaces = 0

# Number of spaces to increment by
$indent_step = 2

# since the .vcproj multi-configuration environment has some settings
# that can be specified per-configuration (target type [lib/exe], include directories)
# but where CMake unfortunately does _NOT_ offer a configuration-specific equivalent,
# we need to fall back to using the globally-scoped CMake commands (include_directories() etc.).
# But at least let's optionally allow the user to precisely specify which configuration
# (empty [first config], "Debug", "Release", ...) he wants to have
# these settings taken from.
$config_multi_authoritative = ""

$filename_map_def = "#{$v2c_config_dir_local}/define_mappings.txt"
$filename_map_dep = "#{$v2c_config_dir_local}/dependency_mappings.txt"
$filename_map_lib_dirs = "#{$v2c_config_dir_local}/lib_dirs_mappings.txt"

### USER-CONFIGURABLE SECTION END ###


master_project_location = File.expand_path($master_project_dir)
p_master_proj = Pathname.new(master_project_location)

p_vcproj = Pathname.new(vcproj_filename)
# figure out a global project_dir variable from the .vcproj location
$project_dir = p_vcproj.dirname

#p_project_dir = Pathname.new($project_dir)
#p_cmakelists = Pathname.new(output_file)
#cmakelists_dir = p_cmakelists.dirname
#p_cmakelists_dir = Pathname.new(cmakelists_dir)
#p_cmakelists_dir.relative_path_from(...)

script_location = File.expand_path(script_name)
p_script = Pathname.new(script_location)
$script_location_relative_to_master = p_script.relative_path_from(p_master_proj)
#puts "p_script #{p_script} | p_master_proj #{p_master_proj} | $script_location_relative_to_master #{$script_location_relative_to_master}"

# monster HACK: set a global variable, since we need to be able
# to tell whether we're able to build a target
# (i.e. whether we have any build units i.e.
# implementation files / non-header files),
# otherwise we should not add a target since CMake will
# complain with "Cannot determine link language for target "xxx"".
$have_build_units = false



$indent_now = $indent_num_spaces

def cmake_indent_more
  $indent_now += $indent_step
end

def cmake_indent_less
  $indent_now -= $indent_step
end

def log_debug(str)
  if $debug
    puts str
  end
end

def log_info(str)
  # We choose to not log an INFO: prefix (reduce log spew).
  puts str
end

def log_warn(str)
  puts "WARNING: #{str}"
end

def log_error(str)
  $stderr.puts "ERROR: #{str}"
end

def log_fatal(str)
  log_error "#{str}. Aborting!"
  exit 1
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
    log_debug "NOTE: #{filename_mappings} NOT AVAILABLE"
  end
  #log_debug mappings["kernel32"]
  #log_debug mappings["mytest"]
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
  #log_debug "adding #{defn_value} on platform #{platform}"
  if platform_defs[platform].nil?
    platform_defs[platform] = Array.new
  end
  platform_defs[platform].push(defn_value)
end

def parse_platform_conversions(platform_defs, arr_defs, map_defs)
  arr_defs.each { |curr_defn|
    #log_debug map_defs[curr_defn]
    map_line = map_defs[curr_defn]
    if map_line.nil?
      # hmm, no direct match! Try to figure out whether any map entry
      # is a regex which would match our curr_defn
      map_defs.each do |key, value|
        if curr_defn =~ /^#{key}$/
          log_debug "KEY: #{key} curr_defn #{curr_defn}"
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
        #log_debug "platform_element #{platform_element}"
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

# IMPORTANT NOTE: the generator/target/parser class hierarchy and _naming_
# is supposed to be eerily similar to the one used by CMake.
# Dito for naming of individual methods...
#
# Global generator: generates/manages parts which are not project-local/target-related
# local generator: has a Makefile member (which contains a list of targets),
#   then generates project files by iterating over the targets via a newly generated target generator each.
# target generator: generates targets. This is the one creating/producing the output file stream. Not provided by all generators (VS10 yes, VS7 no).


class V2C_Compiler_Info
  def initialize
    @arr_flags = Array.new
    @arr_includes = Array.new
    @hash_defines = Hash.new
  end
  attr_accessor :arr_flags
  attr_accessor :arr_includes
  attr_accessor :hash_defines
end

class V2C_Linker_Info
  def initialize
    @arr_dependencies = Array.new
    @arr_lib_dirs = Array.new
  end
  attr_accessor :arr_dependencies
  attr_accessor :arr_lib_dirs
end

class V2C_Config_Info
  def initialize
    @name = 0
    @type = 0
    @use_of_mfc = 0
    @use_of_atl = 0
    @arr_compiler_info = Array.new
    @arr_linker_info = Array.new
  end
  attr_accessor :name
  attr_accessor :type
  attr_accessor :use_of_mfc
  attr_accessor :use_of_atl
  attr_accessor :arr_compiler_info
  attr_accessor :arr_linker_info
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
    @aux_path = nil
  end

  attr_accessor :project_name
  attr_accessor :local_path
  attr_accessor :provider
  attr_accessor :aux_path
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

class V2C_BaseGlobalGenerator
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


### internal CMake generator helpers ###
$vcproj2cmake_func_cmake = "vcproj2cmake_func.cmake"
$v2c_attribute_not_provided_marker = "V2C_NOT_PROVIDED"

$cmake_var_match_regex = "\\$\\{[[:alnum:]_]+\\}"
$cmake_env_var_match_regex = "\\$ENV\\{[[:alnum:]_]+\\}"

class V2C_CMakeSyntaxGenerator
  def initialize(out)
    @out = out
  end

  def generated_comments_level
    return $v2c_generated_comments_level
  end

  def write_comment_at_level(level, block)
    if generated_comments_level() >= level
      block.split("\n").each { |line|
	write_line("# #{line}")
      }
    end
  end

  def write_block(block)
    block.split("\n").each { |line|
      write_line(line)
    }
  end
  def write_line(part)
    @out.print ' ' * $indent_now
    @out.puts part
  end

  def write_empty_line
    @out.puts
  end
  def write_new_line(part)
    write_empty_line()
    write_line(part)
  end

  # WIN32, MSVC, ...
  def write_conditional_if(str_conditional)
    if not str_conditional.nil?
      write_line("if(#{str_conditional})")
      cmake_indent_more()
    end
  end
  def write_conditional_else(str_conditional)
    if not str_conditional.nil?
      cmake_indent_less()
      write_line("else(#{str_conditional})")
      cmake_indent_more()
    end
  end
  def write_conditional_end(str_conditional)
    if not str_conditional.nil?
      cmake_indent_less()
      write_line("endif(#{str_conditional})")
    end
  end
  def get_keyword_bool(setting)
    return setting ? "true" : "false"
  end
  def write_var_bool(var_name, setting)
    str_setting = get_keyword_bool(setting)
    write_line("set(#{var_name} #{str_setting})")
  end
  def write_var_bool_conditional(var_name, str_condition)
    write_conditional_if(str_condition)
      write_var_bool(var_name, true)
    write_conditional_else(str_condition)
      write_var_bool(var_name, false)
    write_conditional_end(str_condition)
  end
  def write_vcproj2cmake_func_comment()
    write_comment_at_level(2, "See function implementation/docs in #{$v2c_module_path_root}/#{$vcproj2cmake_func_cmake}")
  end
  def write_cmake_policy(policy_num, set_to_new, comment)
    str_policy = "%s%04d" % [ "CMP", policy_num ]
    str_conditional = "POLICY #{str_policy}"
    str_OLD_NEW = set_to_new ? "NEW" : "OLD"
    write_conditional_if(str_conditional)
      if not comment.nil?
        write_comment_at_level(3, comment)
      end
      write_line("cmake_policy(SET #{str_policy} #{str_OLD_NEW})")
    write_conditional_end(str_conditional)
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
    write_new_line("project(#{project_name})")
  end
  def put_cmake_mfc_atl_flag(config_info)
    # Hmm, do we need to actively _reset_ CMAKE_MFC_FLAG / CMAKE_ATL_FLAG
    # (i.e. _unconditionally_ set() it, even if it's 0),
    # since projects in subdirs shouldn't inherit?
    # Given the discussion at
    # "[CMake] CMAKE_MFC_FLAG is inherited in subdirectory ?"
    #   http://www.cmake.org/pipermail/cmake/2009-February/026896.html
    # I'd strongly assume yes...

    #if config_info.use_of_mfc > 0
      write_new_line("set(CMAKE_MFC_FLAG #{config_info.use_of_mfc})")
    #end
    # ok, there's no CMAKE_ATL_FLAG yet, AFAIK, but still prepare
    # for it (also to let people probe on this in hook includes)
    #if config_info.use_of_atl > 0
      # TODO: should also set the per-configuration-type variable variant
      #write_new_line("set(CMAKE_ATL_FLAG #{config_info.use_of_atl})")
      write_line("set(CMAKE_ATL_FLAG #{config_info.use_of_atl})")
    #end
  end
  def put_hook_pre
    # this CMakeLists.txt-global optional include could be used e.g.
    # to skip the entire build of this file on certain platforms:
    # if(PLATFORM) message(STATUS "not supported") return() ...
    # (note that we appended CMAKE_MODULE_PATH _prior_ to this include()!)
    write_new_line("include(\"${V2C_CONFIG_DIR_LOCAL}/hook_pre.txt\" OPTIONAL)")
  end
  def put_hook_project
    write_comment_at_level(2, \
	"hook e.g. for invoking Find scripts as expected by\n" \
	"the _LIBRARIES / _INCLUDE_DIRS mappings created\n" \
	"by your include/dependency map files." \
    )
    write_line("include(\"${V2C_HOOK_PROJECT}\" OPTIONAL)")
  end
  def put_hook_post_definitions
    write_empty_line()
    write_comment_at_level(1, \
	"hook include after all definitions have been made\n" \
	"(but _before_ target is created using the source list!)" \
    )
    write_line("include(\"${V2C_HOOK_POST_DEFINITIONS}\" OPTIONAL)")
  end
  def put_hook_post_sources
    write_new_line("include(\"${V2C_HOOK_POST_SOURCES}\" OPTIONAL)")
  end
  def put_hook_post_target
    write_empty_line()
    write_comment_at_level(1, \
      "e.g. to be used for tweaking target properties etc." \
    )
    write_line("include(\"${V2C_HOOK_POST_TARGET}\" OPTIONAL)")
  end
  def put_include_project_source_dir
    # AFAIK .vcproj implicitly adds the project root to standard include path
    # (for automatic stdafx.h resolution etc.), thus add this
    # (and make sure to add it with high priority, i.e. use BEFORE).
    write_new_line("include_directories(BEFORE \"${PROJECT_SOURCE_DIR}\")")
  end
  def put_configuration_types(configuration_types)
    configuration_types_list = cmake_separate_arguments(configuration_types)
    write_line("set(CMAKE_CONFIGURATION_TYPES \"#{configuration_types_list}\")" )
  end
  def put_var_converter_script_location(script_location_relative_to_master)
    # For the CMakeLists.txt rebuilder (automatic rebuild on file changes),
    # add handling of a script file location variable, to enable users
    # to override the script location if needed.
    write_empty_line()
    write_comment_at_level(1, \
      "user override mechanism (allow defining custom location of script)" \
    )
    str_conditional = "NOT V2C_SCRIPT_LOCATION"
    write_conditional_if(str_conditional)
      # NOTE: we'll make V2C_SCRIPT_LOCATION express its path via
      # relative argument to global CMAKE_SOURCE_DIR and _not_ CMAKE_CURRENT_SOURCE_DIR,
      # (this provision should even enable people to manually relocate
      # an entire sub project within the source tree).
      write_line("set(V2C_SCRIPT_LOCATION \"${CMAKE_SOURCE_DIR}/#{script_location_relative_to_master}\")")
    write_conditional_end(str_conditional)
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
      write_block( \
	"# MasterProjectDefaults_vcproj2cmake is supposed to define generic settings\n" \
        "# (such as V2C_HOOK_PROJECT, defined as e.g.\n" \
        "# #{$v2c_config_dir_local}/hook_project.txt,\n" \
        "# and other hook include variables below).\n" \
        "# NOTE: it usually should also reset variables\n" \
        "# V2C_LIBS, V2C_SOURCES etc. as used below since they should contain\n" \
        "# directory-specific contents only, not accumulate!" \
      )
    end
    # (side note: see "ldd -u -r" on Linux for superfluous link parts potentially caused by this!)
    write_line("include(MasterProjectDefaults_vcproj2cmake OPTIONAL)")
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
    write_comment_at_level(1, \
      ">= 2.6 due to crucial set_property(... COMPILE_DEFINITIONS_* ...)" \
    )
    write_line("cmake_minimum_required(VERSION 2.6)")
  end
  def put_file_header_cmake_policies
    str_conditional = "COMMAND cmake_policy"
    write_conditional_if(str_conditional)
      # CMP0005: manual quoting of brackets in definitions doesn't seem to work otherwise,
      # in cmake 2.6.4-7.el5 with "OLD".
      write_cmake_policy(5, true, "automatic quoting of brackets")
      write_cmake_policy(11, false, \
	"we do want the includer to be affected by our updates,\n" \
        "since it might define project-global settings.\n" \
      )
      write_cmake_policy(15, true, \
        ".vcproj contains relative paths to additional library directories,\n" \
        "thus we need to be able to cope with that" \
      )
    write_conditional_end(str_conditional)
  end
  def put_cmake_module_path
    # try to point to cmake/Modules of the topmost directory of the vcproj2cmake conversion tree.
    # This also contains vcproj2cmake helper modules (these should - just like the CMakeLists.txt -
    # be within the project tree as well, since someone might want to copy the entire project tree
    # including .vcproj conversions to a different machine, thus all v2c components should be available)
    #write_new_line("set(V2C_MASTER_PROJECT_DIR \"#{$master_project_dir}\")")
    write_new_line("set(V2C_MASTER_PROJECT_DIR \"${CMAKE_SOURCE_DIR}\")")
    # NOTE: use set() instead of list(APPEND...) to _prepend_ path
    # (otherwise not able to provide proper _overrides_)
    write_line("set(CMAKE_MODULE_PATH \"${V2C_MASTER_PROJECT_DIR}/#{$v2c_module_path_local}\" ${CMAKE_MODULE_PATH})")
  end
  def put_var_config_dir_local
    # "export" our internal $v2c_config_dir_local variable (to be able to reference it in CMake scripts as well)
    write_new_line("set(V2C_CONFIG_DIR_LOCAL \"#{$v2c_config_dir_local}\")")
  end
  def put_include_vcproj2cmake_func
    write_empty_line()
    write_comment_at_level(2, \
      "include the main file for pre-defined vcproj2cmake helper functions\n" \
      "This module will also include the configuration settings definitions module" \
    )
    write_line("include(vcproj2cmake_func)")
  end
end

# analogous to CMake separate_arguments() command
def cmake_separate_arguments(array_in)
  array_in.join(";")
end

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
  # For details, see "Quoting" http://www.itk.org/Wiki/CMake/Language_Syntax
  needs_quoting = false
  has_quotes = false
  # "contains at least one whitespace character,
  # and then prefixed or followed by any non-whitespace char value"
  # Well, that's not enough - consider a concatenation of variables
  # such as
  # ${v1} ${v2}
  # which should NOT be quoted (whereas ${v1} ascii ${v2} should!).
  # As a bandaid to detect variable syntax, make sure to skip
  # closing bracket/dollar sign as well.
  if elem.match(/[^\}\s]\s|\s[^\s\$]/)
    needs_quoting = true
  end
  if elem.match(/".*"/)
    has_quotes = true
  end
  #puts "QUOTING: elem #{elem} needs_quoting #{needs_quoting} has_quotes #{has_quotes}"
  if needs_quoting and not has_quotes
    #puts "QUOTING: do quote!"
    return "\"#{elem}\""
  end
  if not needs_quoting and has_quotes
    #puts "QUOTING: do UNquoting!"
    return elem.gsub(/"(.*)"/, '\1')
  end
    #puts "QUOTING: do no changes!"
  return elem
end

class V2C_CMakeLocalGenerator < V2C_CMakeSyntaxGenerator
  def initialize(out)
    # FIXME: handle arr_config_var_handling appropriately
    # (place the translated CMake commands somewhere suitable)
    @arr_config_var_handling = Array.new
    super(out)
  end

  def write_include_directories(arr_includes, map_includes)
    # Side note: unfortunately CMake as of 2.8.7 probably still does not have
    # a # way of specifying _per-configuration_ syntax of include_directories().
    # See "[CMake] vcproj2cmake.rb script: announcing new version / hosting questions"
    #   http://www.cmake.org/pipermail/cmake/2010-June/037538.html
    #
    # Side note #2: relative arguments to include_directories() (e.g. "..")
    # are relative to CMAKE_PROJECT_SOURCE_DIR and _not_ BINARY,
    # at least on Makefile and .vcproj.
    # CMake dox currently don't offer such details... (yet!)
    if not arr_includes.empty?
      arr_includes_translated = Array.new
      arr_includes.each { |elem_inc_dir|
        elem_inc_dir = vs7_create_config_variable_translation(elem_inc_dir, @arr_config_var_handling)
        arr_includes_translated.push(elem_inc_dir)
      }
      write_build_attributes("include_directories", "", arr_includes_translated, map_includes, nil)
    end
  end

  def write_link_directories(arr_lib_dirs, map_lib_dirs)
    arr_lib_dirs_translated = Array.new
    arr_lib_dirs.each { |elem_lib_dir|
      elem_lib_dir = vs7_create_config_variable_translation(elem_lib_dir, @arr_config_var_handling)
      arr_lib_dirs_translated.push(elem_lib_dir)
    }
    arr_lib_dirs_translated.push("${V2C_LIB_DIRS}")
    write_comment_at_level(3, \
      "It is said to be preferable to be able to use target_link_libraries()\n" \
      "rather than the very unspecific link_directories()." \
    )
    write_build_attributes("link_directories", "", arr_lib_dirs_translated, map_lib_dirs, nil)
  end
  def write_directory_property_compile_flags(attr_opts)
    return if attr_opts.nil?
    write_empty_line()
    # Query WIN32 instead of MSVC, since AFAICS there's nothing in the
    # .vcproj to indicate tool specifics, thus these seem to
    # be settings for ANY PARTICULAR tool that is configured
    # on the Win32 side (.vcproj in general).
    str_platform = "WIN32"
    write_conditional_if(str_platform)
      write_line("set_property(DIRECTORY APPEND PROPERTY COMPILE_FLAGS #{attr_opts})")
    write_conditional_end(str_platform)
  end
  # FIXME private!
  def write_build_attributes(cmake_command, element_prefix, arr_defs, map_defs, cmake_command_arg)
    # the container for the list of _actual_ dependencies as stated by the project
    all_platform_defs = Hash.new
    parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
    all_platform_defs.each { |key, arr_platdefs|
      #log_info "arr_platdefs: #{arr_platdefs}"
      next if arr_platdefs.empty?
      arr_platdefs.uniq!
      write_empty_line()
      str_platform = key if not key.eql?("ALL")
      write_conditional_if(str_platform)
        if cmake_command_arg.nil?
          cmake_command_arg = ""
        end
        write_line("#{cmake_command}(#{cmake_command_arg}")
        cmake_indent_more()
          arr_platdefs.each do |curr_value|
            curr_value_quot = cmake_element_handle_quoting(curr_value)
            write_line("#{element_prefix}#{curr_value_quot}")
          end
        cmake_indent_less()
        write_line(")")
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
    if project_keyword.nil?
	project_keyword = "#{$v2c_attribute_not_provided_marker}"
    end
    write_line("v2c_post_setup(#{project_name}")
    cmake_indent_more()
      write_block( \
        "\"#{project_name}\" \"#{project_keyword}\"\n" \
        "\"${CMAKE_CURRENT_SOURCE_DIR}/#{vs_proj_file_basename}\"\n" \
        "\"${CMAKE_CURRENT_LIST_FILE}\"" \
      )
    cmake_indent_less()
    write_line(")")
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
      cmake_indent_more()
        arr_sub_filters.each { |subfilter|
          #log_info "writing: #{subfilter}"
          put_file_list(project_name, subfilter, this_source_group, arr_my_sub_sources)
        }
      cmake_indent_less()
    end
  
    group_tag = this_source_group.clone.gsub(/( |\\)/,'_')
  
    # process our hierarchy's own files
    if not arr_local_sources.nil?
      source_files_variable = "SOURCES_files_#{group_tag}"
      write_new_line("set(#{source_files_variable}" )
      cmake_indent_more()
        arr_local_sources.each { |source|
          #log_info "quotes now: #{source}"
          source_quot = cmake_element_handle_quoting(source)
          write_line(source_quot)
        }
      cmake_indent_less()
      write_line(")")
      # create source_group() of our local files
      if not parent_source_group.nil?
        write_line("source_group(\"#{this_source_group}\" FILES ${#{source_files_variable}})")
      end
    end
    if not source_files_variable.nil? or not arr_my_sub_sources.empty?
      sources_variable = "SOURCES_#{group_tag}"
      write_new_line("set(SOURCES_#{group_tag}")
      cmake_indent_more()
        # dump sub filters...
        arr_my_sub_sources.each { |source|
          write_line("${#{source}}")
        }
        # ...then our own files
        if not source_files_variable.nil?
          write_line("${#{source_files_variable}}")
        end
      cmake_indent_less()
      write_line(")")
      # add our source list variable to parent return
      arr_sub_sources_for_parent.push(sources_variable)
    end
  end
  def put_sources(arr_sub_sources)
    write_new_line("set(SOURCES")
    cmake_indent_more()
      arr_sub_sources.each { |source_item|
        write_line("${#{source_item}}")
      }
    cmake_indent_less()
    write_line(")")
  end
  def write_target_executable
    write_new_line("add_executable(#{@target.name} WIN32 ${SOURCES})")
  end

  def write_target_library_dynamic
    write_new_line("add_library(#{@target.name} SHARED ${SOURCES})")
  end

  def write_target_library_static
    #write_new_line("add_library_vcproj2cmake( #{target.name} STATIC ${SOURCES} )")
    write_new_line("add_library(#{@target.name} STATIC ${SOURCES})")
  end
  def generate_property_compile_definitions(config_name_upper, arr_platdefs, str_platform)
      write_conditional_if(str_platform)
        # make sure to specify APPEND for greater flexibility (hooks etc.)
        write_line("set_property(TARGET #{@target.name} APPEND PROPERTY COMPILE_DEFINITIONS_#{config_name_upper}")
        cmake_indent_more()
          # FIXME: we should probably get rid of sort() here (and elsewhere),
          # but for now we'll keep it, to retain identically generated files.
          arr_platdefs.sort.each do |compile_defn|
    	# Need to escape the value part of the key=value definition:
            if compile_defn =~ /[\(\)]+/
               escape_char(compile_defn, '\\(')
               escape_char(compile_defn, '\\)')
            end
            write_line(compile_defn)
          end
        cmake_indent_less()
        write_line(")")
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
      #log_info "arr_platdefs: #{arr_platdefs}"
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
    write_conditional_if(str_conditional)
      write_line("set_property(TARGET #{@target.name} APPEND PROPERTY COMPILE_FLAGS_#{config_name_upper}")
      cmake_indent_more()
        arr_flags.each do |compile_flag|
          write_line(compile_flag)
        end
      cmake_indent_less()
      write_line(")")
    write_conditional_end(str_conditional)
  end
  def write_link_libraries(arr_dependencies, map_dependencies)
    arr_dependencies.push("${V2C_LIBS}")
    @localGenerator.write_build_attributes("target_link_libraries", "", arr_dependencies, map_dependencies, @target.name)
  end
  def set_properties_vs_scc(scc_info)
    # Keep source control integration in our conversion!
    # FIXME: does it really work? Then reply to
    # http://www.itk.org/Bug/view.php?id=10237 !!

    # If even scc_info.project_name is unavailable,
    # then we can bail out right away...
    return if scc_info.project_name.nil?

    # Hmm, perhaps need to use CGI.escape since chars other than just '"' might need to be escaped?
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
    if scc_info.local_path
      escape_backslash(scc_info.local_path)
      escape_char(scc_info.local_path, '"')
    end
    if scc_info.provider
      escape_char(scc_info.provider, '"')
    end
    if scc_info.aux_path
      escape_backslash(scc_info.aux_path)
      escape_char(scc_info.aux_path, '"')
    end

    write_empty_line()
    @localGenerator.write_vcproj2cmake_func_comment()
    write_line("v2c_target_set_properties_vs_scc(#{@target.name} \"#{scc_info.project_name}\" \"#{scc_info.local_path}\" \"#{scc_info.provider}\" \"#{scc_info.aux_path}\")")
  end

  private

  def get_config_name_upcase(config_name)
    # need to also convert config names with spaces into underscore variants, right?
    config_name.clone.upcase.gsub(/ /,'_')
  end

  def set_property(target, property, value)
    write_line("set_property(TARGET #{target} PROPERTY #{property} \"#{value}\")")
  end
end

$vs7_prop_var_scan_regex = "\\$\\(([[:alnum:]_]+)\\)"
$vs7_prop_var_match_regex = "\\$\\([[:alnum:]_]+\\)"

class V2C_VS7Parser
  def initialize
    @vs7_value_separator_regex = "[;,]"
  end

  def read_compiler_additional_include_directories(compiler_xml, arr_includes)
    attr_incdir = compiler_xml.attributes["AdditionalIncludeDirectories"]
    if not attr_incdir.nil?
      # FIXME: we should probably get rid of sort() here (and elsewhere),
      # but for now we'll keep it, to retain identically generated files.
      include_dirs = attr_incdir.split(/#{@vs7_value_separator_regex}/).sort.each { |elem_inc_dir|
        elem_inc_dir = normalize_path(elem_inc_dir).strip
        #log_info "include is '#{elem_inc_dir}'"
        arr_includes.push(elem_inc_dir)
      }
    end
  end

  def read_compiler_preprocessor_definitions(compiler_xml, hash_defines)
    attr_defines = compiler_xml.attributes["PreprocessorDefinitions"]
    if not attr_defines.nil?
      attr_defines.split(/#{@vs7_value_separator_regex}/).each { |elem_define|
        str_define_key, str_define_value = elem_define.strip.split(/=/)
        # Since a Hash will indicate nil for any non-existing key,
        # we do need to fill in _empty_ value for our _existing_ key.
        if str_define_value.nil?
  	str_define_value = ""
        end
        hash_defines[str_define_key] = str_define_value
      }
    end
  end

  def read_linker_additional_dependencies(linker_xml, arr_dependencies)
    attr_deps = linker_xml.attributes["AdditionalDependencies"]
    if attr_deps and attr_deps.length > 0
      attr_deps.split.each { |elem_lib_dep|
        elem_lib_dep = normalize_path(elem_lib_dep).strip
        arr_dependencies.push(File.basename(elem_lib_dep, ".lib"))
      }
    end
  end

  def read_linker_additional_library_directories(linker_xml, arr_lib_dirs)
    attr_lib_dirs = linker_xml.attributes["AdditionalLibraryDirectories"]
    if attr_lib_dirs and attr_lib_dirs.length > 0
      attr_lib_dirs.split(/#{@vs7_value_separator_regex}/).each { |elem_lib_dir|
        elem_lib_dir = normalize_path(elem_lib_dir).strip
        #log_info "lib dir is '#{elem_lib_dir}'"
        arr_lib_dirs.push(elem_lib_dir)
      }
    end
  end
end

def vs7_parse_file(project_name, file_xml, arr_sources)
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
    log_info "#{project_name}::#{f} is an IDL generated file: skipping! FIXME: should be platform-dependent."
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
    log_info "#{project_name}::#{f} registered as a \"source\" file!? Skipping!"
    included_in_build = false
    return # no complex handling, just return
  end

  if not excluded_from_build and included_in_build
    if $v2c_validate_vcproj_ensure_files_ok
      # TODO: perhaps we need to add a permissions check, too?
      if not File.exist?("#{$project_dir}/#{f}")
        log_error "File #{f} as listed in project #{project_name} does not exist!? (perhaps filename with wrong case, or wrong path, ...)"
        if $v2c_validate_vcproj_abort_on_error > 0
          log_fatal "Improper original file - will abort and NOT write a broken CMakeLists.txt. Please fix .vcproj content!"
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

def vs7_get_config_name(config_xml)
  config_xml.attributes["Name"].split("|")[0]
end

def vs7_get_configuration_types(project_xml, configuration_types)
  project_xml.elements.each("Configurations/Configuration") { |config_xml|
    config_name = vs7_get_config_name(config_xml)
    configuration_types.push(config_name)
  }
end

def vs7_parse_file_list(project_name, vcproj_filter_xml, files_str)
  file_group_name = vcproj_filter_xml.attributes["Name"]
  if file_group_name.nil?
    file_group_name = "COMMON"
  end
  files_str[:name] = file_group_name
  log_debug "parsing files group #{files_str[:name]}"

  vcproj_filter_xml.elements.each("Filter") { |subfilter_xml|
    # skip file filters that have a SourceControlFiles property
    # that's set to false, i.e. files which aren't under version
    # control (such as IDL generated files).
    # This experimental check might be a little rough after all...
    # yes, FIXME: on Win32, these files likely _should_ get listed
    # after all. We should probably do a platform check in such
    # cases, i.e. add support for a file_mappings.txt
    attr_scfiles = subfilter_xml.attributes["SourceControlFiles"]
    if not attr_scfiles.nil? and attr_scfiles.downcase == "false"
      log_info "#{files_str[:name]}: SourceControlFiles set to false, listing generated files? --> skipping!"
      next
    end
    attr_scname = subfilter_xml.attributes["Name"]
    if not attr_scname.nil? and attr_scname == "Generated Files"
      # Hmm, how are we supposed to handle Generated Files?
      # Most likely we _are_ supposed to add such files
      # and set_property(SOURCE ... GENERATED) on it.
      log_info "#{files_str[:name]}: encountered a filter named Generated Files --> skipping! (FIXME)"
      next
    end
    # TODO: fetch filter regex if available, then have it generated as source_group(REGULAR_EXPRESSION "regex" ...).
    # attr_filter_regex = subfilter_xml.attributes["Filter"]
    if files_str[:arr_sub_filters].nil?
      files_str[:arr_sub_filters] = Array.new
    end
    subfiles_str = Files_str.new
    files_str[:arr_sub_filters].push(subfiles_str)
    vs7_parse_file_list(project_name, subfilter_xml, subfiles_str)
  }

  arr_sources = Array.new
  vcproj_filter_xml.elements.each("File") { |file_xml|
    vs7_parse_file(project_name, file_xml, arr_sources)
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
def vs7_create_config_variable_translation(str, arr_config_var_handling)
  # http://langref.org/all-languages/pattern-matching/searching/loop-through-a-string-matching-a-regex-and-performing-an-action-for-each-match
  str_scan_copy = str.dup # create a deep copy of string, to avoid "`scan': string modified (RuntimeError)"
  str_scan_copy.scan(/#{$vs7_prop_var_scan_regex}/) {
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
        log_warn "Unknown/user-custom config variable name #{config_var} encountered in line '#{str}' --> TODO?"

        #str.gsub!(/\$\(#{config_var}\)/, "${v2c_VS_#{config_var}}")
	# For now, at least better directly reroute from environment variables:
	config_var_replacement = "$ENV{#{config_var}}"
      end
      if config_var_replacement != ""
        log_info "Replacing MSVS configuration variable $(#{config_var}) by #{config_var_replacement}."
        str.gsub!(/\$\(#{config_var}\)/, config_var_replacement)
      end
  }

  #log_info "str is now #{str}"
  return str
end

def project_parse_vs7(vcproj_filename, arr_targets, arr_config_info)
  File.open(vcproj_filename) { |io|
    doc = REXML::Document.new io

    global_parser = V2C_VS7Parser.new

    doc.elements.each("VisualStudioProject") { |project_xml|

      target = V2C_Target.new

      target.name = project_xml.attributes["Name"]
      target.vs_keyword = project_xml.attributes["Keyword"]

      # we can handle the following target stuff outside per-config handling (reason: see comment above)
      scc_info = target.scc_info
      if not project_xml.attributes["SccProjectName"].nil?
        scc_info.project_name = project_xml.attributes["SccProjectName"].clone
        # Hrmm, turns out having SccProjectName is no guarantee that both SccLocalPath and SccProvider
        # exist, too... (one project had SccProvider missing). HOWEVER,
	# CMake generator does expect all three to exist when available! Hmm.
	#
	# There's a special SAK (Should Already Know) entry marker
	# (see e.g. http://stackoverflow.com/a/6356615 ).
	# Currently I don't believe we need to handle "SAK" in special ways
	# (such as filling it in in case of missing entries),
	# transparent handling ought to be sufficient.
        if not project_xml.attributes["SccLocalPath"].nil?
          scc_info.local_path = project_xml.attributes["SccLocalPath"].clone
        end
        if not project_xml.attributes["SccProvider"].nil?
          scc_info.provider = project_xml.attributes["SccProvider"].clone
        end
        if not project_xml.attributes["SccAuxPath"].nil?
          scc_info.aux_path = project_xml.attributes["SccAuxPath"].clone
        end
      end

      $have_build_units = false

      configuration_types = Array.new
      vs7_get_configuration_types(project_xml, configuration_types)

      $main_files = Files_str.new
      project_xml.elements.each("Files") { |files_xml|
      	vs7_parse_file_list(target.name, files_xml, $main_files)
      }

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
      # Well, in that case we should simply resort to generating
      # the _union_ of all include directories of all configurations...

      if $config_multi_authoritative.empty?
	project_configuration_first_xml = project_xml.elements["Configurations/Configuration"].next_element
	if not project_configuration_first_xml.nil?
          $config_multi_authoritative = vs7_get_config_name(project_configuration_first_xml)
	end
      end

      # Technical note: target type (library, executable, ...) in .vcproj can be configured per-config
      # (or, in other words, different configs are capable of generating _different_ target _types_
      # for the _same_ target), but in CMake this isn't possible since _one_ target name
      # maps to _one_ target type and we _need_ to restrict ourselves to using the project name
      # as the exact target name (we are unable to define separate PROJ_lib and PROJ_exe target names,
      # since other .vcproj file contents always link to our target via the main project name only!!).
      # Thus we need to declare the target variable _outside_ the scope of per-config handling :(

      project_xml.elements.each("Configurations/Configuration") { |config_xml|
	config_info_curr = V2C_Config_Info.new

        config_info_curr.name = vs7_get_config_name(config_xml)

        config_info_curr.type = config_xml.attributes["ConfigurationType"].to_i

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
        config_info_curr.use_of_mfc = config_xml.attributes["UseOfMFC"].to_i
        config_info_curr.use_of_atl = config_xml.attributes["UseOfATL"].to_i

        config_xml.elements.each('Tool[@Name="VCCLCompilerTool"]') { |compiler_xml|
	  compiler_info = V2C_Compiler_Info.new
	  global_parser.read_compiler_additional_include_directories(compiler_xml, compiler_info.arr_includes)

	  global_parser.read_compiler_preprocessor_definitions(compiler_xml, compiler_info.hash_defines)
          if config_info_curr.use_of_mfc == 2
            compiler_info.hash_defines["_AFXEXT"] = ""
	    compiler_info.hash_defines["_AFXDLL"] = ""
          end

          attr_opts = compiler_xml.attributes["AdditionalOptions"]
	  # Oh well, we might eventually want to provide a full-scale
	  # translation of various compiler switches to their
	  # counterparts on compilers of various platforms, but for
	  # now, let's simply directly pass them on to the compiler when on
	  # Win32 platform.
	  if not attr_opts.nil?
	     # I don't think we need this (we have per-target properties), thus we'll NOT write it!
	     #local_generator.write_directory_property_compile_flags(attr_opts)

	    # TODO: add translation table for specific compiler flag settings such as MinimalRebuild:
	    # simply make reverse use of existing translation table in CMake source.
	    compiler_info.arr_flags = attr_opts.split(";")
          end

	  config_info_curr.arr_compiler_info.push(compiler_info)
        }

        #if not arr_sub_sources.empty?
        if $have_build_units
	  # parse linker configuration...
          config_xml.elements.each('Tool[@Name="VCLinkerTool"]') { |linker_xml|
	    linker_info_curr = V2C_Linker_Info.new
	    arr_dependencies_curr = linker_info_curr.arr_dependencies
	    global_parser.read_linker_additional_dependencies(linker_xml, arr_dependencies_curr)
	    arr_lib_dirs_curr = linker_info_curr.arr_lib_dirs
	    global_parser.read_linker_additional_library_directories(linker_xml, arr_lib_dirs_curr)
	    # TODO: support AdditionalOptions! (mention via
	    # CMAKE_SHARED_LINKER_FLAGS / CMAKE_MODULE_LINKER_FLAGS / CMAKE_EXE_LINKER_FLAGS
	    # depending on target type, and make sure to filter out options pre-defined by CMake platform
	    # setup modules)
	    config_info_curr.arr_linker_info.push(linker_info_curr)
          }
	end

	arr_config_info.push(config_info_curr)
      }
      arr_targets.push(target)
    }
  }
end

class V2C_VS10Parser
end

def project_parse_vs10(vcxproj_filename, arr_targets, arr_config_info)
  File.open(vcproj_filename) { |io|
    doc = REXML::Document.new io

    global_parser = V2C_VS10Parser.new

    doc.elements.each("VisualStudioProject") { |project_xml|
    }
  }
end

def project_generate_cmake(p_vcproj, out, target, main_files, arr_config_info)
      target_is_valid = false

      generator_base = V2C_BaseGlobalGenerator.new
      map_lib_dirs = Hash.new
      read_mappings_combined($filename_map_lib_dirs, map_lib_dirs)
      map_dependencies = Hash.new
      read_mappings_combined($filename_map_dep, map_dependencies)
      map_defines = Hash.new
      read_mappings_combined($filename_map_def, map_defines)

      syntax_generator = V2C_CMakeSyntaxGenerator.new(out)

      # we likely shouldn't declare this, since for single-configuration
      # generators CMAKE_CONFIGURATION_TYPES shouldn't be set
      ## configuration types need to be stated _before_ declaring the project()!
      #syntax_generator.write_empty_line()
      #global_generator.put_configuration_types(configuration_types)

      local_generator = V2C_CMakeLocalGenerator.new(out)

      global_generator = V2C_CMakeGlobalGenerator.new(out)

      global_generator.put_file_header()

      # FIXME: these are all statements of the _project-local_ file,
      # not any global ("solution") content!! --> move to local_generator.
      global_generator.put_project(target.name)

      ## sub projects will inherit, and we _don't_ want that...
      # DISABLED: now to be done by MasterProjectDefaults_vcproj2cmake module if needed
      #syntax_generator.write_line("# reset project-local variables")
      #syntax_generator.write_line("set( V2C_LIBS )")
      #syntax_generator.write_line("set( V2C_SOURCES )")

      global_generator.put_include_MasterProjectDefaults_vcproj2cmake()

      global_generator.put_hook_project()

      target_generator = V2C_CMakeTargetGenerator.new(target, local_generator, out)

      arr_sub_sources = Array.new
      target_generator.put_file_list(target.name, main_files, nil, arr_sub_sources)

      if not arr_sub_sources.empty?
        # add a ${V2C_SOURCES} variable to the list, to be able to append
        # all sorts of (auto-generated, ...) files to this list within
        # hook includes.
	# - _right before_ creating the target with its sources
	# - and not earlier since earlier .vcproj-defined variables should be clean (not be made to contain V2C_SOURCES contents yet)
        arr_sub_sources.push("V2C_SOURCES")
      else
        log_warn "#{target.name}: no source files at all!? (header-based project?)"
      end

      global_generator.put_include_project_source_dir()

      global_generator.put_hook_post_sources()

      arr_config_info.each { |config_info_curr|
	build_type_condition = ""
	if $config_multi_authoritative == config_info_curr.name
	  build_type_condition = "CMAKE_CONFIGURATION_TYPES OR CMAKE_BUILD_TYPE STREQUAL \"#{config_info_curr.name}\""
	else
	  # YES, this condition is supposed to NOT trigger in case of a multi-configuration generator
	  build_type_condition = "CMAKE_BUILD_TYPE STREQUAL \"#{config_info_curr.name}\""
	end
	var_v2c_want_buildcfg_curr = "v2c_want_buildcfg_#{config_info_curr.name}"
	syntax_generator.write_var_bool_conditional(var_v2c_want_buildcfg_curr, build_type_condition)
      }

      arr_config_info.each { |config_info_curr|
	var_v2c_want_buildcfg_curr = "v2c_want_buildcfg_#{config_info_curr.name}"
	syntax_generator.write_empty_line()
	syntax_generator.write_conditional_if(var_v2c_want_buildcfg_curr)

	global_generator.put_cmake_mfc_atl_flag(config_info_curr)

	config_info_curr.arr_compiler_info.each { |compiler_info_curr|
	  local_generator.write_include_directories(compiler_info_curr.arr_includes, generator_base.map_includes)
	}

	# FIXME: hohumm, the position of this hook include is outdated, need to update it
	global_generator.put_hook_post_definitions()

        # create a target only in case we do have any meat at all
        #if not main_files[:arr_sub_filters].empty? or not main_files[:arr_files].empty?
        #if not arr_sub_sources.empty?
        if $have_build_units

          # first add source reference, then do linker setup, then create target

	  target_generator.put_sources(arr_sub_sources)

	  # write link_directories() (BEFORE establishing a target!)
	  config_info_curr.arr_linker_info.each { | linker_info_curr|
	    local_generator.write_link_directories(linker_info_curr.arr_lib_dirs, map_lib_dirs)
	  }

	  target_is_valid = false

	  str_condition_no_target = "NOT TARGET #{target.name}"
	  syntax_generator.write_conditional_if(str_condition_no_target)
          # FIXME: should use a macro like rosbuild_add_executable(),
          # http://www.ros.org/wiki/rosbuild/CMakeLists ,
          # https://kermit.cse.wustl.edu/project/robotics/browser/trunk/vendor/ros/core/rosbuild/rosbuild.cmake?rev=3
          # to be able to detect non-C++ file types within a source file list
          # and add a hook to handle them specially.

          # see VCProjectEngine ConfigurationTypes enumeration
    	  case config_info_curr.type
          when 1       # typeApplication (.exe)
	    target_is_valid = true
            #syntax_generator.write_line("add_executable_vcproj2cmake( #{target.name} WIN32 ${SOURCES} )")
            # TODO: perhaps for real cross-platform binaries (i.e.
            # console apps not needing a WinMain()), we should detect
            # this and not use WIN32 in this case...
	    # Well, this probably is related to the .vcproj Keyword attribute ("Win32Proj", "MFCProj", "ATLProj", "MakeFileProj" etc.).
	    target_generator.write_target_executable()
          when 2    # typeDynamicLibrary (.dll)
	    target_is_valid = true
            #syntax_generator.write_line("add_library_vcproj2cmake( #{target.name} SHARED ${SOURCES} )")
            # add_library() docs: "If no type is given explicitly the type is STATIC or  SHARED
            #                      based on whether the current value of the variable
            #                      BUILD_SHARED_LIBS is true."
            # --> Thus we would like to leave it unspecified for typeDynamicLibrary,
            #     and do specify STATIC for explicitly typeStaticLibrary targets.
            # However, since then the global BUILD_SHARED_LIBS variable comes into play,
            # this is a backwards-incompatible change, thus leave it for now.
            # Or perhaps make use of new V2C_TARGET_LINKAGE_{SHARED|STATIC}_LIB
            # variables here, to be able to define "SHARED"/"STATIC" externally?
	    target_generator.write_target_library_dynamic()
          when 4    # typeStaticLibrary
	    target_is_valid = true
	    target_generator.write_target_library_static()
          when 0    # typeUnknown (utility)
            log_warn "Project type 0 (typeUnknown - utility) is a _custom command_ type and thus probably cannot be supported easily. We will not abort and thus do write out a file, but it probably needs fixup (hook scripts?) to work properly. If this project type happens to use VCNMakeTool tool, then I would suggest to examine BuildCommandLine/ReBuildCommandLine/CleanCommandLine attributes for clues on how to proceed."
	  else
          #when 10    # typeGeneric (Makefile) [and possibly other things...]
            # TODO: we _should_ somehow support these project types...
            log_fatal "Project type #{config_info_curr.type} not supported."
          end
	  syntax_generator.write_conditional_end(str_condition_no_target)

	  # write target_link_libraries() in case there's a valid target
          if target_is_valid
	    config_info_curr.arr_linker_info.each { | linker_info_curr|
	      target_generator.write_link_libraries(linker_info_curr.arr_dependencies, map_dependencies)
	    }
          end # target_is_valid
        end # not arr_sub_sources.empty?

	global_generator.put_hook_post_target()

	syntax_generator.write_conditional_end(var_v2c_want_buildcfg_curr)
      } # [END per-config handling]

      # Now that we likely _do_ have a valid target
      # (created by at least one of the Debug/Release/... build configs),
      # *iterate through the configs again* and add config-specific
      # definitions. This is necessary (fix for multi-config
      # environment).
      if target_is_valid
        str_conditional = "TARGET #{target.name}"
        syntax_generator.write_conditional_if(str_conditional)
      arr_config_info.each { |config_info_curr|
        # NOTE: the commands below can stay in the general section (outside of
        # var_v2c_want_buildcfg_curr above), but only since they define properties
        # which are clearly named as being configuration-_specific_ already!
        #
	# I don't know WhyTH we're iterating over a compiler_info here,
	# but let's just do it like that for now since it's required
	# by our current data model:
	  config_info_curr.arr_compiler_info.each { |compiler_info_curr|
            target_generator.write_property_compile_definitions(config_info_curr.name, compiler_info_curr.hash_defines, map_defines)
            # Original compiler flags are MSVC-only, of course. TODO: provide an automatic conversion towards gcc?
            target_generator.write_property_compile_flags(config_info_curr.name, compiler_info_curr.arr_flags, "MSVC")
          }
        }
        syntax_generator.write_conditional_end(str_conditional)
      end

      if target_is_valid
	target_generator.set_properties_vs_scc(target.scc_info)

        # TODO: might want to set a target's FOLDER property, too...
        # (and perhaps a .vcproj has a corresponding attribute
        # which indicates that?)

        # TODO: perhaps there are useful Xcode (XCODE_ATTRIBUTE_*) properties to convert?
      end # target_is_valid

      global_generator.put_var_converter_script_location($script_location_relative_to_master)
      local_generator.write_func_v2c_post_setup(target.name, target.vs_keyword, p_vcproj.basename)
end

################
#     MAIN     #
################

arr_targets = Array.new
arr_config_info = Array.new

# Q&D parser switch...
if str_vcproj_filename.match(/.vcproj$/)
  project_parse_vs7(vcproj_filename, arr_targets, arr_config_info)
elsif str_vcproj_filename.match(/.vcxproj$/)
  project_parse_vs10(vcproj_filename, arr_targets, arr_config_info)
end

# write into temporary file, to avoid corrupting previous CMakeLists.txt due to disk space or failure issues
tmpfile = Tempfile.new('vcproj2cmake')

File.open(tmpfile.path, "w") { |out|

  # Wrong hierarchy, but currently I really don't care...
  # (output file should be _created/handled_ within per-target handling)
  arr_targets.each { |target|
    project_generate_cmake(p_vcproj, out, target, $main_files, arr_config_info)
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
    # Move away old file.
    # Usability trick:
    # rename to CMakeLists.txt.previous and not CMakeLists.previous.txt
    # since grepping for all *.txt files would then hit these outdated ones.
    V2C_Util_File.mv(output_file, output_file + ".previous")
  end
  # activate our version
  # [for chmod() comments, see our $v2c_cmakelists_create_permissions settings variable]
  V2C_Util_File.chmod($v2c_cmakelists_create_permissions, tmpfile.path)
  V2C_Util_File.mv(tmpfile.path, output_file)

  log_info %{\
Wrote #{output_file}
Finished. You should make sure to have all important v2c settings includes such as vcproj2cmake_defs.cmake somewhere in your CMAKE_MODULE_PATH
}
else
  log_info "No settings changed, #{output_file} not updated."
  # tmpfile will auto-delete when finalized...

  # Some make dependency mechanisms might require touching (timestamping) the unchanged(!) file
  # to indicate that it's up-to-date,
  # however we won't do this here since it's not such a good idea.
  # Any user who needs that should do a manual touch subsequently.
end
