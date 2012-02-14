### USER-CONFIGURABLE SECTION ###

# global variable to indicate whether we want debug output or not
$v2c_debug = false

# Initial number of spaces for indenting
v2c_generator_indent_num_spaces = 0

# Number of spaces to increment by
$v2c_generator_indent_step = 2

### USER-CONFIGURABLE SECTION END ###


require 'vcproj2cmake/util_file' # V2C_Util_File.cmp()

# At least currently, this is a custom plugin mechanism.
# It doesn't have anything to do with e.g.
# Ruby on Rails Plugins, which is described by
# "15 Rails mit Plug-ins erweitern"
#   http://openbook.galileocomputing.de/ruby_on_rails/ruby_on_rails_15_001.htm

$arr_plugin_parser = Array.new

class V2C_Core_Plugin_Info
  def initialize
    @version = 0 # plugin API version that this plugin supports
  end
  attr_accessor :version
end

class V2C_Core_Plugin_Info_Parser < V2C_Core_Plugin_Info
  def initialize
    super()
    @parser_name = nil
    @extension_name = nil
  end
  attr_accessor :parser_name
  attr_accessor :extension_name
end

def V2C_Core_Add_Plugin_Parser(plugin_parser)
  if plugin_parser.version == 1
    $arr_plugin_parser.push(plugin_parser)
    puts "registered parser plugin #{plugin_parser.parser_name} (.#{plugin_parser.extension_name})"
    return true
  else
    puts "parser plugin #{plugin_parser.parser_name} indicates wrong version #{plugin_parser.version}"
    return false
  end
end

# Use specially named "v2c_plugins" dir to avoid any resemblance/clash
# with standard Ruby on Rails plugins mechanism.
v2c_plugin_dir = "#{$script_dir}/v2c_plugins"

Find.find(v2c_plugin_dir) { |f_plugin|
  if f_plugin =~ /v2c_(parser|generator)_.*\.rb$/
    puts "loading plugin #{f_plugin}!"
    load f_plugin
  end
  # register project file extension name in plugin manager array, ...
}

# TODO: to be automatically filled in from parser plugins

plugin_parser_vs10 = V2C_Core_Plugin_Info_Parser.new

plugin_parser_vs10.version = 1
plugin_parser_vs10.parser_name = 'Visual Studio 10'
plugin_parser_vs10.extension_name = 'vcxproj'

V2C_Core_Add_Plugin_Parser(plugin_parser_vs10)

plugin_parser_vs7_vfproj = V2C_Core_Plugin_Info_Parser.new

plugin_parser_vs7_vfproj.version = 1
plugin_parser_vs7_vfproj.parser_name = 'Visual Studio 7+ (Fortran .vfproj)'
plugin_parser_vs7_vfproj.extension_name = 'vfproj'

V2C_Core_Add_Plugin_Parser(plugin_parser_vs7_vfproj)


#*******************************************************************************************************

# since the .vcproj multi-configuration environment has some settings
# that can be specified per-configuration (target type [lib/exe], include directories)
# but where CMake unfortunately does _NOT_ offer a configuration-specific equivalent,
# we need to fall back to using the globally-scoped CMake commands (include_directories() etc.).
# But at least let's optionally allow the user to precisely specify which configuration
# (empty [first config], "Debug", "Release", ...) he wants to have
# these settings taken from.
$config_multi_authoritative = ''

FILENAME_MAP_DEF = "#{$v2c_config_dir_local}/define_mappings.txt"
FILENAME_MAP_DEP = "#{$v2c_config_dir_local}/dependency_mappings.txt"
FILENAME_MAP_LIB_DIRS = "#{$v2c_config_dir_local}/lib_dirs_mappings.txt"


def log_debug(str)
  return if not $v2c_debug
  puts str
end

def log_info(str)
  # We choose to not log an INFO: prefix (reduce log spew).
  puts str
end

def log_warn(str); puts "WARNING: #{str}" end

def log_error(str); $stderr.puts "ERROR: #{str}" end

def log_fatal(str); log_error "#{str}. Aborting!"; exit 1 end

# Change \ to /, and remove leading ./
def normalize_path(p)
  felems = p.gsub('\\', '/').split('/')
  # DON'T eradicate single '.' !!
  felems.shift if felems[0] == '.' and felems.size > 1
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
  in_string.gsub!(/\\/, '\\\\\\\\')
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
  #log_debug mappings['kernel32']
  #log_debug mappings['mytest']
end

# Read mappings of both current project and source root.
# Ordering should definitely be _first_ current project,
# _then_ global settings (a local project may have specific
# settings which should _override_ the global defaults).
def read_mappings_combined(filename_mappings, mappings, master_project_dir)
  read_mappings(filename_mappings, mappings)
  return if not master_project_dir
  # read common mappings (in source root) to be used by all sub projects
  read_mappings("#{master_project_dir}/#{filename_mappings}", mappings)
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
      map_defs.each do |key_regex, value|
        if curr_defn =~ /^#{key_regex}$/
          log_debug "KEY: #{key_regex} curr_defn #{curr_defn}"
          map_line = value
          break
        end
      end
    end
    if map_line.nil?
      # no mapping? --> unconditionally use the original define
      push_platform_defn(platform_defs, 'ALL', curr_defn)
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
          platform = 'ALL'
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
# Global generator: generates/manages parts which are not project-local/target-related (i.e., manages things related to the _entire solution_ configuration)
# local generator: has a Makefile member (which contains a list of targets),
#   then generates project files by iterating over the targets via a newly generated target generator each.
# target generator: generates targets. This is the one creating/producing the output file stream. Not provided by all generators (VS10 yes, VS7 no).

class V2C_Info_Condition
  def initialize(str_condition)
    @str_condition = str_condition
  end
end

class V2C_Info_Elem_Base
  def initialize
    @condition = nil # V2C_Info_Condition
  end
end

class V2C_Info_Include_Dir < V2C_Info_Elem_Base
  def initialize
    super()
    @dir = String.new
    @attr_after = 0
    @attr_before = 0
    @attr_system = 0
  end
  attr_accessor :dir
  attr_accessor :attr_after
  attr_accessor :attr_before
  attr_accessor :attr_system
end

class V2C_Tool_Compiler_Info
  def initialize
    @arr_flags = Array.new
    @arr_info_include_dirs = Array.new
    @hash_defines = Hash.new
  end
  attr_accessor :arr_flags
  attr_accessor :arr_info_include_dirs
  attr_accessor :hash_defines
end

class V2C_Tool_Linker_Info
  def initialize
    @arr_dependencies = Array.new
    @arr_lib_dirs = Array.new
  end
  attr_accessor :arr_dependencies
  attr_accessor :arr_lib_dirs
end

class V2C_Config_Base_Info
  def initialize
    @build_type = 0 # WARNING: it may contain spaces!
    @platform = 0
    @cfg_type = 0
    @use_of_mfc = 0 # TODO: perhaps make ATL/MFC values an enum?
    @use_of_atl = 0
    @charset = 0 # Simply uses VS7 values for now. TODO: should use our own enum definition or so.
    @whole_program_optimization = 0 # Simply uses VS7 values for now. TODO: should use our own enum definition or so.
    @use_debug_libs = false
    @arr_compiler_info = Array.new
    @arr_linker_info = Array.new
  end
  attr_accessor :build_type
  attr_accessor :platform
  attr_accessor :cfg_type
  attr_accessor :use_of_mfc
  attr_accessor :use_of_atl
  attr_accessor :charset
  attr_accessor :whole_program_optimization
  attr_accessor :use_debug_libs
  attr_accessor :arr_compiler_info
  attr_accessor :arr_linker_info
end

class V2C_Project_Config_Info < V2C_Config_Base_Info
  def initialize
    super()
    @output_dir = nil
    @intermediate_dir = nil
  end
  attr_accessor :output_dir
  attr_accessor :intermediate_dir
end

class V2C_File_Config_Info < V2C_Config_Base_Info
  def initialize
    super()
    @excluded_from_build = false
  end
  attr_accessor :excluded_from_build
end

class V2C_Makefile
  def initialize
    @config_info = V2C_Project_Config_Info.new
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

# Well, in fact in Visual Studio, "target" and "project"
# seem to be pretty much synonymous...
# FIXME: we should still do better separation between these two...
class V2C_Target
  def initialize
    @type = nil # project type
    @name = nil
    @creator = nil
    @guid = nil
    @root_namespace = nil
    @version = nil
    @vs_keyword = nil
    @scc_info = V2C_SCC_Info.new
    # semi-HACK: we need this variable, since we need to be able
    # to tell whether we're able to build a target
    # (i.e. whether we have any build units i.e.
    # implementation files / non-header files),
    # otherwise we should not add a target since CMake will
    # complain with "Cannot determine link language for target "xxx"".
    @have_build_units = false
  end

  attr_accessor :type
  attr_accessor :name
  attr_accessor :creator
  attr_accessor :guid
  attr_accessor :root_namespace
  attr_accessor :version
  attr_accessor :vs_keyword
  attr_accessor :scc_info
  attr_accessor :have_build_units
end

class V2C_BaseGlobalGenerator
  def initialize(master_project_dir)
    @filename_map_inc = "#{$v2c_config_dir_local}/include_mappings.txt"
    @master_project_dir = master_project_dir
    @map_includes = Hash.new
    read_mappings_includes()
  end

  attr_accessor :map_includes

  private

  def read_mappings_includes
    # These mapping files may contain things such as mapping .vcproj "Vc7/atlmfc/src/mfc"
    # into CMake "SYSTEM ${MFC_INCLUDE}" information.
    read_mappings_combined(@filename_map_inc, @map_includes, @master_project_dir)
  end
end


CMAKE_VAR_MATCH_REGEX = '\\$\\{[[:alnum:]_]+\\}'
CMAKE_ENV_VAR_MATCH_REGEX = '\\$ENV\\{[[:alnum:]_]+\\}'

# HACK: Since we have several instances of the generator syntax base class,
# we cannot have indent_now as class member since we'd have multiple
# disconnected instances... (TODO: add common per-file syntax generator object as member of generator classes)
$indent_now = v2c_generator_indent_num_spaces

