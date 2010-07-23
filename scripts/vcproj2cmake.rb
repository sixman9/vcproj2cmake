#!/usr/bin/ruby

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
# and thus keep your local specific additions _separate_.

# TODO: Always make sure that a simple vcproj2cmake.rb run will result in a
# fully working _self-contained_ CMakeLists.txt, no matter how small
# the current vcproj2cmake config environment is
# (i.e., it needs to work even without a single specification file)

# TODO:
# - perhaps there's a way to provide more precise/comfortable hook script handling?
# - should continue with clean separation of .vcproj content parsing and .vcproj output
#   generation (e.g. in preparation for .vcxproj support)
# - try to come up with an ingenious way to near-_automatically_ handle those pesky repeated
#   dependency requirements of several sub projects
#   (e.g. the component-based Boost Find scripts, etc.) instead of having to manually
#   write custom hook script content (which cannot be kept synchronized
#   with changes _automatically_!!) each time due to changing components and libraries.

require 'fileutils'
require 'tempfile'
require 'pathname'
require 'rexml/document'
include FileUtils::Verbose

# load common settings
$LOAD_PATH.unshift(File.dirname(__FILE__)) 
load 'vcproj2cmake_settings.rb'

# Usage: vcproj2cmake.rb <input.vcproj> [<output CMakeLists.txt>] [<master project directory>]

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
   puts ""
   puts "*** Input Error *** #{script_name}"
   puts "#{cl_error}"
   puts ""
   puts "Usage: vcproj2cmake.rb <input.vcproj> [<output CMakeLists.txt>] [<master project directory>]"

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
$master_project_dir = ARGV.shift or "."
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

filename_map_inc = "#{$v2c_config_dir_local}/include_mappings.txt"
filename_map_def = "#{$v2c_config_dir_local}/define_mappings.txt"
filename_map_dep = "#{$v2c_config_dir_local}/dependency_mappings.txt"
filename_map_lib_dirs = "#{$v2c_config_dir_local}/lib_dirs_mappings.txt"

$myindent = 0

### USER-CONFIGURABLE SECTION END ###


p_vcproj = Pathname.new(vcproj_filename)
# figure out a global project_dir variable from the .vcproj location
project_dir = p_vcproj.dirname

#p_project_dir = Pathname.new(project_dir)
#p_cmakelists = Pathname.new(output_file)
#cmakelists_dir = p_cmakelists.dirname
#p_cmakelists_dir = Pathname.new(cmakelists_dir)
#p_cmakelists_dir.relative_path_from(...)


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
def normalize(p)
  felems = p.gsub("\\", "/").split("/")
  # DON'T eradicate single '.'!!
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
    puts "NOTE: #{filename_mappings} NOT AVAILABLE"
  end
  #puts mappings["kernel32"]
  #puts mappings["mytest"]
end

def read_mappings_combined(filename_mappings, mappings)
  if $master_project_dir
    # read common mappings to be used by all sub projects
    read_mappings("#{$master_project_dir}/#{filename_mappings}", mappings)
  end
  read_mappings(filename_mappings, mappings)
end

def push_platform_def(platform_defs, platform, def_value)
  #puts "adding #{def_value} on platform #{platform}"
  if platform_defs[platform].nil?
    platform_defs[platform] = Array.new
  end
  platform_defs[platform].push(def_value)
end

def parse_platform_conversions(platform_defs, arr_defs, map_defs)
  arr_defs.each { |curr_value|
    #puts map_defs[curr_value]
    map_line = map_defs[curr_value]
    if map_line.nil?
      # hmm, no direct match! Try to figure out whether any map entry
      # is a regex which would match our curr_value
      map_defs.each do |key, value|
        if curr_value =~ /^#{key}$/
          puts "KEY: #{key} curr_value #{curr_value}"
          map_line = value
        end
      end
    end
    if map_line.nil?
      # no mapping? --> unconditionally use the original define
      push_platform_def(platform_defs, "ALL", curr_value)
    else
      map_line.chomp.split(/\|/).each do |platform_element|
        #puts "platform_element #{platform_element}"
        platform, replacement_def = platform_element.split(/=/)
        if platform.empty?
          # specified a replacement without a specific platform?
          # ("tag:=REPLACEMENT")
          # --> unconditionally use it!
          platform = "ALL"
        else
          if replacement_def.nil?
            replacement_def = curr_value
          end
        end
        push_platform_def(platform_defs, platform, replacement_def)
      end
    end
  }
