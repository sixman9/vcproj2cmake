#!/usr/bin/env ruby

# Given a Visual Studio project (.vcproj, .vcxproj),
# create a CMakeLists.txt file which optionally allows
# for ongoing side-by-side operation (e.g. on Linux, Mac)
# together with the existing static .vc[x]proj project on the Windows side.
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
require 'find' # Find.find()

# http://devblog.vworkapp.com/post/910714976/best-practice-for-rubys-require

# HACK: have $script_dir as global variable currently
$script_dir = File.dirname(__FILE__)

$LOAD_PATH.unshift($script_dir + '/.') unless $LOAD_PATH.include?($script_dir + '/.')
$LOAD_PATH.unshift($script_dir + '/./lib') unless $LOAD_PATH.include?($script_dir + '/./lib')

# load common settings
load 'vcproj2cmake_settings.rb'

require 'vcproj2cmake/v2c_core' # (currently) large amount of random "core" functionality

################
#     MAIN     #
################

script_name = $0

# Usage: vcproj2cmake.rb <input.vc[x]proj> [<output CMakeLists.txt>] [<master project directory>]

#*******************************************************************************************************
# Check for command-line input errors
# -----------------------------------
cl_error = ''

vcproj_filename = nil

if ARGV.length < 1
   cl_error = "*** Too few arguments\n"
else
   str_vcproj_filename = ARGV.shift
   #puts "First arg is #{str_vcproj_filename}"

   # Discovered Ruby 1.8.7(?) BUG: kills extension on duplicate slashes: ".//test.ext"
   # OK: ruby-1.8.5-5.el5_4.8, KO: u10.04 ruby1.8 1.8.7.249-2 and ruby1.9.1 1.9.1.378-1
   # http://redmine.ruby-lang.org/issues/show/3882
   # TODO: add a version check to conditionally skip this cleanup effort?
   vcproj_filename_full = Pathname.new(str_vcproj_filename).cleanpath

   $arr_plugin_parser.each { |plugin_parser_curr|
     vcproj_filename_test = vcproj_filename_full.clone
     parser_extension = ".#{plugin_parser_curr.extension_name}"
     if File.extname(vcproj_filename_test) == parser_extension
       vcproj_filename = vcproj_filename_test
       break
     else
        # The first argument on the command-line did not have a '.vcproj' extension.
        # If the local directory contains file "ARGV[0].vcproj" then use it, else error.
        # (Note:  Only '+' works here for concatenation, not '<<'.)
        vcproj_filename_test += parser_extension
  
        #puts "Looking for #{vcproj_filename}"
        if FileTest.exist?(vcproj_filename_test)
          vcproj_filename = vcproj_filename_test
	  break
        end
     end
   }
end

if vcproj_filename.nil?
  str_parser_descrs = ''
  $arr_plugin_parser.each { |plugin_parser_named|
    str_parser_descr_elem = ".#{plugin_parser_named.extension_name} [#{plugin_parser_named.parser_name}]"
    str_parser_descrs += str_parser_descr_elem + ', '
  }
  cl_error = "*** The first argument must be the project name / file (supported parsers: #{str_parser_descrs})\n"
end

if ARGV.length > 3
   cl_error = cl_error << "*** Too many arguments\n"
end

unless cl_error == ''
   puts %{\
*** Input Error *** #{script_name}
#{cl_error}

Usage: vcproj2cmake.rb <project input file> [<output CMakeLists.txt>] [<master project directory>]

project input file can e.g. have .vcproj or .vcxproj extension.
}

   exit 1
end

# TODO: create the proper parser object!
# "Dynamically instantiate a class"
#   http://www.ruby-forum.com/topic/141758

#if File.extname(vcproj_filename) == '.vcproj'
#end

# Process the optional command-line arguments
# -------------------------------------------
# FIXME:  Variables 'output_file' and 'master_project_dir' are position-dependent on the
# command-line, if they are entered.  The script does not have a way to distinguish whether they
# were input in the wrong order.  A potential fix is to associate flags with the arguments, like
# '-i <input.vcproj> [-o <output CMakeLists.txt>] [-d <master project directory>]' and then parse
# them accordingly.  This lets them be entered in any order and removes ambiguity.
# -------------------------------------------
output_file = ARGV.shift or output_file = File.join(File.dirname(vcproj_filename), 'CMakeLists.txt')

# Master (root) project dir defaults to current dir--useful for simple, single-.vcproj conversions.
master_project_dir = ARGV.shift
if not master_project_dir
  master_project_dir = '.'
end

v2c_convert_project_outer(script_name, vcproj_filename, output_file, master_project_dir)