# Contains functionality common to _any_ file-based generator
class V2C_TextStreamSyntaxGeneratorBase
  def initialize(out, indent_step, comments_level)
    @out = out
    @indent_step = indent_step
    @comments_level = comments_level
  end

  def generated_comments_level; return @comments_level end

  def get_indent; return $indent_now end

  def indent_more; $indent_now += @indent_step end
  def indent_less; $indent_now -= @indent_step end

  def write_block(block)
    block.split("\n").each { |line|
      write_line(line)
    }
  end
  def write_line(part)
    @out.print ' ' * get_indent()
    @out.puts part
  end

  def write_empty_line; @out.puts end
  def write_new_line(part)
    write_empty_line()
    write_line(part)
  end
end

class V2C_CMakeSyntaxGenerator < V2C_TextStreamSyntaxGeneratorBase
  VCPROJ2CMAKE_FUNC_CMAKE = 'vcproj2cmake_func.cmake'
  V2C_ATTRIBUTE_NOT_PROVIDED_MARKER = 'V2C_NOT_PROVIDED'
  def initialize(out)
    super(out, $v2c_generator_indent_step, $v2c_generated_comments_level)
    @streamout = self # reference to the stream output handler; to be changed into something that is being passed in externally, for the _one_ file that we (and other generators) are working on

    # internal CMake generator helpers
  end

  def write_comment_at_level(level, block)
    return if generated_comments_level() < level
    block.split("\n").each { |line|
      write_line("# #{line}")
    }
  end
  def write_command_list(cmake_command, cmake_command_arg, arr_elems)
    if cmake_command_arg.nil?
      cmake_command_arg = ''
    end
    write_line("#{cmake_command}(#{cmake_command_arg}")
    indent_more()
      arr_elems.each do |curr_elem|
        write_line(curr_elem)
      end
    indent_less()
    write_line(')')
  end
  def write_command_list_quoted(cmake_command, cmake_command_arg, arr_elems)
    arr_elems_quoted = Array.new
    arr_elems.each do |curr_elem|
      # HACK for nil input of SCC info.
      curr_elem = '' if curr_elem.nil?
      arr_elems_quoted.push(element_handle_quoting(curr_elem))
    end
    write_command_list(cmake_command, cmake_command_arg, arr_elems_quoted)
  end
  def write_command_single_line(cmake_command, cmake_command_args)
    write_line("#{cmake_command}(#{cmake_command_args})")
  end
  def write_list(list_var_name, arr_elems)
    write_command_list('set', list_var_name, arr_elems)
  end
  def write_list_quoted(list_var_name, arr_elems)
    write_command_list_quoted('set', list_var_name, arr_elems)
  end

  # WIN32, MSVC, ...
  def write_conditional_if(str_conditional)
    return if str_conditional.nil?
    write_command_single_line('if', str_conditional)
    indent_more()
  end
  def write_conditional_else(str_conditional)
    return if str_conditional.nil?
    indent_less()
    write_command_single_line('else', str_conditional)
    indent_more()
  end
  def write_conditional_end(str_conditional)
    return if str_conditional.nil?
    indent_less()
    write_command_single_line('endif', str_conditional)
  end
  def get_keyword_bool(setting); return setting ? 'true' : 'false' end
  def write_set_var(var_name, setting)
    str_args = "#{var_name} #{setting}"
    write_command_single_line('set', str_args)
  end
  def write_set_var_bool(var_name, setting)
    write_set_var(var_name, get_keyword_bool(setting))
  end
  def write_set_var_bool_conditional(var_name, str_condition)
    write_conditional_if(str_condition)
      write_set_var_bool(var_name, true)
    write_conditional_else(str_condition)
      write_set_var_bool(var_name, false)
    write_conditional_end(str_condition)
  end
  def write_include(include_file, optional = false)
    include_file_args = element_handle_quoting(include_file)
    if optional
      include_file_args += ' OPTIONAL'
    end
    write_command_single_line('include', include_file_args)
  end
  def write_vcproj2cmake_func_comment()
    write_comment_at_level(2, "See function implementation/docs in #{$v2c_module_path_root}/#{VCPROJ2CMAKE_FUNC_CMAKE}")
  end
  def write_cmake_policy(policy_num, set_to_new, comment)
    str_policy = '%s%04d' % [ 'CMP', policy_num ]
    str_conditional = "POLICY #{str_policy}"
    str_OLD_NEW = set_to_new ? 'NEW' : 'OLD'
    write_conditional_if(str_conditional)
      if not comment.nil?
        write_comment_at_level(3, comment)
      end
      str_set_policy = "SET #{str_policy} #{str_OLD_NEW}"
      write_command_single_line('cmake_policy', str_set_policy)
    write_conditional_end(str_conditional)
  end

  # analogous to CMake separate_arguments() command
  def separate_arguments(array_in); array_in.join(';') end

  private

  # (un)quote strings as needed
  #
  # Once we added a variable in the string,
  # we definitely _need_ to have the resulting full string quoted
  # in the generated file, otherwise we won't obey
  # CMake filesystem whitespace requirements! (string _variables_ _need_ quoting)
  # However, there is a strong argument to be made for applying the quotes
  # on the _generator_ and not _parser_ side, since it's a CMake syntax attribute
  # that such strings need quoting.
  def element_handle_quoting(elem)
    # Determine whether quoting needed
    # (in case of whitespace or variable content):
    #if elem.match(/\s|#{CMAKE_VAR_MATCH_REGEX}|#{CMAKE_ENV_VAR_MATCH_REGEX}/)
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
    # And an empty string needs quoting, too!!
    # (this empty content might be a counted parameter of a function invocation,
    # in which case unquoted syntax would implicitly throw away that empty parameter!
    if elem.match(/[^\}\s]\s|\s[^\s\$]|^$/)
      needs_quoting = true
    end
    if elem.match(/".*"/)
      has_quotes = true
    end
    #puts "QUOTING: elem #{elem} needs_quoting #{needs_quoting} has_quotes #{has_quotes}"
    if needs_quoting and not has_quotes
      #puts 'QUOTING: do quote!'
      return "\"#{elem}\""
    end
    if not needs_quoting and has_quotes
      #puts 'QUOTING: do UNquoting!'
      return elem.gsub(/"(.*)"/, '\1')
    end
      #puts 'QUOTING: do no changes!'
    return elem
  end
end

class V2C_CMakeGlobalGenerator < V2C_CMakeSyntaxGenerator
  def initialize(out)
    super(out)
  end
  def put_configuration_types(configuration_types)
    configuration_types_list = separate_arguments(configuration_types)
    write_set_var('CMAKE_CONFIGURATION_TYPES', "\"#{configuration_types_list}\"")
  end

  private
end