end

def cmake_write_build_attributes(cmake_command, element_prefix, out, arr_defs, map_defs, cmake_command_arg)
  # the container for the list of _actual_ dependencies as stated by the project
  all_platform_defs = Hash.new
  parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
  all_platform_defs.each { |key, arr_platdefs|
    #puts "arr_platdefs: #{arr_platdefs}"
    next if arr_platdefs.empty?
    arr_platdefs.uniq!
    out.puts
    specific_platform = !(key.eql?("ALL"))
    if specific_platform
      puts_ind(out, "if(#{key})")
      $myindent += 2
    end
    if cmake_command_arg.nil?
      puts_ind(out, "#{cmake_command}(")
    else
      puts_ind(out, "#{cmake_command}(#{cmake_command_arg}")
    end
    arr_platdefs.each do |curr_value|
      puts_ind(out, "  #{element_prefix}#{curr_value}")
    end
    puts_ind(out, ")")
    if specific_platform
      $myindent -= 2
      puts_ind(out, "endif(#{key})")
    end
  }
end

def cmake_get_config_name_upcase(config_name)
  # need to also convert config names with spaces into underscore variants, right?
  config_name.clone.upcase.gsub(/ /,'_')
end

def cmake_set_target_property(target, property, value, out)
  puts_ind(out, "set_property(TARGET #{target} PROPERTY #{property} \"#{value}\")")
end

def cmake_set_target_property_compile_definitions(target, config_name, arr_defs, map_defs, out)
  config_name_upper = cmake_get_config_name_upcase(config_name)
  # the container for the list of _actual_ dependencies as stated by the project
  all_platform_defs = Hash.new
  parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
  all_platform_defs.each { |key, arr_platdefs|
    #puts "arr_platdefs: #{arr_platdefs}"
    next if arr_platdefs.empty?
    arr_platdefs.uniq!
    out.puts
    specific_platform = !(key.eql?("ALL"))
    if specific_platform
      puts_ind(out, "if(#{key})")
      $myindent += 2
    end
    # make sure to specify APPEND for greater flexibility (hooks etc.)
    puts_ind(out, "set_property(TARGET #{target} APPEND PROPERTY COMPILE_DEFINITIONS_#{config_name_upper} ")
    arr_platdefs.each do |curr_value|
      puts_ind(out, "  #{curr_value}")
    end
    puts_ind(out, ")")
    if specific_platform
      $myindent -= 2
      puts_ind(out, "endif(#{key})")
    end
  }
end

def cmake_set_target_property_compile_flags(target, config_name, arr_flags, out)
  return if arr_flags.empty?
  config_name_upper = cmake_get_config_name_upcase(config_name)
  # original compiler flags are MSVC-only, of course. TODO: provide an automatic conversion towards gcc?
  new_puts_ind(out, "if(MSVC)")
  puts_ind(out, "set_property(TARGET #{target} APPEND PROPERTY COMPILE_FLAGS_#{config_name_upper} ")
  arr_flags.each do |curr_value|
    puts_ind(out, "  #{curr_value}")
  end
  puts_ind(out, ")")
  puts_ind(out, "endif(MSVC)")
end

def vc8_parse_file(project, file, arr_sources)
  projname = project.attributes["Name"]
  f = normalize(file.attributes["RelativePath"])

  # Ignore header files
  return if f =~ /\.(h|H|lex|y|ico|bmp|txt)$/

  # Ignore files which have the ExcludedFromBuild attribute set to TRUE
  excluded_from_build = false
  file.elements.each("FileConfiguration") { |file_config|
    #file_config.elements.each('Tool[@Name="VCCLCompilerTool"]') { |compiler|
    #  if compiler.attributes["UsePrecompiledHeader"]
    #}
    excl_build = file_config.attributes["ExcludedFromBuild"]
    if not excl_build.nil? and excl_build.downcase == "true"
      excluded_from_build = true
      return # no complex handling, just return
    end
  }

  # Ignore files with custom build steps
  included_in_build = true
  file.elements.each("FileConfiguration/Tool") { |tool|
    if tool.attributes["Name"] == "VCCustomBuildTool"
      included_in_build = false
      return # no complex handling, just return
    end
  }

  # Verbosely ignore IDL generated files
  if f =~/_(i|p).c$/
    # see file_mappings.txt comment above
    puts "#{projname}::#{f} as an IDL generated file: skipping! FIXME: should be platform-dependent."
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
    puts "#{projname}::#{f} registered as a \"source\" file!? Skipping!"
    included_in_build = false
    return # no complex handling, just return
  end

  if not excluded_from_build and included_in_build
  	  arr_sources.push(f)
  end
end

Files_str = Struct.new(:name, :arr_sub_filters, :arr_files)

def vc8_get_config_name(config)
  config.attributes["Name"].split("|")[0]
end

def vc8_get_configuration_types(project, configuration_types)
  project.elements.each("Configurations/Configuration") { |config|
    config_name = vc8_get_config_name(config)
    configuration_types.push(config_name)
  }
end

# analogous to CMake separate_arguments() command
def cmake_separate_arguments(array_in)
  array_in.join(";")
end

def cmake_write_configuration_types(configuration_types, out)
    configuration_types_list = cmake_separate_arguments(configuration_types)
    puts_ind(out, "set(CMAKE_CONFIGURATION_TYPES \"#{configuration_types_list}\")" )
end

def vc8_parse_file_list(project, vcproj_filter, files_str)
  file_group_name = vcproj_filter.attributes["Name"]
  if file_group_name.nil?
    file_group_name = "COMMON"
  end
  files_str[:name] = file_group_name
  puts "parsing files group #{files_str[:name]}"

  vcproj_filter.elements.each("Filter") { |subfilter|
    # skip file filters that have a SourceControlFiles property
    # that's set to false, i.e. files which aren't under version
    # control (such as IDL generated files).
    # This experimental check might be a little rough after all...
    # yes, FIXME: on Win32, these files likely _should_ get listed
    # after all. We should probably do a platform check in such
    # cases, i.e. add support for a file_mappings.txt
    scfiles = subfilter.attributes["SourceControlFiles"]
    if not scfiles.nil? and scfiles.downcase == "false"
      puts "#{files_str[:name]}: SourceControlFiles set to false, listing generated files? --> skipping!"
      next
    end
    if files_str[:arr_sub_filters].nil?
      files_str[:arr_sub_filters] = Array.new()
    end
    subfiles_str = Files_str.new()
    files_str[:arr_sub_filters].push(subfiles_str)
    vc8_parse_file_list(project, subfilter, subfiles_str)
  }

  arr_sources = Array.new()
  vcproj_filter.elements.each("File") { |file|
    vc8_parse_file(project, file, arr_sources)
  } # |file|

  if not arr_sources.empty?
    files_str[:arr_files] = arr_sources
  end
end

def cmake_write_file_list(project, files_str, parent_source_group, arr_sub_sources_for_parent, out)
  group = files_str[:name]
  if not files_str[:arr_sub_filters].nil?
    arr_sub_filters = files_str[:arr_sub_filters]
  end
  if not files_str[:arr_files].nil?
    arr_local_sources = files_str[:arr_files].clone
  end

  # TODO: cmake is said to have a weird bug in case of parent_source_group being "Source Files"
  # http://www.mail-archive.com/cmake@cmake.org/msg05002.html
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
  arr_my_sub_sources = Array.new()
  if not arr_sub_filters.nil?
    $myindent += 2
    arr_sub_filters.each { |subfilter|
      #puts "writing: #{subfilter}"
      cmake_write_file_list(project, subfilter, this_source_group, arr_my_sub_sources, out)
    }
    $myindent -= 2
  end

  group_tag = this_source_group.clone.gsub(/( |\\)/,'_')

  # process our hierarchy's own files
  if not arr_local_sources.nil?
    source_files_variable = "SOURCES_files_#{group_tag}"
    new_puts_ind(out, "set(#{source_files_variable}" )
    arr_local_sources.each { |source|
      #puts "quotes now: #{source}"
      if source.include? ' '
        # quote arguments with spaces (yes, I don't know how to
        # preserve quotes properly other than to actually open-code it
        # in such an ugly way - ARGH!!)
        puts_ind(out, "  " + "\"#{source}\"")
      else
        puts_ind(out, "  " + "#{source}")
      end
    }
    puts_ind(out, ")")
    # create source_group() of our local files
    if not parent_source_group.nil?
      puts_ind(out, "source_group(\"#{this_source_group}\" FILES ${#{source_files_variable}})")
    end
  end
  if not source_files_variable.nil? or not arr_my_sub_sources.empty?
    sources_variable = "SOURCES_#{group_tag}";
    new_puts_ind(out, "set(SOURCES_#{group_tag}")
    $myindent += 2;
    # dump sub filters...
    arr_my_sub_sources.each { |source|
      puts_ind(out, "${#{source}}")
    }
    # ...then our own files
    if not source_files_variable.nil?
      puts_ind(out, "${#{source_files_variable}}")
    end
    $myindent -= 2;
    puts_ind(out, ")")
    # add our source list variable to parent return
    arr_sub_sources_for_parent.push(sources_variable)
  end