class V2C_CMakeLocalGenerator < V2C_CMakeSyntaxGenerator
  def initialize(out)
    super(out)
    # FIXME: handle arr_config_var_handling appropriately
    # (place the translated CMake commands somewhere suitable)
    @arr_config_var_handling = Array.new
  end
  def put_file_header
    put_file_header_temporary_marker()
    put_file_header_cmake_minimum_version()
    put_file_header_cmake_policies()

    put_cmake_module_path()
    put_var_config_dir_local()
    put_include_vcproj2cmake_func()
    put_hook_pre()
  end
  def put_project(project_name, arr_languages = nil)
    log_fatal 'missing project name' if project_name.nil?
    project_name_and_attrs = project_name
    if not arr_languages.nil?
      arr_languages.each { |elem_lang|
        project_name_and_attrs += " #{elem_lang}"
      }
    end
    write_command_single_line('project', project_name_and_attrs)
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
    write_include('MasterProjectDefaults_vcproj2cmake', true)
  end
  def put_hook_project
    write_comment_at_level(2, \
	"hook e.g. for invoking Find scripts as expected by\n" \
	"the _LIBRARIES / _INCLUDE_DIRS mappings created\n" \
	"by your include/dependency map files." \
    )
    write_include('${V2C_HOOK_PROJECT}', true)
  end

  def put_include_project_source_dir
    # AFAIK .vcproj implicitly adds the project root to standard include path
    # (for automatic stdafx.h resolution etc.), thus add this
    # (and make sure to add it with high priority, i.e. use BEFORE).
    # For now sitting in LocalGenerator and not per-target handling since this setting is valid for the entire directory.
    write_empty_line()
    write_command_single_line('include_directories', 'BEFORE "${PROJECT_SOURCE_DIR}"')
  end
  def put_cmake_mfc_atl_flag(config_info)
    # Hmm, do we need to actively _reset_ CMAKE_MFC_FLAG / CMAKE_ATL_FLAG
    # (i.e. _unconditionally_ set() it, even if it's 0),
    # since projects in subdirs shouldn't inherit?
    # Given the discussion at
    # "[CMake] CMAKE_MFC_FLAG is inherited in subdirectory ?"
    #   http://www.cmake.org/pipermail/cmake/2009-February/026896.html
    # I'd strongly assume yes...
    # See also "Re: [CMake] CMAKE_MFC_FLAG not working in functions"
    #   http://www.mail-archive.com/cmake@cmake.org/msg38677.html

    #if config_info.use_of_mfc > 0
      write_set_var('CMAKE_MFC_FLAG', config_info.use_of_mfc)
    #end
    # ok, there's no CMAKE_ATL_FLAG yet, AFAIK, but still prepare
    # for it (also to let people probe on this in hook includes)
    #if config_info.use_of_atl > 0
      # TODO: should also set the per-configuration-type variable variant
      #write_new_line("set(CMAKE_ATL_FLAG #{config_info.use_of_atl})")
      write_set_var('CMAKE_ATL_FLAG', config_info.use_of_atl)
    #end
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
    return if arr_includes.empty?
    arr_includes_translated = Array.new
    arr_includes.each { |elem_inc_dir|
      elem_inc_dir = vs7_create_config_variable_translation(elem_inc_dir, @arr_config_var_handling)
      arr_includes_translated.push(elem_inc_dir)
    }
    write_build_attributes('include_directories', arr_includes_translated, map_includes, nil)
  end

  def write_link_directories(arr_lib_dirs, map_lib_dirs)
    arr_lib_dirs_translated = Array.new
    arr_lib_dirs.each { |elem_lib_dir|
      elem_lib_dir = vs7_create_config_variable_translation(elem_lib_dir, @arr_config_var_handling)
      arr_lib_dirs_translated.push(elem_lib_dir)
    }
    arr_lib_dirs_translated.push('${V2C_LIB_DIRS}')
    write_comment_at_level(3, \
      "It is said to be much preferable to be able to use target_link_libraries()\n" \
      "rather than the very unspecific link_directories()." \
    )
    write_build_attributes('link_directories', arr_lib_dirs_translated, map_lib_dirs, nil)
  end
  def write_directory_property_compile_flags(attr_opts)
    return if attr_opts.nil?
    write_empty_line()
    # Query WIN32 instead of MSVC, since AFAICS there's nothing in the
    # .vcproj to indicate tool specifics, thus these seem to
    # be settings for ANY PARTICULAR tool that is configured
    # on the Win32 side (.vcproj in general).
    str_platform = 'WIN32'
    write_conditional_if(str_platform)
      write_command_single_line('set_property', "DIRECTORY APPEND PROPERTY COMPILE_FLAGS #{attr_opts}")
    write_conditional_end(str_platform)
  end
  # FIXME private!
  def write_build_attributes(cmake_command, arr_defs, map_defs, cmake_command_arg)
    # the container for the list of _actual_ dependencies as stated by the project
    all_platform_defs = Hash.new
    parse_platform_conversions(all_platform_defs, arr_defs, map_defs)
    all_platform_defs.each { |key, arr_platdefs|
      #log_info "arr_platdefs: #{arr_platdefs}"
      next if arr_platdefs.empty?
      arr_platdefs.uniq!
      write_empty_line()
      str_platform = key if not key.eql?('ALL')
      write_conditional_if(str_platform)
        write_command_list_quoted(cmake_command, cmake_command_arg, arr_platdefs)
      write_conditional_end(str_platform)
    }
  end
  def put_var_converter_script_location(script_location_relative_to_master)
    # For the CMakeLists.txt rebuilder (automatic rebuild on file changes),
    # add handling of a script file location variable, to enable users
    # to override the script location if needed.
    write_empty_line()
    write_comment_at_level(1, \
      "user override mechanism (allow defining custom location of script)" \
    )
    str_conditional = 'NOT V2C_SCRIPT_LOCATION'
    write_conditional_if(str_conditional)
      # NOTE: we'll make V2C_SCRIPT_LOCATION express its path via
      # relative argument to global CMAKE_SOURCE_DIR and _not_ CMAKE_CURRENT_SOURCE_DIR,
      # (this provision should even enable people to manually relocate
      # an entire sub project within the source tree).
      write_set_var('V2C_SCRIPT_LOCATION', "\"${CMAKE_SOURCE_DIR}/#{script_location_relative_to_master}\"")
    write_conditional_end(str_conditional)
  end
  def write_func_v2c_post_setup(project_name, project_keyword, orig_project_file_basename)
    # Rationale: keep count of generated lines of CMakeLists.txt to a bare minimum -
    # call v2c_post_setup(), by simply passing all parameters that are _custom_ data
    # of the current generated CMakeLists.txt file - all boilerplate handling functionality
    # that's identical for each project should be implemented by the v2c_post_setup() function
    # _internally_.
    write_vcproj2cmake_func_comment()
    if project_keyword.nil?
	project_keyword = V2C_ATTRIBUTE_NOT_PROVIDED_MARKER
    end
    arr_func_args = [ project_name, project_keyword, "${CMAKE_CURRENT_SOURCE_DIR}/#{orig_project_file_basename}", '${CMAKE_CURRENT_LIST_FILE}' ] 
    write_command_list_quoted('v2c_post_setup', project_name, arr_func_args)
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
    write_command_single_line('cmake_minimum_required', 'VERSION 2.6')
  end
  def put_file_header_cmake_policies
    str_conditional = 'COMMAND cmake_policy'
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
    #write_new_line("set(V2C_MASTER_PROJECT_DIR \"#{@master_project_dir}\")")
    write_empty_line()
    write_set_var('V2C_MASTER_PROJECT_DIR', '"${CMAKE_SOURCE_DIR}"')
    # NOTE: use set() instead of list(APPEND...) to _prepend_ path
    # (otherwise not able to provide proper _overrides_)
    write_set_var('CMAKE_MODULE_PATH', "\"${V2C_MASTER_PROJECT_DIR}/#{$v2c_module_path_local}\" ${CMAKE_MODULE_PATH}")
  end
  def put_var_config_dir_local
    # "export" our internal $v2c_config_dir_local variable (to be able to reference it in CMake scripts as well)
    write_set_var('V2C_CONFIG_DIR_LOCAL', "\"#{$v2c_config_dir_local}\"")
  end
  def put_include_vcproj2cmake_func
    write_empty_line()
    write_comment_at_level(2, \
      "include the main file for pre-defined vcproj2cmake helper functions\n" \
      "This module will also include the configuration settings definitions module" \
    )
    write_include('vcproj2cmake_func')
  end
  def put_hook_pre
    # this CMakeLists.txt-global optional include could be used e.g.
    # to skip the entire build of this file on certain platforms:
    # if(PLATFORM) message(STATUS "not supported") return() ...
    # (note that we appended CMAKE_MODULE_PATH _prior_ to this include()!)
    write_include('${V2C_CONFIG_DIR_LOCAL}/hook_pre.txt', true)
  end
end

# Hrmm, I'm not quite sure yet where to aggregate this function...
# (missing some proper generator base class or so...)
def v2c_generator_validate_file(project_dir, file_relative, project_name)
  if $v2c_validate_vcproj_ensure_files_ok
    # TODO: perhaps we need to add a permissions check, too?
    if not File.exist?("#{project_dir}/#{file_relative}")
      log_error "File #{file_relative} as listed in project #{project_name} does not exist!? (perhaps filename with wrong case, or wrong path, ...)"
      if $v2c_validate_vcproj_abort_on_error > 0
	# FIXME: should be throwing an exception, to not exit out
	# on entire possibly recursive (global) operation
        # when a single project is in error...
        log_fatal "Improper original file - will abort and NOT generate a broken converted project file. Please fix content of the original project file!"
      end
    end
  end
end

class V2C_CMakeFileListGenerator < V2C_CMakeSyntaxGenerator
  def initialize(out, project_name, project_dir, files_str, parent_source_group, arr_sub_sources_for_parent)
    super(out)
    @project_name = project_name
    @project_dir = project_dir
    @files_str = files_str
    @parent_source_group = parent_source_group
    @arr_sub_sources_for_parent = arr_sub_sources_for_parent
  end
  def generate; put_file_list_recursive(@files_str, @parent_source_group, @arr_sub_sources_for_parent) end

  # Hrmm, I'm not quite sure yet where to aggregate this function...
  def get_filter_group_name(filter_info); return filter_info.nil? ? 'COMMON' : filter_info.name; end

  def put_file_list_recursive(files_str, parent_source_group, arr_sub_sources_for_parent)
    filter_info = files_str[:filter_info]
    group_name = get_filter_group_name(filter_info)
      log_debug "#{self.class.name}: #{group_name}"
    if not files_str[:arr_sub_filters].nil?
      arr_sub_filters = files_str[:arr_sub_filters]
    end
    if not files_str[:arr_files].nil?
      arr_local_sources = Array.new
      files_str[:arr_files].each { |file|
        f = file.path_relative

	v2c_generator_validate_file(@project_dir, f, @project_name)

        ## Ignore header files
        #return if f =~ /\.(h|H|lex|y|ico|bmp|txt)$/
        # No we should NOT ignore header files: if they aren't added to the target,
        # then VS won't display them in the file tree.
        next if f =~ /\.(lex|y|ico|bmp|txt)$/
  
        # Verbosely ignore IDL generated files
        if f =~/_(i|p).c$/
          # see file_mappings.txt comment above
          log_info "#{@project_name}::#{f} is an IDL generated file: skipping! FIXME: should be platform-dependent."
          included_in_build = false
          next # no complex handling, just skip
        end
  
        # Verbosely ignore .lib "sources"
        if f =~ /\.lib$/
          # probably these entries are supposed to serve as dependencies
          # (i.e., non-link header-only include dependency, to ensure
          # rebuilds in case of foreign-library header file changes).
          # Not sure whether these were added by users or
          # it's actually some standard MSVS mechanism... FIXME
          log_info "#{@project_name}::#{f} registered as a \"source\" file!? Skipping!"
          included_in_build = false
          return # no complex handling, just return
        end
  
        arr_local_sources.push(f)
      }
    end
  
    # TODO: CMake is said to have a weird bug in case of parent_source_group being "Source Files":
    # "Re: [CMake] SOURCE_GROUP does not function in Visual Studio 8"
    #   http://www.mail-archive.com/cmake@cmake.org/msg05002.html
    if parent_source_group.nil?
      this_source_group = ''
    else
      if parent_source_group == ''
        this_source_group = group_name
      else
        this_source_group = "#{parent_source_group}\\\\#{group_name}"
      end
    end
  
    # process sub-filters, have their main source variable added to arr_my_sub_sources
    arr_my_sub_sources = Array.new
    if not arr_sub_filters.nil?
      indent_more()
        arr_sub_filters.each { |subfilter|
          #log_info "writing: #{subfilter}"
          put_file_list_recursive(subfilter, this_source_group, arr_my_sub_sources)
        }
      indent_less()
    end
  
    group_tag = this_source_group.clone.gsub(/( |\\)/,'_')
  
    # process our hierarchy's own files
    if not arr_local_sources.nil?
      source_files_variable = "SOURCES_files_#{group_tag}"
      write_list_quoted(source_files_variable, arr_local_sources)
      # create source_group() of our local files
      if not parent_source_group.nil?
        source_group_args = "\"#{this_source_group}\" "
        # use filter regex if available: have it generated as source_group(REGULAR_EXPRESSION "regex" ...).
        filter_regex_str = nil
        if not filter_info.nil?
          filter_regex = filter_info.attr_scfilter
          if not filter_regex.nil?
            source_group_args += "REGULAR_EXPRESSION \"#{filter_regex}\" "
          end
        end
        source_group_args += "FILES ${#{source_files_variable}}"
        write_command_single_line('source_group', source_group_args)
      end
    end
    if not source_files_variable.nil? or not arr_my_sub_sources.empty?
      sources_variable = "SOURCES_#{group_tag}"
      arr_source_vars = Array.new
      # dump sub filters...
      arr_my_sub_sources.each { |sources_elem|
        arr_source_vars.push("${#{sources_elem}}")
      }
      # ...then our own files
      if not source_files_variable.nil?
        arr_source_vars.push("${#{source_files_variable}}")
      end
      write_empty_line()
      write_list_quoted(sources_variable, arr_source_vars)
      # add our source list variable to parent return
      arr_sub_sources_for_parent.push(sources_variable)
    end
  end
end

class V2C_CMakeTargetGenerator < V2C_CMakeSyntaxGenerator
  def initialize(target, project_dir, localGenerator, out)
    super(out)
    @target = target
    @project_dir = project_dir
    @localGenerator = localGenerator
  end

  def put_file_list(project_name, files_str, parent_source_group, arr_sub_sources_for_parent)
    filelist_generator = V2C_CMakeFileListGenerator.new(@out, project_name, @project_dir, files_str, parent_source_group, arr_sub_sources_for_parent)
    filelist_generator.generate
  end
  def put_source_vars(arr_sub_source_list_var_names)
    arr_source_vars = Array.new
    arr_sub_source_list_var_names.each { |sources_elem|
	arr_source_vars.push("${#{sources_elem}}")
    }
    write_empty_line()
    write_list_quoted('SOURCES', arr_source_vars)
  end
  def put_hook_post_sources; write_include('${V2C_HOOK_POST_SOURCES}', true) end
  def put_hook_post_definitions
    write_empty_line()
    write_comment_at_level(1, \
	"hook include after all definitions have been made\n" \
	"(but _before_ target is created using the source list!)" \
    )
    write_include('${V2C_HOOK_POST_DEFINITIONS}', true)
  end
  # FIXME: not sure whether map_lib_dirs etc. should be passed in in such a raw way -
  # probably mapping should already have been done at that stage...
  def put_target(target, arr_sub_source_list_var_names, map_lib_dirs, map_dependencies, config_info_curr)
    target_is_valid = false

    # create a target only in case we do have any meat at all
    #if not main_files[:arr_sub_filters].empty? or not main_files[:arr_files].empty?
    #if not arr_sub_source_list_var_names.empty?
    if target.have_build_units

      # first add source reference, then do linker setup, then create target

      put_source_vars(arr_sub_source_list_var_names)

      # write link_directories() (BEFORE establishing a target!)
      config_info_curr.arr_linker_info.each { |linker_info_curr|
        @localGenerator.write_link_directories(linker_info_curr.arr_lib_dirs, map_lib_dirs)
      }

      target_is_valid = put_target_type(target, map_dependencies, config_info_curr)
    end # target.have_build_units

    put_hook_post_target()
    return target_is_valid
  end
  def put_target_type(target, map_dependencies, config_info_curr)
    target_is_valid = false

    str_condition_no_target = "NOT TARGET #{target.name}"
    write_conditional_if(str_condition_no_target)
          # FIXME: should use a macro like rosbuild_add_executable(),
          # http://www.ros.org/wiki/rosbuild/CMakeLists ,
          # https://kermit.cse.wustl.edu/project/robotics/browser/trunk/vendor/ros/core/rosbuild/rosbuild.cmake?rev=3
          # to be able to detect non-C++ file types within a source file list
          # and add a hook to handle them specially.

          # see VCProjectEngine ConfigurationTypes enumeration
    case config_info_curr.cfg_type
    when 1       # typeApplication (.exe)
      target_is_valid = true
      #syntax_generator.write_line("add_executable_vcproj2cmake( #{target.name} WIN32 ${SOURCES} )")
      # TODO: perhaps for real cross-platform binaries (i.e.
      # console apps not needing a WinMain()), we should detect
      # this and not use WIN32 in this case...
      # Well, this probably is related to the .vcproj Keyword attribute ("Win32Proj", "MFCProj", "ATLProj", "MakeFileProj" etc.).
      write_target_executable()
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
      write_target_library_dynamic()
    when 4    # typeStaticLibrary
      target_is_valid = true
      write_target_library_static()
    when 0    # typeUnknown (utility)
      log_warn "Project type 0 (typeUnknown - utility) is a _custom command_ type and thus probably cannot be supported easily. We will not abort and thus do write out a file, but it probably needs fixup (hook scripts?) to work properly. If this project type happens to use VCNMakeTool tool, then I would suggest to examine BuildCommandLine/ReBuildCommandLine/CleanCommandLine attributes for clues on how to proceed."
    else
    #when 10    # typeGeneric (Makefile) [and possibly other things...]
      # TODO: we _should_ somehow support these project types...
      log_fatal "Project type #{config_info_curr.cfg_type} not supported."
    end
    write_conditional_end(str_condition_no_target)

    # write target_link_libraries() in case there's a valid target
    if target_is_valid
      config_info_curr.arr_linker_info.each { |linker_info_curr|
        write_link_libraries(linker_info_curr.arr_dependencies, map_dependencies)
      }
    end # target_is_valid
    return target_is_valid
  end
  def write_target_executable
    write_command_single_line('add_executable', "#{@target.name} WIN32 ${SOURCES}")
  end

  def write_target_library_dynamic
    write_empty_line()
    write_command_single_line('add_library', "#{@target.name} SHARED ${SOURCES}")
  end

  def write_target_library_static
    #write_new_line("add_library_vcproj2cmake( #{target.name} STATIC ${SOURCES} )")
    write_empty_line()
    write_command_single_line('add_library', "#{@target.name} STATIC ${SOURCES}")
  end
  def put_hook_post_target
    write_empty_line()
    write_comment_at_level(1, \
      "e.g. to be used for tweaking target properties etc." \
    )
    write_include('${V2C_HOOK_POST_TARGET}', true)
  end
  def generate_property_compile_definitions(config_name_upper, arr_platdefs, str_platform)
      write_conditional_if(str_platform)
        arr_compile_defn = Array.new
        arr_platdefs.each do |compile_defn|
    	  # Need to escape the value part of the key=value definition:
          if compile_defn =~ /[\(\)]+/
            escape_char(compile_defn, '\\(')
            escape_char(compile_defn, '\\)')
          end
          arr_compile_defn.push(compile_defn)
        end
        # make sure to specify APPEND for greater flexibility (hooks etc.)
        cmake_command_arg = "TARGET #{@target.name} APPEND PROPERTY COMPILE_DEFINITIONS_#{config_name_upper}"
	write_command_list('set_property', cmake_command_arg, arr_compile_defn)
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
      str_platform = key if not key.eql?('ALL')
      generate_property_compile_definitions(config_name_upper, arr_platdefs, str_platform)
    }
  end
  def write_property_compile_flags(config_name, arr_flags, str_conditional)
    return if arr_flags.empty?
    config_name_upper = get_config_name_upcase(config_name)
    write_empty_line()
    write_conditional_if(str_conditional)
      cmake_command_arg = "TARGET #{@target.name} APPEND PROPERTY COMPILE_FLAGS_#{config_name_upper}"
      write_command_list('set_property', cmake_command_arg, arr_flags)
    write_conditional_end(str_conditional)
  end
  def write_link_libraries(arr_dependencies, map_dependencies)
    arr_dependencies.push('${V2C_LIBS}')
    @localGenerator.write_build_attributes('target_link_libraries', arr_dependencies, map_dependencies, @target.name)
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
    scc_info.project_name.gsub!(/"/, '&quot;')
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
    write_vcproj2cmake_func_comment()
    arr_func_args = [ scc_info.project_name, scc_info.local_path, scc_info.provider, scc_info.aux_path ]
    write_command_list_quoted('v2c_target_set_properties_vs_scc', @target.name, arr_func_args)
  end

  private

  def get_config_name_upcase(config_name)
    # need to also convert config names with spaces into underscore variants, right?
    config_name.clone.upcase.gsub(/ /,'_')
  end

  def set_property(target, property, value)
    write_command_single_line('set_property', "TARGET #{target} PROPERTY #{property} \"#{value}\"")
  end
end

# XML support as required by VS7+/VS10 parsers:
require 'rexml/document'

# See "Format of a .vcproj File" http://msdn.microsoft.com/en-us/library/2208a1f2%28v=vs.71%29.aspx

$vs7_prop_var_scan_regex = '\\$\\(([[:alnum:]_]+)\\)'
$vs7_prop_var_match_regex = '\\$\\([[:alnum:]_]+\\)'

class V2C_Info_Filter
  def initialize
    @name = nil
    @attr_scfilter = nil
    @val_scmfiles = true
    @guid = nil
  end
  attr_accessor :name
  attr_accessor :attr_scfilter
  attr_accessor :val_scmfiles
  attr_accessor :guid
end

Files_str = Struct.new(:filter_info, :arr_sub_filters, :arr_files)

# See also
# "How to: Use Environment Variables in a Build"
#   http://msdn.microsoft.com/en-us/library/ms171459.aspx
# "Macros for Build Commands and Properties"
#   http://msdn.microsoft.com/en-us/library/c02as0cs%28v=vs.71%29.aspx
# To examine real-life values of such MSVS configuration/environment variables,
# open a Visual Studio project's additional library directories dialog,
# then press its "macros" button for a nice list.
def vs7_create_config_variable_translation(str, arr_config_var_handling)
  # http://langref.org/all-languages/pattern-matching/searching/loop-through-a-string-matching-a-regex-and-performing-an-action-for-each-match
  str_scan_copy = str.dup # create a deep copy of string, to avoid "`scan': string modified (RuntimeError)"
  str_scan_copy.scan(/#{$vs7_prop_var_scan_regex}/) {
    config_var = $1
    # MSVS Property / Environment variables are documented to be case-insensitive,
    # thus implement insensitive match:
    config_var_upcase = config_var.upcase
    config_var_replacement = ''
    case config_var_upcase
      when 'CONFIGURATIONNAME'
      	config_var_replacement = '${CMAKE_CFG_INTDIR}'
      when 'PLATFORMNAME'
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
	config_var_replacement = '${v2c_VS_PlatformName}'
        # InputName is said to be same as ProjectName in case input is the project.
      when 'INPUTNAME', 'PROJECTNAME'
      	config_var_replacement = '${PROJECT_NAME}'
        # See ProjectPath reasoning below.
      when 'INPUTFILENAME', 'PROJECTFILENAME'
        # config_var_replacement = '${PROJECT_NAME}.vcproj'
	config_var_replacement = "${v2c_VS_#{config_var}}"
      when 'OUTDIR'
        # FIXME: should extend code to do executable/library/... checks
        # and assign CMAKE_LIBRARY_OUTPUT_DIRECTORY / CMAKE_RUNTIME_OUTPUT_DIRECTORY
        # depending on this.
        config_var_emulation_code = <<EOF
  set(v2c_CS_OutDir "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
EOF
	config_var_replacement = '${v2c_VS_OutDir}'
      when 'PROJECTDIR'
	config_var_replacement = '${PROJECT_SOURCE_DIR}'
      when 'PROJECTPATH'
        # ProjectPath emulation probably doesn't make much sense,
        # since it's a direct path to the MSVS-specific .vcproj file
        # (redirecting to CMakeLists.txt file likely isn't correct/useful).
	config_var_replacement = '${v2c_VS_ProjectPath}'
      when 'SOLUTIONDIR'
        # Probability of SolutionDir being identical to CMAKE_SOURCE_DIR
	# (i.e. the source root dir) ought to be strongly approaching 100%.
	config_var_replacement = '${CMAKE_SOURCE_DIR}'
      when 'TARGETPATH'
        config_var_emulation_code = ''
        arr_config_var_handling.push(config_var_emulation_code)
	config_var_replacement = '${v2c_VS_TargetPath}'
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
      if config_var_replacement != ''
        log_info "Replacing MSVS configuration variable $(#{config_var}) by #{config_var_replacement}."
        str.gsub!(/\$\(#{config_var}\)/, config_var_replacement)
      end
  }

  #log_info "str is now #{str}"
  return str
end

class V2C_VSParserBase
  def unknown_attribute(name)
    unknown_something('attribute', name)
  end
  def unknown_element(name)
    unknown_something('element', name)
  end
  def skipped_element_warn(elem_name)
    log_warn "unhandled less important XML element (#{elem_name})!"
  end
  def get_boolean_value(attr_value)
    value = false
    if not attr_value.nil? and attr_value.downcase == 'true'
      value = true
    end
    return value
  end

  private

  def unknown_something(something_name, name)
    log_error "#{self.class.name}: unknown/incorrect XML #{something_name} (#{name})!"
  end
end

class V2C_VSProjectXmlParserBase
  def initialize(doc_proj, arr_targets, arr_config_info)
    @doc_proj = doc_proj
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
  end
end

class V2C_VSProjectParserBase < V2C_VSParserBase
  def initialize(project_xml, target_out, arr_config_info)
    super()
    @project_xml = project_xml
    @target = target_out
    @arr_config_info = arr_config_info
  end
end

class V2C_VS7ProjectParserBase < V2C_VSProjectParserBase
  def initialize(project_xml, target_out, arr_config_info)
    super(project_xml, target_out, arr_config_info)
  end
end

module V2C_VS7ToolDefines
  VS7_VALUE_SEPARATOR_REGEX = '[;,]'
end

class V2C_VS7ToolLinkerParser < V2C_VSParserBase
  include V2C_VS7ToolDefines
  def initialize(linker_xml, arr_linker_info_out)
    super()
    @linker_xml = linker_xml
    @arr_linker_info = arr_linker_info_out
  end
  def parse
    # parse linker configuration...
    # FIXME case/when switch for individual elements...
    linker_info_curr = V2C_Tool_Linker_Info.new
    arr_dependencies_curr = linker_info_curr.arr_dependencies
    read_linker_additional_dependencies(@linker_xml, arr_dependencies_curr)
    arr_lib_dirs_curr = linker_info_curr.arr_lib_dirs
    read_linker_additional_library_directories(@linker_xml, arr_lib_dirs_curr)
    # TODO: support AdditionalOptions! (mention via
    # CMAKE_SHARED_LINKER_FLAGS / CMAKE_MODULE_LINKER_FLAGS / CMAKE_EXE_LINKER_FLAGS
    # depending on target type, and make sure to filter out options pre-defined by CMake platform
    # setup modules)
    @arr_linker_info.push(linker_info_curr)
  end

  private

  def read_linker_additional_dependencies(linker_xml, arr_dependencies)
    attr_deps = linker_xml.attributes['AdditionalDependencies']
    return if attr_deps.nil? or attr_deps.length == 0
    attr_deps.split.each { |elem_lib_dep|
      elem_lib_dep = normalize_path(elem_lib_dep).strip
      arr_dependencies.push(File.basename(elem_lib_dep, '.lib'))
    }
  end

  def read_linker_additional_library_directories(linker_xml, arr_lib_dirs)
    attr_lib_dirs = linker_xml.attributes['AdditionalLibraryDirectories']
    return if attr_lib_dirs.nil? or attr_lib_dirs.length == 0
    attr_lib_dirs.split(/#{VS7_VALUE_SEPARATOR_REGEX}/).each { |elem_lib_dir|
      elem_lib_dir = normalize_path(elem_lib_dir).strip
      #log_info "lib dir is '#{elem_lib_dir}'"
      arr_lib_dirs.push(elem_lib_dir)
    }
  end
end

class V2C_VS7ToolCompilerParser < V2C_VSParserBase
  include V2C_VS7ToolDefines
  def initialize(compiler_xml, arr_compiler_info_out)
    super()
    @compiler_xml = compiler_xml
    @arr_compiler_info = arr_compiler_info_out
  end
  def parse
    compiler_info = V2C_Tool_Compiler_Info.new

    parse_attributes(compiler_info)

    @arr_compiler_info.push(compiler_info)
  end

  private

  def parse_attributes(compiler_info)
    @compiler_xml.attributes.each_attribute { |attr_xml|
      attr_value = attr_xml.value
      case attr_xml.name
      when 'AdditionalIncludeDirectories'
        parse_compiler_additional_include_directories(compiler_info, attr_value)
      when 'AdditionalOptions'
        parse_compiler_additional_options(compiler_info.arr_flags, attr_value)
      when 'PreprocessorDefinitions'
        parse_compiler_preprocessor_definitions(compiler_info.hash_defines, attr_value)
      else
        unknown_attribute(attr_xml.name)
      end
    }
  end
  def parse_compiler_additional_include_directories(compiler_info, attr_incdir)
    arr_includes = Array.new
    include_dirs = attr_incdir.split(/#{VS7_VALUE_SEPARATOR_REGEX}/).each { |elem_inc_dir|
      elem_inc_dir = normalize_path(elem_inc_dir).strip
      #log_info "include is '#{elem_inc_dir}'"
      arr_includes.push(elem_inc_dir)
    }
    arr_includes.each { |inc_dir|
      info_inc_dir = V2C_Info_Include_Dir.new
      info_inc_dir.dir = inc_dir
      compiler_info.arr_info_include_dirs.push(info_inc_dir)
    }
  end
  def parse_compiler_additional_options(arr_flags, attr_options)
    # Oh well, we might eventually want to provide a full-scale
    # translation of various compiler switches to their
    # counterparts on compilers of various platforms, but for
    # now, let's simply directly pass them on to the compiler when on
    # Win32 platform.

    # I don't think we need this (we have per-target properties), thus we'll NOT write it!
    #local_generator.write_directory_property_compile_flags(attr_opts)
  
    # TODO: add translation table for specific compiler flag settings such as MinimalRebuild:
    # simply make reverse use of existing translation table in CMake source.
    arr_flags.replace(attr_options.split(';'))
  end
  def parse_compiler_preprocessor_definitions(hash_defines, attr_defines)
    attr_defines.split(/#{VS7_VALUE_SEPARATOR_REGEX}/).each { |elem_define|
      str_define_key, str_define_value = elem_define.strip.split(/=/)
      # Since a Hash will indicate nil for any non-existing key,
      # we do need to fill in _empty_ value for our _existing_ key.
      if str_define_value.nil?
        str_define_value = ''
      end
      hash_defines[str_define_key] = str_define_value
    }
  end
end

class V2C_VS7ToolParser < V2C_VSParserBase
  def initialize(tool_xml, config_info_out)
    super()
    @tool_xml = tool_xml
    @config_info = config_info_out
  end
  def parse
    toolname = @tool_xml.attributes['Name']
    case toolname
    when 'VCCLCompilerTool'
      elem_parser = V2C_VS7ToolCompilerParser.new(@tool_xml, @config_info.arr_compiler_info)
    when 'VCLinkerTool'
      elem_parser = V2C_VS7ToolLinkerParser.new(@tool_xml, @config_info.arr_linker_info)
    else
      unknown_element(toolname)
    end
    if not elem_parser.nil?
      elem_parser.parse
    end
  end
end

class V2C_VS7ConfigurationBaseParser < V2C_VSParserBase
  def initialize(config_xml, config_info_out)
    super()
    @config_xml = config_xml
    @config_info = config_info_out
  end
  def parse
    res = false
    parse_attributes(@config_info)
    parse_elements(@config_info)
    res = true
    return res
  end

  private

  def parse_attributes(config_info)
    @config_xml.attributes.each_attribute { |attr_xml|
      parse_attribute(config_info, attr_xml.name, attr_xml.value)
    }
  end
  def parse_attribute_base(config_info, attr_name, attr_value)
    found = true # be optimistic :)
    case attr_name
    when 'CharacterSet'
      config_info.charset = parse_charset(attr_value)
    when 'ConfigurationType'
      config_info.cfg_type = attr_value.to_i
    when 'Name'
      arr_name = attr_value.split('|')
      config_info.build_type = arr_name[0]
      config_info.platform = arr_name[1]
    when 'UseOfMFC'
      # 0 == no MFC
      # 1 == static MFC
      # 2 == shared MFC
      # VS7 does not seem to use string values (only 0/1/2 integers), while VS10 additionally does.
      # FUTURE NOTE: MSVS7 has UseOfMFC, MSVS10 has UseOfMfc (see CMake MSVS generators)
      # --> we probably should _not_ switch to case insensitive matching on
      # attributes (see e.g.
      # http://fossplanet.com/f14/rexml-translate-xpath-28868/ ),
      # but rather implement version-specific parser classes due to
      # the differing XML configurations
      # (e.g. do this via a common base class, then add derived ones
      # to implement any differences).
      config_info.use_of_mfc = attr_value.to_i
    when 'UseOfATL'
      config_info.use_of_atl = attr_value.to_i
    when 'WholeProgramOptimization'
      config_info.whole_program_optimization = parse_wp_optimization(attr_value)
    else
      found = false
    end
    return found
  end
  def parse_elements(config_info)
    @config_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'Tool'
        elem_parser = V2C_VS7ToolParser.new(elem_xml, config_info)
      else
        unknown_element(elem_xml.name)
      end
      if not elem_parser.nil?
        elem_parser.parse
      end
    }
  end
  def parse_charset(str_charset); return str_charset.to_i end
  def parse_wp_optimization(str_opt); return str_opt.to_i end
end

class V2C_VS7ProjectConfigurationParser < V2C_VS7ConfigurationBaseParser
  def initialize(config_xml, config_info_out)
    super(config_xml, config_info_out)
  end

  private

  def parse_attribute(config_info, attr_name, attr_value)
    if not parse_attribute_base(config_info, attr_name, attr_value)
      unknown_attribute(attr_name)
    end
  end
end

class V2C_VS7FileConfigurationParser < V2C_VS7ConfigurationBaseParser
  def initialize(config_xml, arr_config_info_out)
    super(config_xml, arr_config_info_out)
  end

  private

  def parse_attribute(config_info, attr_name, attr_value)
    if not parse_attribute_base(config_info, attr_name, attr_value)
      case attr_name
      when 'ExcludedFromBuild'
        config_info.excluded_from_build = get_boolean_value(attr_value)
      else
        unknown_attribute(attr_name)
      end
    end
  end
end

class V2C_VS7ConfigurationsParser < V2C_VSParserBase
  def initialize(configs_xml, arr_config_info_out)
    super()
    @configs_xml = configs_xml
    @arr_config_info = arr_config_info_out
  end
  def parse
    @configs_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'Configuration'
        config_info_curr = V2C_Project_Config_Info.new
        elem_parser = V2C_VS7ProjectConfigurationParser.new(elem_xml, config_info_curr)
        if elem_parser.parse
          @arr_config_info.push(config_info_curr)
        end
      else
        unknown_element(elem_xml.name)
      end
    }
  end
end

class V2C_Info_File
  def initialize
    @config_info = nil
    @path_relative = ''
  end
  attr_accessor :config_info
  attr_accessor :path_relative
end

class V2C_VS7FileParser < V2C_VSParserBase
  def initialize(project_name, file_xml, arr_source_infos_out)
    super()
    @project_name = project_name # FIXME remove (file check should be done _after_ parsing!)
    @file_xml = file_xml
    @arr_source_infos = arr_source_infos_out
  end
  def parse
    log_debug "#{self.class.name}: parse"
    info_file = V2C_Info_File.new
    parse_attributes(info_file)
    f = info_file.path_relative # HACK

    config_info_curr = nil
    @file_xml.elements.each { |elem_xml|
      case elem_xml.name
      when 'FileConfiguration'
	config_info_curr = V2C_File_Config_Info.new
        elem_parser = V2C_VS7FileConfigurationParser.new(elem_xml, config_info_curr)
        elem_parser.parse
        info_file.config_info = config_info_curr
      else
        unknown_element(elem_xml.name)
      end
    }

    # FIXME: move these file skipping parts to _generator_ side,
    # don't skip adding file array entries here!!

    excluded_from_build = false
    if not config_info_curr.nil? and config_info_curr.excluded_from_build
      excluded_from_build = true
    end

    # Ignore files which have the ExcludedFromBuild attribute set to TRUE
    if excluded_from_build
      return # no complex handling, just return
    end
    # Ignore files with custom build steps
    included_in_build = true
    @file_xml.elements.each('FileConfiguration/Tool') { |tool_xml|
      if tool_xml.attributes['Name'] == 'VCCustomBuildTool'
        included_in_build = false
        return # no complex handling, just return
      end
    }

    if not excluded_from_build and included_in_build
      @arr_source_infos.push(info_file)
      # HACK:
      if not $have_build_units
        if f =~ /\.(c|C)/
          $have_build_units = true
        end
      end
    end
  end

  private

  def parse_attributes(info_file)
    @file_xml.attributes.each_attribute { |attr_xml|
      attr_value = attr_xml.value
      case attr_xml.name
      when 'RelativePath'
        info_file.path_relative = normalize_path(attr_value)
      else
        unknown_attribute(attr_xml.name)
      end
    }
  end
end

class V2C_VS7FilterParser < V2C_VSParserBase
  def initialize(files_xml, target_out, files_str_out)
    super()
    @files_xml = files_xml
    @target = target_out
    @files_str = files_str_out
  end
  def parse
    res = parse_file_list(@files_xml, @files_str)
    @target.have_build_units = $have_build_units # HACK
    return res
  end
  def parse_file_list(vcproj_filter_xml, files_str)
    parse_file_list_attributes(vcproj_filter_xml, files_str)

    filter_info = files_str[:filter_info]
    if not filter_info.nil?
      # skip file filters that have a SourceControlFiles property
      # that's set to false, i.e. files which aren't under version
      # control (such as IDL generated files).
      # This experimental check might be a little rough after all...
      # yes, FIXME: on Win32, these files likely _should_ get listed
      # after all. We should probably do a platform check in such
      # cases, i.e. add support for a file_mappings.txt
      if filter_info.val_scmfiles == false
        log_info "#{filter_info.name}: SourceControlFiles set to false, listing generated files? --> skipping!"
        return false
      end
      if not filter_info.name.nil?
        # Hrmm, this string match implementation is very open-coded ad-hoc imprecise.
        if filter_info.name == 'Generated Files' or filter_info.name == 'Generierte Dateien'
          # Hmm, how are we supposed to handle Generated Files?
          # Most likely we _are_ supposed to add such files
          # and set_property(SOURCE ... GENERATED) on it.
          log_info "#{filter_info.name}: encountered a filter named Generated Files --> skipping! (FIXME)"
          return false
        end
      end
    end

    arr_source_infos = Array.new
    vcproj_filter_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'File'
        log_debug 'FOUND File'
        elem_parser = V2C_VS7FileParser.new(@target.name, elem_xml, arr_source_infos)
        elem_parser.parse
      when 'Filter'
        log_debug 'FOUND Filter'
        subfiles_str = Files_str.new
        elem_parser = V2C_VS7FilterParser.new(elem_xml, @target, subfiles_str)
        if elem_parser.parse
          if files_str[:arr_sub_filters].nil?
            files_str[:arr_sub_filters] = Array.new
          end
          files_str[:arr_sub_filters].push(subfiles_str)
        end
      else
        unknown_element(elem_xml.name)
      end
    } # |elem_xml|

    if not arr_source_infos.empty?
      files_str[:arr_files] = arr_source_infos
    end
    return true
  end

  private

  def parse_file_list_attributes(vcproj_filter_xml, files_str)
    filter_info = nil
    file_group_name = nil
    if vcproj_filter_xml.attributes.length
      filter_info = V2C_Info_Filter.new
    end
    vcproj_filter_xml.attributes.each_attribute { |attr_xml|
      attr_value = attr_xml.value
      case attr_xml.name
      when 'Filter'
        filter_info.attr_scfilter = attr_value
      when 'Name'
        file_group_name = attr_value
        filter_info.name = file_group_name
      when 'SourceControlFiles'
        filter_info.val_scmfiles = get_boolean_value(attr_value)
      when 'UniqueIdentifier'
        filter_info.guid = attr_value
      else
        unknown_attribute(attr_xml.name)
      end
    }
    if file_group_name.nil?
      file_group_name = 'COMMON'
    end
    log_debug "parsing files group #{file_group_name}"
    files_str[:filter_info] = filter_info
  end
end

class V2C_VS7ProjectParser < V2C_VS7ProjectParserBase
  def initialize(project_xml, target_out, arr_config_info)
    super(project_xml, target_out, arr_config_info)
  end
  def parse
    parse_attributes

    $have_build_units = false # HACK
  
    $main_files = Files_str.new # HACK global var

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
  
    if $config_multi_authoritative.empty? # HACK global var
  	  project_configuration_first_xml = @project_xml.elements['Configurations/Configuration'].next_element
  	  if not project_configuration_first_xml.nil?
        $config_multi_authoritative = vs7_get_build_type(project_configuration_first_xml)
  	  end
    end
  
    @project_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'Configurations'
        elem_parser = V2C_VS7ConfigurationsParser.new(elem_xml, @arr_config_info)
      when 'Files' # "Files" simply appears to be a special "Filter" element without any filter conditions.
        # FIXME: we most likely shouldn't pass a rather global "target" object here! (pass a file info object)
        elem_parser = V2C_VS7FilterParser.new(elem_xml, @target, $main_files)
      when 'Platforms'
        skipped_element_warn(elem_xml.name)
      else
        unknown_element(elem_xml.name)
      end
      if not elem_parser.nil?
        elem_parser.parse
      end
    }
  end

  private

  def vs7_get_build_type(config_xml); config_xml.attributes['Name'].split('|')[0] end

  def parse_attributes
    @project_xml.attributes.each_attribute { |attr_xml|
      attr_value = attr_xml.value
      case attr_xml.name
      when 'Keyword'
        @target.vs_keyword = attr_value
      when 'Name'
        @target.name = attr_value
      when 'ProjectCreator' # used by Fortran .vfproj ("Intel Fortran")
        @target.creator = attr_value
      when 'ProjectGUID', 'ProjectIdGuid' # used by Visual C++ .vcproj, Fortran .vfproj
        @target.guid = attr_value
      when 'ProjectType'
        @target.type = attr_value
      when 'RootNamespace'
        @target.root_namespace = attr_value
      when 'Version'
        @target.version = attr_value

      when /^Scc/
        parse_attributes_scc(attr_xml.name, attr_value, @target.scc_info)
      else
        unknown_attribute(attr_xml.name)
      end
    }
  end
  def parse_attributes_scc(attr_name, attr_value, scc_info_out)
    case attr_name
    # Hrmm, turns out having SccProjectName is no guarantee that both SccLocalPath and SccProvider
    # exist, too... (one project had SccProvider missing). HOWEVER,
    # CMake generator does expect all three to exist when available! Hmm.
    when 'SccProjectName'
      scc_info_out.project_name = attr_value
    # There's a special SAK (Should Already Know) entry marker
    # (see e.g. http://stackoverflow.com/a/6356615 ).
    # Currently I don't believe we need to handle "SAK" in special ways
    # (such as filling it in in case of missing entries),
    # transparent handling ought to be sufficient.
    when 'SccLocalPath'
      scc_info_out.local_path = attr_value
    when 'SccProvider'
      scc_info_out.provider = attr_value
    when 'SccAuxPath'
      scc_info_out.aux_path = attr_value
    else
      unknown_attribute(attr_name)
    end
  end