end

################
#     MAIN     #
################

# write into temporary file, to avoid corrupting previous CMakeLists.txt due to disk space or failure issues
tmpfile = Tempfile.new('vcproj2cmake')

File.open(tmpfile.path, "w") { |out|

  out.puts "#"
  out.puts "# TEMPORARY Build file, AUTO-GENERATED by http://vcproj2cmake.sf.net"
  out.puts "# DO NOT CHECK INTO VERSION CONTROL OR APPLY \"PERMANENT\" MODIFICATIONS!!"
  out.puts "#"
  out.puts
  # Required version line to make cmake happy.
  out.puts "# >= 2.6 due to crucial set_property(... COMPILE_DEFINITIONS_* ...)"
  out.puts "cmake_minimum_required(VERSION 2.6)"

  out.puts "if(COMMAND cmake_policy)"
  # manual quoting of brackets in definitions doesn't seem to work otherwise,
  # in cmake 2.6.4-7.el5 with CMP0005 OLD.
  out.puts "  if(POLICY CMP0005)"
  out.puts "    cmake_policy(SET CMP0005 NEW) # automatic quoting of brackets"
  out.puts "  endif(POLICY CMP0005)"
  out.puts
  out.puts "  if(POLICY CMP0011)"
  out.puts "    # we do want the includer to be affected by our updates,"
  out.puts "    # since it might define project-global settings."
  out.puts "    cmake_policy(SET CMP0011 OLD)"
  out.puts "  endif(POLICY CMP0011)"
  out.puts "  if(POLICY CMP0015)"
  out.puts "    # .vcproj contains relative paths to additional library directories, thus we need to be able to cope with that"
  out.puts "    cmake_policy(SET CMP0015 NEW)"
  out.puts "  endif(POLICY CMP0015)"
  out.puts "endif(COMMAND cmake_policy)"

  File.open(vcproj_filename) { |io|
    doc = REXML::Document.new io

    # try to point to cmake/Modules of the topmost directory of the vcproj2cmake conversion tree.
    # This also contains vcproj2cmake helper modules (these should - just like the CMakeLists.txt -
    # be within the project tree as well, since someone might want to copy the entire project tree
    # including .vcproj conversions to a different machine, thus all v2c components should be available)
    module_path_element = "\"#{$master_project_dir}/#{$v2c_module_path_local}\""

    # NOTE: use set() instead of list(APPEND...) to prepend path
    # (otherwise not able to provide proper overrides)
    new_puts_ind(out, "set(CMAKE_MODULE_PATH #{module_path_element} ${CMAKE_MODULE_PATH})")

    # "export" our internal $v2c_config_dir_local variable (to be able to reference it in CMake scripts as well)
    new_puts_ind(out, "set(V2C_CONFIG_DIR_LOCAL \"#{$v2c_config_dir_local}\")")

    new_puts_ind(out, "# include the main file for pre-defined vcproj2cmake helper functions")
    puts_ind(out, "include(vcproj2cmake_func)")

    new_puts_ind(out, "# include the main file for pre-defined vcproj2cmake definitions")
    puts_ind(out, "include(vcproj2cmake_defs)")

    # this CMakeLists.txt-global optional include could be used e.g.
    # to skip the entire build of this file on certain platforms:
    # if(PLATFORM) message(STATUS "not supported") return() ...
    # (note that we appended CMAKE_MODULE_PATH _prior_ to this include()!)
    new_puts_ind(out, "include(${V2C_CONFIG_DIR_LOCAL}/hook_pre.txt OPTIONAL)")

    doc.elements.each("VisualStudioProject") { |project|

      project_name = project.attributes["Name"]

      configuration_types = Array.new()
      vc8_get_configuration_types(project, configuration_types)

      # we likely shouldn't declare this, since for single-configuration
      # generators CMAKE_CONFIGURATION_TYPES shouldn't be set
      ## configuration types need to be stated _before_ declaring the project()!
      #out.puts
      #cmake_write_configuration_types(configuration_types, out)

      # TODO: figure out language type (C CXX etc.) and add it to project() command
      new_puts_ind(out, "project( #{project_name} )")

      ## sub projects will inherit, and we _don't_ want that...
      # DISABLED: now to be done by MasterProjectDefaults_vcproj2cmake module if needed
      #puts_ind(out, "# reset project-local variables")
      #puts_ind(out, "set( V2C_LIBS )")
      #puts_ind(out, "set( V2C_SOURCES )")

      out.puts
      out.puts "# this part is for including a file which contains"
      out.puts "# _globally_ applicable settings for all sub projects of a master project"
      out.puts "# (compiler flags, path settings, platform stuff, ...)"
      out.puts "# e.g. have vcproj2cmake-specific MasterProjectDefaults_vcproj2cmake"
      out.puts "# which then _also_ includes a global MasterProjectDefaults module"
      out.puts "# for _all_ CMakeLists.txt. This needs to sit post-project()"
      out.puts "# since e.g. compiler info is dependent on a valid project."
      puts_ind(out, "# MasterProjectDefaults_vcproj2cmake is supposed to define")
      puts_ind(out, "# generic settings (such as V2C_HOOK_PROJECT, defined as e.g.")
      puts_ind(out, "# #{$v2c_config_dir_local}/hook_project.txt, and other hook include variables below).")
      puts_ind(out, "# NOTE: it usually should also reset variables V2C_LIBS, V2C_SOURCES etc.")
      puts_ind(out, "# as used below since they should contain directory-specific contents only, not accumulate!")
      # (side note: see "ldd -u -r" on Linux for superfluous link parts potentially caused by this!)
      puts_ind(out, "include(MasterProjectDefaults_vcproj2cmake OPTIONAL)")

      puts_ind(out, "# hook e.g. for invoking Find scripts as expected by")
      puts_ind(out, "# the _LIBRARIES / _INCLUDE_DIRS mappings created")
      puts_ind(out, "# by your include/dependency map files.")
      puts_ind(out, "include(${V2C_HOOK_PROJECT} OPTIONAL)")

      main_files = Files_str.new()
      project.elements.each("Files") { |files|
      	vc8_parse_file_list(project, files, main_files)
      }
      arr_sub_sources = Array.new()
      $myindent += 2
      cmake_write_file_list(project, main_files, nil, arr_sub_sources, out)
      $myindent -= 2

      if not arr_sub_sources.empty?
        # add a ${V2C_SOURCES} variable to the list, to be able to append
        # all sorts of (auto-generated, ...) files to this list within
        # hook includes, _right before_ creating the target with its sources.
        arr_sub_sources.push("V2C_SOURCES")
      else
        puts "WARNING: #{project_name}: no source files at all!? (header-based project?)"
      end

      # AFAIK .vcproj implicitly adds the project root to standard include path
      # (for automatic stdafx.h resolution etc.), thus add this
      # (and make sure to add it with high priority, i.e. use BEFORE).
      new_puts_ind(out, "include_directories(BEFORE ${PROJECT_SOURCE_DIR})")

      new_puts_ind(out, "include(${V2C_HOOK_POST_SOURCES} OPTIONAL)")

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
	project_configuration_first = project.elements["Configurations/Configuration"].next_element
	if not project_configuration_first.nil?
          config_multi_authoritative = vc8_get_config_name(project_configuration_first)
	end
      end

      # target type (library, executable, ...) in .vcproj can be configured per-config
      # (or, in other words, different configs are capable of generating _different_ target _types_
      # for the _same_ target), but in CMake this isn't possible since _one_ target name
      # maps to _one_ target type and we _need_ to restrict ourselves to using the project name
      # as the exact target name (we are unable to define separate PROJ_lib and PROJ_exe target names,
      # since other .vcproj file contents always link to our target via the main project name only!!).
      # Thus we need to declare the target variable _outside_ the scope of per-config handling :(
      target = nil

      project.elements.each("Configurations/Configuration") { |config|
        config_name = vc8_get_config_name(config)

	build_type_condition = ""
	if config_multi_authoritative == config_name
	  build_type_condition = "CMAKE_CONFIGURATION_TYPES OR CMAKE_BUILD_TYPE STREQUAL \"#{config_name}\""
	else
	  # YES, this condition is supposed to NOT trigger in case of a multi-configuration generator
	  build_type_condition = "CMAKE_BUILD_TYPE STREQUAL \"#{config_name}\""
	end

        new_puts_ind(out, "if(#{build_type_condition})")
        $myindent += 2

        # FIXME: do we need to actively reset CMAKE_MFC_FLAG / CMAKE_ATL_FLAG
        # (i.e. best also set it in case of 0?), since projects in subdirs shouldn't inherit?

        # 0 == no MFC
        # 1 == static MFC
        # 2 == shared MFC
        config_use_of_mfc = config.attributes["UseOfMFC"].to_i
        if config_use_of_mfc > 0
          new_puts_ind(out, "set(CMAKE_MFC_FLAG #{config_use_of_mfc})")
        end

        # ok, there's no CMAKE_ATL_FLAG yet, AFAIK, but still prepare
        # for it (also to let people probe on this in hook includes)
        config_use_of_atl = config.attributes["UseOfATL"].to_i
        if config_use_of_atl > 0
	  # TODO: should also set the per-configuration-type variable variant
          new_puts_ind(out, "set(CMAKE_ATL_FLAG #{config_use_of_atl})")
        end

        arr_defines = Array.new()
        arr_flags = Array.new()
        config.elements.each('Tool[@Name="VCCLCompilerTool"]') { |compiler|

          arr_includes = Array.new()
          map_includes = Hash.new()
          if compiler.attributes["AdditionalIncludeDirectories"]
            include_dirs = compiler.attributes["AdditionalIncludeDirectories"].split(/[,;]/).sort.each { |s|
                incpath = normalize(s).strip
                #puts "include is '#{incpath}'"
                arr_includes.push(incpath)
            }
	    # these mapping files may contain things such as mapping .vcproj "Vc7/atlmfc/src/mfc" into CMake ${MFC_INCLUDE} var
            read_mappings_combined(filename_map_inc, map_includes)
          end
          cmake_write_build_attributes("include_directories", "", out, arr_includes, map_includes, nil)

          if compiler.attributes["PreprocessorDefinitions"]

            compiler.attributes["PreprocessorDefinitions"].split(";").sort.each { |s|
            str_define, str_setting = s.strip.split(/=/)
            if str_setting.nil?
                    arr_defines.push(str_define)
            else
              if str_setting =~ /[\(\)]+/
                escape_char(str_setting, '\\(')
                escape_char(str_setting, '\\)')
              end
                    arr_defines.push("#{str_define}=#{str_setting}")
            end
            }

          end

          if config_use_of_mfc == 2
            arr_defines.push("_AFXEXT", "_AFXDLL")
          end

	  # TODO: add translation table for specific compiler flag settings such as MinimalRebuild:
	  # simply make reverse use of existing translation table in CMake source.

	  if compiler.attributes["AdditionalOptions"]
	    arr_flags = compiler.attributes["AdditionalOptions"].split(";")
	  end
        }

        config_type = config.attributes["ConfigurationType"].to_i

	# FIXME: hohumm, the position of this hook include is outdated, need to update it
        new_puts_ind(out, "# hook include after all definitions have been made")
        puts_ind(out, "# (but _before_ target is created using the source list!)")
        puts_ind(out, "include(${V2C_HOOK_POST_DEFINITIONS} OPTIONAL)")

        # create a target only in case we do have any meat at all
        #if not main_files[:arr_sub_filters].empty? or not main_files[:arr_files].empty?
        if not arr_sub_sources.empty?

          # first add source reference, then do linker setup, then create target

          new_puts_ind(out, "set(SOURCES")
          $myindent += 2
          arr_sub_sources.each { |group_tag|
            puts_ind(out, "${#{group_tag}}")
          }
          $myindent -= 2
          puts_ind(out, ")")

	  # parse linker configuration...
          arr_dependencies = Array.new()
	  arr_lib_dirs = Array.new()
          config.elements.each('Tool[@Name="VCLinkerTool"]') { |linker|
            deps = linker.attributes["AdditionalDependencies"]
            if deps and deps.length > 0
              deps.split.each { |lib|
                # FIXME possible to use lib = normalize(lib).strip here?
                lib = lib.gsub(/\\/, '/')
                arr_dependencies.push(File.basename(lib, ".lib"))
              }
            end

            lib_dirs = linker.attributes["AdditionalLibraryDirectories"]
            if lib_dirs and lib_dirs.length > 0
              lib_dirs.split(/[,;]/).each { |lib_dir|
                lib_dir = normalize(lib_dir).strip
		  #puts "lib dir is '#{lib_dir}'"
                arr_lib_dirs.push(lib_dir)
              }
            end
	    # TODO: support AdditionalOptions! (mention via
	    # CMAKE_SHARED_LINKER_FLAGS / CMAKE_MODULE_LINKER_FLAGS / CMAKE_EXE_LINKER_FLAGS
	    # depending on target type, and make sure to filter out options pre-defined by CMake platform
	    # setup modules)
          }

	  # write link_directories() (BEFORE establishing a target!)
          arr_lib_dirs.push("${V2C_LIB_DIRS}")

          map_lib_dirs = Hash.new()
          read_mappings_combined(filename_map_lib_dirs, map_lib_dirs)
          cmake_write_build_attributes("link_directories", "", out, arr_lib_dirs, map_lib_dirs, project_name)

          # FIXME: should use a macro like rosbuild_add_executable(),
          # http://www.ros.org/wiki/rosbuild/CMakeLists ,
          # https://kermit.cse.wustl.edu/project/robotics/browser/trunk/vendor/ros/core/rosbuild/rosbuild.cmake?rev=3
          # to be able to detect non-C++ file types within a source file list
          # and add a hook to handle them specially.
          if config_type == 1    # Executable
            target = project_name
            #puts_ind(out, "add_executable_vcproj2cmake( #{project_name} WIN32 ${SOURCES} )")
            # TODO: perhaps for real cross-platform binaries (i.e.
            # console apps not needing a WinMain()), we should detect
            # this and not use WIN32 in this case...
            new_puts_ind(out, "add_executable( #{target} WIN32 ${SOURCES} )")
          elsif config_type == 2    # DLL
            target = project_name
            #puts_ind(out, "add_library_vcproj2cmake( #{project_name} SHARED ${SOURCES} )")
            new_puts_ind(out, "add_library( #{target} SHARED ${SOURCES} )")
          elsif config_type == 4    # Static
            target = project_name
            #puts_ind(out, "add_library_vcproj2cmake( #{project_name} STATIC ${SOURCES} )")
            new_puts_ind(out, "add_library( #{target} STATIC ${SOURCES} )")
          elsif config_type == 0 # seems to be some sort of non-build logical collection project, TODO: investigate!
          elsif
            $stderr.puts "Project type #{config_type} not supported."
            exit 1
          end

	  # write target_link_libraries() in case there's a target
          if not target.nil?
            arr_dependencies.push("${V2C_LIBS}")

            map_dependencies = Hash.new()
            read_mappings_combined(filename_map_dep, map_dependencies)
            cmake_write_build_attributes("target_link_libraries", "", out, arr_dependencies, map_dependencies, project_name)
          end # not target.nil?
        end # not arr_sub_sources.empty?

        new_puts_ind(out, "# e.g. to be used for tweaking target properties etc.")
        puts_ind(out, "include(${V2C_HOOK_POST_TARGET} OPTIONAL)")

        $myindent -= 2
        puts_ind(out, "endif(#{build_type_condition})")

        # NOTE: the commands below can stay in the general section (outside of
        # build_type_condition above), but only since they define
        # configuration-_specific_ settings only!
        if not target.nil?
          map_defines = Hash.new()
          read_mappings_combined(filename_map_def, map_defines)
          puts_ind(out, "if(TARGET #{target})")
          $myindent += 2
          cmake_set_target_property_compile_definitions(target, config_name, arr_defines, map_defines, out)
          cmake_set_target_property_compile_flags(target, config_name, arr_flags, out)
          $myindent -= 2
          puts_ind(out, "endif(TARGET #{target})")
        end
      } # [END per-config handling]

      # we can handle the following target stuff outside per-config handling (reason: see comment above)
      if not target.nil?
        # Make sure to keep CMake Name/Keyword (PROJECT_LABEL / VS_KEYWORD properties) in our converted file, too...
	# Hrmm, both project() _and_ PROJECT_LABEL reference the same project_name?? WEIRD.
	out.puts
	# no need to enclose this within "if(TARGET ...)" here since at this point
	# we really _should_ have a target available,
	# otherwise everything is broken anyway...
	cmake_set_target_property(target, "PROJECT_LABEL", project_name, out)
	project_keyword = project.attributes["Keyword"]
        if not project_keyword.nil?
	  cmake_set_target_property(target, "VS_KEYWORD", project_keyword, out)
        end

        # keep source control integration in our conversion!
        # FIXME: does it really work? Then reply to
        # http://public.kitware.com/mantis/view.php?id=10237 !!
        if not project.attributes["SccProjectName"].nil?
          scc_project_name = project.attributes["SccProjectName"].clone
          # hmm, perhaps need to use CGI.escape since chars other than just '"' might need to be escaped?
          # NOTE: needed to clone() this string above since otherwise modifying (same) source object!!
          # We used to escape_char('"') below, but this was problematic
          # on VS7 .vcproj generator since that one is BUGGY (GIT trunk
          # 201007xx): it should escape quotes into XMLed "&quot;" yet
          # it doesn't. Thus it's us who has to do that and pray that it
          # won't fail on us... (but this bogus escaping within
          # CMakeLists.txt space might lead to severe trouble
          # with _other_ IDE generators which cannot deal with a raw "&quot;").
          # Note that perhaps we should also escape all other chars
          # as in CMake's EscapeForXML() method.
          scc_project_name.gsub!(/"/, "&quot;")
	  # hrmm, turns out having SccProjectName is no guarantee that both SccLocalPath and SccProvider
	  # exist, too... (one project had SccProvider missing)
	  if not project.attributes["SccLocalPath"].nil?
            scc_local_path = project.attributes["SccLocalPath"].clone
	  end
	  if not project.attributes["SccProvider"].nil?
            scc_provider = project.attributes["SccProvider"].clone
	  end
	  out.puts
	  cmake_set_target_property(target, "VS_SCC_PROJECTNAME", scc_project_name, out)
          if scc_local_path
            escape_backslash(scc_local_path)
            escape_char(scc_local_path, '"')
	    cmake_set_target_property(target, "VS_SCC_LOCALPATH", scc_local_path, out)
          end
          if scc_provider
            escape_char(scc_provider, '"')
	    cmake_set_target_property(target, "VS_SCC_PROVIDER", scc_provider, out)
          end
        end
      end # not target.nil?
      new_puts_ind(out, "v2c_rebuild_on_update(#{project_name} \"${CMAKE_CURRENT_SOURCE_DIR}/#{p_vcproj.basename}\" ${CMAKE_CURRENT_LIST_FILE} \"#{script_name}\" \"#{$master_project_dir}\")")
    }
    new_puts_ind(out, "include(${V2C_HOOK_POST} OPTIONAL)")
  }
  # Close file, since Fileutils.mv on an open file will barf on XP
  out.close
}

# make sure to close that one as well...
tmpfile.close

if File.exists?(output_file)
  mv(output_file, output_file + ".backup")
end
mv(tmpfile.path, output_file)

puts "Wrote #{output_file}"
puts "Finished. You should make sure to have all important v2c settings includes such as vcproj2cmake_defs.cmake somewhere in your CMAKE_MODULE_PATH"