end

class V2C_VSProjectFilesParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    @proj_filename = proj_filename
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
  end
end

# Project parser variant which works on XML-stream-based input
class V2C_VS7ProjectXmlParser < V2C_VSProjectXmlParserBase
  def initialize(doc_proj, arr_targets, arr_config_info)
    super(doc_proj, arr_targets, arr_config_info)
  end
  def parse
    @doc_proj.elements.each { |elem_xml|
      case elem_xml.name
      when 'VisualStudioProject'
        target = V2C_Target.new
        project_parser = V2C_VS7ProjectParser.new(elem_xml, target, @arr_config_info)
        project_parser.parse

        @arr_targets.push(target)
      else
        unknown_element(elem_xml.name)
      end
    }
  end
end

# Project parser variant which works on file-based input
class V2C_VSProjectFileParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    @proj_filename = proj_filename
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
    @proj_xml_parser = nil
  end
  def parse
    @proj_xml_parser.parse
  end
end

class V2C_VS7ProjectFileParser < V2C_VSProjectFileParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    super(proj_filename, arr_targets, arr_config_info)
  end
  def parse
    File.open(@proj_filename) { |io|
      doc_proj = REXML::Document.new io

      @proj_xml_parser = V2C_VS7ProjectXmlParser.new(doc_proj, @arr_targets, @arr_config_info)
      #super.parse
      @proj_xml_parser.parse
    }
  end
end

class V2C_VS7ProjectFilesParser < V2C_VSProjectFilesParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    super(proj_filename, arr_targets, arr_config_info)
  end
  def parse
    proj_file_parser = V2C_VS7ProjectFileParser.new(@proj_filename, @arr_targets, @arr_config_info)
    proj_file_parser.parse
  end
end

# NOTE: VS10 == MSBuild == somewhat Ant-based.
# Thus it would probably be useful to create an Ant syntax parser base class
# and derive MSBuild-specific behaviour from it.
class V2C_VS10ParserBase < V2C_VSParserBase
  def initialize
    super()
  end
end

class V2C_VS10ItemGroupProjectConfigParser < V2C_VS10ParserBase
  def initialize(itemgroup_xml, arr_config_info)
    super()
    @itemgroup_xml = itemgroup_xml
    @arr_config_info = arr_config_info
  end
  def parse
    @itemgroup_xml.elements.each { |itemgroup_elem_xml|
      case itemgroup_elem_xml.name
      when 'ProjectConfiguration'
        config_info = V2C_Project_Config_Info.new
        itemgroup_elem_xml.elements.each  { |projcfg_elem_xml|
          case projcfg_elem_xml.name
          when 'Configuration'
            config_info.build_type = projcfg_elem_xml.text
          when 'Platform'
            config_info.platform = projcfg_elem_xml.text
          else
            unknown_element(projcfg_elem_xml.name)
          end
	}
        log_debug "ProjectConfig: build type #{config_info.build_type}, platform #{config_info.platform}"
	@arr_config_info.push(config_info)
      else
        unknown_element(itemgroup_elem_xml.name)
      end
    }
  end
end

class V2C_ItemGroup
  def initialize
    @label = String.new
    @items = Array.new
  end
end

class V2C_VS10ItemGroupAnonymousParser < V2C_VS10ParserBase
  def initialize(itemgroup_xml, itemgroup_out)
    super()
    @itemgroup_xml = itemgroup_xml
    @itemgroup = itemgroup_out
  end
  def parse
    puts "FIXME!! V2C_VS10ItemGroupAnonymousParser"
  end
end

class V2C_VS10ItemGroupParser < V2C_VS10ParserBase
  def initialize(itemgroup_xml, target_out, arr_config_info)
    super()
    @itemgroup_xml = itemgroup_xml
    @target = target_out
    @arr_config_info = arr_config_info
  end
  def parse
    itemgroup_label = @itemgroup_xml.attributes['Label']
    log_debug "item group, Label #{itemgroup_label}!"
    item_group_parser = nil
    case itemgroup_label
    when 'ProjectConfigurations'
      item_group_parser = V2C_VS10ItemGroupProjectConfigParser.new(@itemgroup_xml, @arr_config_info)
    when nil
      item_group_parser = V2C_VS10ItemGroupAnonymousParser.new(@itemgroup_xml, @target)
    else
      unknown_element("Label #{itemgroup_label}")
    end
    if not item_group_parser.nil?
      item_group_parser.parse
    end
  end
end

class V2C_VS10PropertyGroupGlobalsParser < V2C_VS10ParserBase
  def initialize(propgroup_xml, target_out)
    super()
    @propgroup_xml = propgroup_xml
    @target = target_out
  end
  def parse
    @propgroup_xml.elements.each { |propelem_xml|
      case propelem_xml.name
      when 'Keyword'
        @target.vs_keyword = propelem_xml.text
      when 'ProjectGuid'
        @target.guid = propelem_xml.text
      when 'ProjectName'
        @target.name = propelem_xml.text
      when 'RootNamespace'
        @target.root_namespace = propelem_xml.text
      else
        unknown_element(propelem_xml.name)
      end
    }
  end
end

class V2C_VS10PropertyGroupParser < V2C_VS10ParserBase
  def initialize(propgroup_xml, target_out)
    super()
    @propgroup_xml = propgroup_xml
    @target = target_out
  end
  def parse
    @propgroup_xml.attributes.each_attribute { |attr_xml|
      case attr_xml.name
      when 'Label'
        propgroup_label = attr_xml.value
        log_debug "property group, Label #{propgroup_label}!"
        case propgroup_label
        when 'Globals'
          propgroup_parser = V2C_VS10PropertyGroupGlobalsParser.new(@propgroup_xml, @target)
          propgroup_parser.parse
        else
          unknown_element("Label #{propgroup_label}")
        end
      else
        unknown_attribute(attr_xml.name)
      end
    }
  end
end

class V2C_VS10ProjectParserBase < V2C_VSProjectParserBase
  def initialize(project_xml, target_out, arr_config_info)
    super(project_xml, target_out, arr_config_info)
  end
end

class V2C_VS10ProjectParser < V2C_VS10ProjectParserBase
  def initialize(project_xml, target_out, arr_config_info)
    super(project_xml, target_out, arr_config_info)
  end

  def parse
    # Do strict traversal over _all_ elements, parse what's supported by us,
    # and yell loudly for any element which we don't know about!
    # FIXME: VS7 parser should be changed to do the same thing...
    @project_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'ItemGroup'
        elem_parser = V2C_VS10ItemGroupParser.new(elem_xml, @target, @arr_config_info)
      when 'PropertyGroup'
        elem_parser = V2C_VS10PropertyGroupParser.new(elem_xml, @target)
      else
        unknown_element(elem_xml.name)
      end
      if not elem_parser.nil?
        elem_parser.parse
      end
    }
  end
end

# Project parser variant which works on XML-stream-based input
class V2C_VS10ProjectXmlParser < V2C_VSProjectXmlParserBase
  def initialize(doc_proj, arr_targets, arr_config_info)
    super(doc_proj, arr_targets, arr_config_info)
  end
  def parse
    @doc_proj.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'Project'
        target = V2C_Target.new
        elem_parser = V2C_VS10ProjectParser.new(elem_xml, target, @arr_config_info)
        elem_parser.parse
        @arr_targets.push(target)
      else
        unknown_element(elem_xml.name)
      end
    }
  end
end

# Project parser variant which works on file-based input
class V2C_VS10ProjectFileParser < V2C_VSProjectFileParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    super(proj_filename, arr_targets, arr_config_info)
  end
  def parse
    File.open(@proj_filename) { |io|
      doc_proj = REXML::Document.new io

      @proj_xml_parser = V2C_VS10ProjectXmlParser.new(doc_proj, @arr_targets, @arr_config_info)
      #super.parse
      @proj_xml_parser.parse
    }
  end
end

class V2C_VS10ProjectFiltersParserBase < V2C_VS10ParserBase
  def initialize
    super()
  end
end

class V2C_VS10ProjectFiltersParser < V2C_VS10ProjectFiltersParserBase
  def initialize(project_filters_xml, target_out, arr_config_info)
    super()
    @project_filters_xml = project_filters_xml
    @target = target_out
    @arr_config_info = arr_config_info
  end

  def parse
    # Do strict traversal over _all_ elements, parse what's supported by us,
    # and yell loudly for any element which we don't know about!
    # FIXME: VS7 parser should be changed to do the same thing...
    @project_filters_xml.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'ItemGroup'
        elem_parser = V2C_VS10ItemGroupParser.new(elem_xml, @target, @arr_config_info)
      #when 'PropertyGroup'
      #  proj_filters_elem_parser = V2C_VS10PropertyGroupParser.new(elem_xml, @target)
      else
        unknown_element(elem_xml.name)
      end
      if not elem_parser.nil?
        elem_parser.parse
      end
    }
  end
end

# Project filters parser variant which works on XML-stream-based input
class V2C_VS10ProjectFiltersXmlParser
  def initialize(doc_proj_filters, arr_targets, arr_config_info)
    @doc_proj_filters = doc_proj_filters
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
  end
  def parse
    idx_target = 0
    puts "FIXME: filters file exists, needs parsing!"
    @doc_proj_filters.elements.each { |elem_xml|
      elem_parser = nil # IMPORTANT: reset it!
      case elem_xml.name
      when 'Project'
	# FIXME handle fetch() exception
        target = @arr_targets.fetch(idx_target)
        idx_target += 1
        elem_parser = V2C_VS10ProjectFiltersParser.new(elem_xml, target, @arr_config_info)
        elem_parser.parse
      else
        unknown_element(elem_xml.name)
      end
    }
  end
end

# Project filters parser variant which works on file-based input
class V2C_VS10ProjectFiltersFileParser
  def initialize(proj_filters_filename, arr_targets, arr_config_info)
    @proj_filters_filename = proj_filters_filename
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
  end
  def parse
    # Parse the file filters file (_separate_ in VS10!)
    # if it exists:
    File.open(@proj_filters_filename) { |io|
      doc_proj_filters = REXML::Document.new io

      project_filters_parser = V2C_VS10ProjectFiltersXmlParser.new(doc_proj_filters, @arr_targets, @arr_config_info)
      project_filters_parser.parse
    }
  end
end

class V2C_VS10ProjectFilesParser < V2C_VSProjectFilesParserBase
  def initialize(proj_filename, arr_targets, arr_config_info)
    super(proj_filename, arr_targets, arr_config_info)
  end
  def parse
    proj_file_parser = V2C_VS10ProjectFileParser.new(@proj_filename, @arr_targets, @arr_config_info)
    proj_filters_file_parser = V2C_VS10ProjectFiltersFileParser.new("#{@proj_filename}.filters", @arr_targets, @arr_config_info)

    proj_file_parser.parse
    proj_filters_file_parser.parse
  end
end

def util_flatten_string(in_string)
  return in_string.gsub(/\s/, '_')
end

class V2C_CMakeGenerator
  def initialize(p_script, p_master_project, p_parser_proj_file, p_generator_proj_file, arr_targets, arr_config_info)
    @p_master_project = p_master_project
    @orig_proj_file_basename = p_parser_proj_file.basename
    # figure out a project_dir variable from the generated project file location
    @project_dir = p_generator_proj_file.dirname
    @cmakelists_output_file = p_generator_proj_file.to_s
    @arr_targets = arr_targets
    @arr_config_info = arr_config_info
    @script_location_relative_to_master = p_script.relative_path_from(p_master_project)
    #puts "p_script #{p_script} | p_master_project #{p_master_project} | @script_location_relative_to_master #{@script_location_relative_to_master}"
  end
  def generate
    @arr_targets.each { |target|
      # write into temporary file, to avoid corrupting previous CMakeLists.txt due to syntax error abort, disk space or failure issues
      tmpfile = Tempfile.new('vcproj2cmake')

      File.open(tmpfile.path, 'w') { |out|
        project_generate_cmake(@p_master_project, @orig_proj_file_basename, out, target, $main_files, @arr_config_info)

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
      output_file = @cmakelists_output_file
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
          V2C_Util_File.mv(output_file, output_file + '.previous')
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
    }
  end
  def project_generate_cmake(p_master_project, orig_proj_file_basename, out, target, main_files, arr_config_info)
        if target.nil?
          log_fatal 'invalid target'
        end
        if main_files.nil?
          log_fatal 'project has no files!? --> will not generate it'
        end
  
        target_is_valid = false
  
        master_project_dir = p_master_project.to_s
        generator_base = V2C_BaseGlobalGenerator.new(master_project_dir)
        map_lib_dirs = Hash.new
        read_mappings_combined(FILENAME_MAP_LIB_DIRS, map_lib_dirs, master_project_dir)
        map_dependencies = Hash.new
        read_mappings_combined(FILENAME_MAP_DEP, map_dependencies, master_project_dir)
        map_defines = Hash.new
        read_mappings_combined(FILENAME_MAP_DEF, map_defines, master_project_dir)
  
        syntax_generator = V2C_CMakeSyntaxGenerator.new(out)
  
        # we likely shouldn't declare this, since for single-configuration
        # generators CMAKE_CONFIGURATION_TYPES shouldn't be set
        # Also, the configuration_types array should be inferred from arr_config_info.
        ## configuration types need to be stated _before_ declaring the project()!
        #syntax_generator.write_empty_line()
        #global_generator.put_configuration_types(configuration_types)
  
        local_generator = V2C_CMakeLocalGenerator.new(out)
  
        local_generator.put_file_header()
  
        # TODO: figure out language type (C CXX etc.) and add it to project() command
        # ok, let's try some initial Q&D handling...
        arr_languages = nil
        if not target.creator.nil?
          if target.creator.match(/Fortran/)
            arr_languages = Array.new
            arr_languages.push('Fortran')
          end
        end
        local_generator.put_project(target.name, arr_languages)
  
        #global_generator = V2C_CMakeGlobalGenerator.new(out)
  
        ## sub projects will inherit, and we _don't_ want that...
        # DISABLED: now to be done by MasterProjectDefaults_vcproj2cmake module if needed
        #syntax_generator.write_line('# reset project-local variables')
        #syntax_generator.write_set_var('V2C_LIBS', '')
        #syntax_generator.write_set_var('V2C_SOURCES', '')
  
        local_generator.put_include_MasterProjectDefaults_vcproj2cmake()
  
        local_generator.put_hook_project()
  
        target_generator = V2C_CMakeTargetGenerator.new(target, @project_dir, local_generator, out)
  
        # arr_sub_source_list_var_names will receive the names of the individual source list variables:
        arr_sub_source_list_var_names = Array.new
        target_generator.put_file_list(target.name, main_files, nil, arr_sub_source_list_var_names)
  
        if not arr_sub_source_list_var_names.empty?
          # add a ${V2C_SOURCES} variable to the list, to be able to append
          # all sorts of (auto-generated, ...) files to this list within
          # hook includes.
  	# - _right before_ creating the target with its sources
  	# - and not earlier since earlier .vcproj-defined variables should be clean (not be made to contain V2C_SOURCES contents yet)
          arr_sub_source_list_var_names.push('V2C_SOURCES')
        else
          log_warn "#{target.name}: no source files at all!? (header-based project?)"
        end
  
        local_generator.put_include_project_source_dir()
  
        target_generator.put_hook_post_sources()
  
        arr_config_info.each { |config_info_curr|
  	build_type_condition = ''
  	if $config_multi_authoritative == config_info_curr.build_type
  	  build_type_condition = "CMAKE_CONFIGURATION_TYPES OR CMAKE_BUILD_TYPE STREQUAL \"#{config_info_curr.build_type}\""
  	else
  	  # YES, this condition is supposed to NOT trigger in case of a multi-configuration generator
  	  build_type_condition = "CMAKE_BUILD_TYPE STREQUAL \"#{config_info_curr.build_type}\""
  	end
  	syntax_generator.write_set_var_bool_conditional(cmake_get_config_info_condition_var_name(config_info_curr), build_type_condition)
        }
  
        arr_config_info.each { |config_info_curr|
  	var_v2c_want_buildcfg_curr = cmake_get_config_info_condition_var_name(config_info_curr)
  	syntax_generator.write_empty_line()
  	syntax_generator.write_conditional_if(var_v2c_want_buildcfg_curr)
  
  	local_generator.put_cmake_mfc_atl_flag(config_info_curr)
  
  	config_info_curr.arr_compiler_info.each { |compiler_info_curr|
  	  arr_includes = Array.new
  	  compiler_info_curr.arr_info_include_dirs.each { |inc_dir_info|
  	    arr_includes.push(inc_dir_info.dir)
  	  }
  
  	  local_generator.write_include_directories(arr_includes, generator_base.map_includes)
  	}
  
  	# FIXME: hohumm, the position of this hook include is outdated, need to update it
  	target_generator.put_hook_post_definitions()
  
        # Technical note: target type (library, executable, ...) in .vcproj can be configured per-config
        # (or, in other words, different configs are capable of generating _different_ target _types_
        # for the _same_ target), but in CMake this isn't possible since _one_ target name
        # maps to _one_ target type and we _need_ to restrict ourselves to using the project name
        # as the exact target name (we are unable to define separate PROJ_lib and PROJ_exe target names,
        # since other .vcproj file contents always link to our target via the main project name only!!).
        # Thus we need to declare the target _outside_ the scope of per-config handling :(
  	target_is_valid = target_generator.put_target(target, arr_sub_source_list_var_names, map_lib_dirs, map_dependencies, config_info_curr)
  
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
            if config_info_curr.use_of_mfc == 2
              compiler_info_curr.hash_defines['_AFXEXT'] = ''
              compiler_info_curr.hash_defines['_AFXDLL'] = ''
            end
              target_generator.write_property_compile_definitions(config_info_curr.build_type, compiler_info_curr.hash_defines, map_defines)
              # Original compiler flags are MSVC-only, of course. TODO: provide an automatic conversion towards gcc?
              target_generator.write_property_compile_flags(config_info_curr.build_type, compiler_info_curr.arr_flags, 'MSVC')
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
  
        local_generator.put_var_converter_script_location(@script_location_relative_to_master)
        local_generator.write_func_v2c_post_setup(target.name, target.vs_keyword, orig_proj_file_basename)
  end

  private

  # Hrmm, I'm not quite sure yet where to aggregate this function...
  def cmake_get_config_info_condition_var_name(config_info)
    # Name may contain spaces - need to handle them!
    config_name = util_flatten_string(config_info.build_type)
    return "v2c_want_buildcfg_#{config_name}"
  end
end


def v2c_convert_project_inner(p_script, p_parser_proj_file, p_generator_proj_file, p_master_project)
  #p_project_dir = Pathname.new(project_dir)
  #p_cmakelists = Pathname.new(output_file)
  #cmakelists_dir = p_cmakelists.dirname
  #p_cmakelists_dir = Pathname.new(cmakelists_dir)
  #p_cmakelists_dir.relative_path_from(...)

  arr_targets = Array.new
  arr_config_info = Array.new

  parser_project_filename = p_parser_proj_file.to_s
  # Q&D parser switch...
  parser = nil # IMPORTANT: reset it!
  if parser_project_filename.match(/.vcproj$/)
    parser = V2C_VS7ProjectFilesParser.new(parser_project_filename, arr_targets, arr_config_info)
  elsif parser_project_filename.match(/.vfproj$/)
    log_warn 'Detected Fortran .vfproj - parsing is VERY experimental, needs much more work!'
    parser = V2C_VS7ProjectFilesParser.new(parser_project_filename, arr_targets, arr_config_info)
  elsif parser_project_filename.match(/.vcxproj$/)
    parser = V2C_VS10ProjectFilesParser.new(parser_project_filename, arr_targets, arr_config_info)
  end

  if not parser.nil?
    parser.parse
  else
    log_fatal "No project parser found for project file #{parser_project_filename}!?"
  end

  generator = nil
  if true
    generator = V2C_CMakeGenerator.new(p_script, p_master_project, p_parser_proj_file, p_generator_proj_file, arr_targets, arr_config_info)
  end

  if not generator.nil?
    generator.generate
  end
end

# Treat non-normalized ("raw") input arguments as needed,
# then pass on to inner function.
def v2c_convert_project_outer(project_converter_script_filename, parser_proj_file, generator_proj_file, master_project_dir)
  p_parser_proj_file = Pathname.new(parser_proj_file)
  p_generator_proj_file = Pathname.new(generator_proj_file)
  master_project_location = File.expand_path(master_project_dir)
  p_master_project = Pathname.new(master_project_location)

  script_location = File.expand_path(project_converter_script_filename)
  p_script = Pathname.new(script_location)

  v2c_convert_project_inner(p_script, p_parser_proj_file, p_generator_proj_file, p_master_project)
end
