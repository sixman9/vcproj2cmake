# This vcproj2cmake-specific CMake module should be available
# at least in your root project (i.e., PROJECT/cmake/Modules/)

# Some helper functions to be used by all converted projects in the tree

# First, include main file (to be customized by user as needed),
# to have important vcproj2cmake configuration settings
# re-defined per each new vcproj-converted project.
include(vcproj2cmake_defs)


# Avoid useless repeated parsing of static-data function definitions
if(V2C_FUNC_DEFINED)
  return()
endif(V2C_FUNC_DEFINED)
set(V2C_FUNC_DEFINED true)

# Define a couple global constant settings
# (make sure to keep outside of repeatedly invoked functions below)

# FIXME: should obey V2C_LOCAL_CONFIG_DIR setting!! Nope, this is a
# reference to the _global_ one here... Hmm, is there a config variable for
# that? At least set a local variable here for now.
set(v2c_global_config_subdir_my "cmake/vcproj2cmake")
set(v2c_mappings_files_expr "${v2c_global_config_subdir_my}/*_mappings.txt")

file(GLOB root_mappings_files_list "${CMAKE_SOURCE_DIR}/${v2c_mappings_files_expr}")


# Sanitize CMAKE_BUILD_TYPE setting:
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
  message("WARNING: CMAKE_BUILD_TYPE was not specified - defaulting to ${CMAKE_BUILD_TYPE} setting!")
endif(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)


if(NOT V2C_STAMP_FILES_SUBDIR)
  set(V2C_STAMP_FILES_SUBDIR "stamps")
endif(NOT V2C_STAMP_FILES_SUBDIR)
set(v2c_stamp_files_dir "${CMAKE_BINARY_DIR}/${v2c_global_config_subdir_my}/${V2C_STAMP_FILES_SUBDIR}")
file(MAKE_DIRECTORY "${v2c_stamp_files_dir}")


if(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
  # Some one-time setup steps:

  set(v2c_cmakelists_target_rebuild_all_name update_cmakelists_rebuild_recursive_ALL)
  set(v2c_project_exclude_list_file_location "${CMAKE_SOURCE_DIR}/${v2c_global_config_subdir_my}/project_exclude_list.txt")

  # Have an update_cmakelists_ALL convenience target
  # to be able to update _all_ outdated CMakeLists.txt files within a project hierarchy
  # Providing _this_ particular target (as a dummy) is _always_ needed,
  # even if the rebuild mechanism cannot be provided (missing script, etc.).
  if(NOT TARGET update_cmakelists_ALL)
    add_custom_target(update_cmakelists_ALL)
  endif(NOT TARGET update_cmakelists_ALL)

  if(NOT v2c_ruby_BIN) # avoid repeated checks (see cmake --trace)
    find_program(v2c_ruby_BIN NAMES ruby)
    if(NOT v2c_ruby_BIN)
      message("could not detect your ruby installation (perhaps forgot to set CMAKE_PREFIX_PATH?), aborting: won't automagically rebuild CMakeLists.txt on changes...")
      return()
    endif(NOT v2c_ruby_BIN)
  endif(NOT v2c_ruby_BIN)

  set(v2c_cmakelists_update_check_stamp_file "${v2c_stamp_files_dir}/v2c_cmakelists_update_check_done.stamp")

  if(V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD)
    # See also
    # "Re: Makefile: 'abort' command? / 'elseif' to go with ifeq/else/endif?
    #   (Make newbie)" http://www.mail-archive.com/help-gnu-utils@gnu.org/msg00736.html
    if(UNIX)
      set(v2c_abort_BIN false)
    else(UNIX)
      set(v2c_abort_BIN v2c_invoked_non_existing_command_simply_to_force_build_abort)
    endif(UNIX)
    # Provide a marker file, to enable external build invokers
    # to determine whether a (supposedly entire) build
    # was aborted due to CMakeLists.txt conversion and thus they
    # should immediately resume with a new build...
    set(cmakelists_update_check_did_abort_public_marker_file "${v2c_stamp_files_dir}/v2c_cmakelists_update_check_did_abort.marker")
    # This is the stamp file for the subsequent "cleanup" target
    # (oh yay, we even need to have the marker file removed on next build launch again).
    set(v2c_update_cmakelists_abort_build_after_update_cleanup_stamp_file "${v2c_stamp_files_dir}/v2c_cmakelists_update_abort_cleanup_done.stamp")
  endif(V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD)

  function(v2c_cmakelists_rebuild_recursively _script)
    if(TARGET ${v2c_cmakelists_target_rebuild_all_name})
      return() # Nothing left to do...
    endif(TARGET ${v2c_cmakelists_target_rebuild_all_name})
    # Need to manually derive the name of the recursive script...
    string(REGEX REPLACE "(.*)/vcproj2cmake.rb" "\\1/vcproj2cmake_recursive.rb" script_recursive_ "${_script}")
    if(NOT EXISTS "${script_recursive_}")
      return()
    endif(NOT EXISTS "${script_recursive_}")
    message(STATUS "Providing fully recursive CMakeLists.txt rebuilder target ${v2c_cmakelists_target_rebuild_all_name}, to forcibly enact a recursive .vcproj --> CMake reconversion of all source tree sub directories.")
    set(cmakelists_update_recursively_updated_stamp_file_ "${CMAKE_CURRENT_BINARY_DIR}/cmakelists_recursive_converter_done.stamp")
    add_custom_target(${v2c_cmakelists_target_rebuild_all_name}
      COMMAND "${v2c_ruby_BIN}" "${script_recursive_}"
      WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
      DEPENDS "${v2c_project_exclude_list_file_location}"
      COMMENT "Doing recursive .vcproj --> CMakeLists.txt conversion in all source root sub directories."
    )
    # TODO: I wanted to add an extra target as an observer of the excluded projects file,
    # but this does not work properly yet -
    # ${v2c_cmakelists_target_rebuild_all_name} should run unconditionally,
    # yet the depending observer target is supposed to be an ALL target which only triggers rerun
    # in case of that excluded projects file dependency being dirty -
    # which does not work since the rebuilder target will then _always_ run on a "make all" build.
    #set(cmakelists_update_recursively_updated_observer_stamp_file_ "${CMAKE_CURRENT_BINARY_DIR}/cmakelists_recursive_converter_observer_done.stamp")
    #add_custom_command(OUTPUT "${cmakelists_update_recursively_updated_observer_stamp_file_}"
    #  COMMAND "${CMAKE_COMMAND}" -E touch "${cmakelists_update_recursively_updated_observer_stamp_file_}"
    #  DEPENDS "${v2c_project_exclude_list_file_location}"
    #)
    #add_custom_target(update_cmakelists_rebuild_recursive_ALL_observer ALL DEPENDS "${cmakelists_update_recursively_updated_observer_stamp_file_}")
    #add_dependencies(update_cmakelists_rebuild_recursive_ALL_observer ${v2c_cmakelists_target_rebuild_all_name})
  endfunction(v2c_cmakelists_rebuild_recursively _script)

  # Function to automagically rebuild our converted CMakeLists.txt
  # by the original converter script in case any relevant files changed.
  function(v2c_rebuild_on_update _target_name _vcproj_file _cmakelists_file _script _master_proj_dir)
    message(STATUS "${_target_name}: providing ${_cmakelists_file} rebuilder (watching ${_vcproj_file})")

    if(NOT EXISTS "${_script}")
      # Perhaps someone manually copied over a set of foreign-machine-converted CMakeLists.txt files...
      # --> make sure that this use case is working anyway.
      message("WARN: ${_target_name}: vcproj2cmake converter script ${_script} not found, cannot activate automatic reconversion functionality!")
      return()
    endif(NOT EXISTS "${_script}")

    # There are some uncertainties about how to locate the ruby script.
    # for now, let's just hardcode a "must have been converted from root project" requirement.
    ## canonicalize script, to be able to precisely launch it via a CMAKE_SOURCE_DIR root dir base
    #file(RELATIVE_PATH _script_rel "${CMAKE_SOURCE_DIR}" "${_script}")
    ##message(FATAL_ERROR "_script ${_script} _script_rel ${_script_rel}")

    # Hrmm, this is a wee bit unclean: since we gather access to the script name
    # only in case of an invocation of this function, we'll have to invoke the recursive-rebuild function here.
    v2c_cmakelists_rebuild_recursively("${_script}")

    set(v2c_cmakelists_rebuilder_deps_list_ "${_vcproj_file}" "${_script}")
    # Collect dependencies for mappings files in both root project and current project
    file(GLOB proj_mappings_files_list_ "${v2c_mappings_files_expr}")
    list(APPEND v2c_cmakelists_rebuilder_deps_list_ ${root_mappings_files_list} ${proj_mappings_files_list_})
    #message("v2c_cmakelists_rebuilder_deps_list_ ${v2c_cmakelists_rebuilder_deps_list_}")

    # Need to manually derive the name of the settings script...
    string(REGEX REPLACE "(.*)/vcproj2cmake.rb" "\\1/vcproj2cmake_settings.rb" script_settings_ "${_script}")
    if(EXISTS "${script_settings_}")
      list(APPEND v2c_cmakelists_rebuilder_deps_list_ "${script_settings_}")
    endif(EXISTS "${script_settings_}")
    list(APPEND v2c_cmakelists_rebuilder_deps_list_ "${v2c_ruby_BIN}")
    # TODO add any other relevant dependencies here

    # Need an intermediate stamp file, otherwise "make clean" will clean
    # our live output file (CMakeLists.txt), yet we crucially need to preserve it
    # since it hosts this very CMakeLists.txt rebuilder mechanism...
    set(cmakelists_update_this_proj_updated_stamp_file_ "${CMAKE_CURRENT_BINARY_DIR}/cmakelists_rebuilder_done.stamp")
    add_custom_command(OUTPUT "${cmakelists_update_this_proj_updated_stamp_file_}"
      COMMAND "${v2c_ruby_BIN}" "${_script}" "${_vcproj_file}" "${_cmakelists_file}" "${_master_proj_dir}"
      COMMAND "${CMAKE_COMMAND}" -E remove -f "${v2c_cmakelists_update_check_stamp_file}"
      COMMAND "${CMAKE_COMMAND}" -E touch "${cmakelists_update_this_proj_updated_stamp_file_}"
      DEPENDS ${v2c_cmakelists_rebuilder_deps_list_}
      COMMENT "vcproj settings changed, rebuilding ${_cmakelists_file}"
    )
    # TODO: do we have to set_source_files_properties(GENERATED) on ${_cmakelists_file}?

    if(NOT TARGET update_cmakelists_ALL__internal_collector)
      set(need_init_main_targets_this_time_ true)

      # This is the lower-level target which encompasses all .vcproj-based
      # sub projects (always separate this from external higher-level
      # target, to be able to implement additional mechanisms):
      add_custom_target(update_cmakelists_ALL__internal_collector)
    endif(NOT TARGET update_cmakelists_ALL__internal_collector)

#    if(need_init_main_targets_this_time_)
#      # Define a "rebuild of any CMakeLists.txt file occurred" marker
#      # file. This will be used to trigger subsequent targets which will
#      # abort the build.
#      set(rebuild_occurred_marker_file "${v2c_stamp_files_dir}/v2c_cmakelists_rebuild_occurred.marker")
#      add_custom_command(OUTPUT "${rebuild_occurred_marker_file}"
#        COMMAND "${CMAKE_COMMAND}" -E touch "${rebuild_occurred_marker_file}"
#      )
#      add_custom_target(update_cmakelists_rebuild_happened DEPENDS "${rebuild_occurred_marker_file}")
#    endif(need_init_main_targets_this_time_)

    # NOTE: we use update_cmakelists_[TARGET] names instead of [TARGET]_...
    # since in certain IDEs these peripheral targets will end up as user-visible folders
    # and we want to keep them darn out of sight via suitable sorting!
    set(target_cmakelists_update_this_proj_name_ update_cmakelists_${_target_name})
    #add_custom_target(${target_cmakelists_update_this_proj_name_} DEPENDS "${_cmakelists_file}")
    add_custom_target(${target_cmakelists_update_this_proj_name_} ALL DEPENDS "${cmakelists_update_this_proj_updated_stamp_file_}")
#    add_dependencies(${target_cmakelists_update_this_proj_name_} update_cmakelists_rebuild_happened)

    add_dependencies(update_cmakelists_ALL__internal_collector ${target_cmakelists_update_this_proj_name_})

    # We definitely need to implement aborting the build process directly
    # after any new CMakeLists.txt files have been generated
    # (we don't want to go full steam ahead with _old_ CMakeLists.txt content).
    # Ideally processing should be aborted after _all_ sub projects
    # have been converted, but _before_ any of these progress towards
    # building - thus let's just implement it like that ;)
    # This way external build invokers can attempt to do an entire build
    # and if it fails check whether it failed due to conversion and then
    # restart the build. Without this mechanism, external build invokers
    # would _always_ have to first do a separate update_cmakelists_ALL
    # build and _then_ have an additional full build, which wastes
    # valuable seconds for each build of any single file within the
    # project.

    # FIXME: should use that V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD conditional
    # to establish (during one-time setup) a _dummy/non-dummy_ _function_ for rebuild abort handling.
    if(V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD)
      if(need_init_main_targets_this_time_)
        add_custom_command(OUTPUT "${v2c_cmakelists_update_check_stamp_file}"
          # Obviously we need to touch the output file (success indicator) _before_ aborting by invoking false.
          # Also, we need to touch the public marker file as well.
          COMMAND "${CMAKE_COMMAND}" -E touch "${v2c_cmakelists_update_check_stamp_file}" "${cmakelists_update_check_did_abort_public_marker_file}"
          COMMAND "${CMAKE_COMMAND}" -E remove -f "${v2c_update_cmakelists_abort_build_after_update_cleanup_stamp_file}"
          COMMAND "${v2c_abort_BIN}"
          # Hrmm, I thought that we _need_ this dependency, otherwise at least on Ninja the
          # command will not get triggered _within_ the same build run (by the preceding target
          # removing the output file). But apparently that does not help
          # either.
#          DEPENDS "${rebuild_occurred_marker_file}"
          COMMENT ">>> === Detected a rebuild of CMakeLists.txt files - forcefully aborting the current outdated build run (force new updated-settings configure run)! <<< ==="
        )
        add_custom_target(update_cmakelists_abort_build_after_update DEPENDS "${v2c_cmakelists_update_check_stamp_file}")

        add_custom_command(OUTPUT "${v2c_update_cmakelists_abort_build_after_update_cleanup_stamp_file}"
          COMMAND "${CMAKE_COMMAND}" -E remove -f "${cmakelists_update_check_did_abort_public_marker_file}"
          COMMAND "${CMAKE_COMMAND}" -E touch "${v2c_update_cmakelists_abort_build_after_update_cleanup_stamp_file}"
          COMMENT "removed public marker file (for newly converted CMakeLists.txt signalling)!"
        )
        # Mark this target as ALL since it's VERY important that it gets
        # executed ASAP.
        add_custom_target(update_cmakelists_abort_build_after_update_cleanup ALL
          DEPENDS "${v2c_update_cmakelists_abort_build_after_update_cleanup_stamp_file}")

        add_dependencies(update_cmakelists_ALL update_cmakelists_abort_build_after_update_cleanup)
        add_dependencies(update_cmakelists_abort_build_after_update_cleanup update_cmakelists_abort_build_after_update)
        add_dependencies(update_cmakelists_abort_build_after_update update_cmakelists_ALL__internal_collector)
      endif(need_init_main_targets_this_time_)
      add_dependencies(update_cmakelists_abort_build_after_update ${target_cmakelists_update_this_proj_name_})
      set(target_cmakelists_ensure_rebuilt_name_ update_cmakelists_ALL)
    else(V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD)
      if(need_init_main_targets_this_time_)
        add_dependencies(update_cmakelists_ALL update_cmakelists_ALL__internal_collector)
      endif(need_init_main_targets_this_time_)
      set(target_cmakelists_ensure_rebuilt_name_ ${target_cmakelists_update_this_proj_name_})
    endif(V2C_CMAKELISTS_REBUILDER_ABORT_AFTER_REBUILD)

    if(TARGET ${_target_name}) # in some projects an actual target might not exist (i.e. we simply got passed the project name)
      # Make sure the CMakeLists.txt rebuild happens _before_ trying to build the actual target.
      add_dependencies(${_target_name} ${target_cmakelists_ensure_rebuilt_name_})
    endif(TARGET ${_target_name})
  endfunction(v2c_rebuild_on_update _target_name _vcproj_file _cmakelists_file _script _master_proj_dir)
else(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
  function(v2c_rebuild_on_update _target_name _vcproj_file _cmakelists_file _script _master_proj_dir)
    # dummy!
  endfunction(v2c_rebuild_on_update _target_name _vcproj_file _cmakelists_file _script _master_proj_dir)
endif(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)


# This function will set up target properties gathered from
# Visual Studio Source Control Management (SCM) elements.
function(v2c_target_set_properties_vs_scc _target _vs_scc_projectname _vs_scc_localpath _vs_scc_provider)
  #message(STATUS
  #  "v2c_target_set_properties_vs_scc: target ${_target}"
  #  "VS_SCC_PROJECTNAME ${_vs_scc_projectname} VS_SCC_LOCALPATH ${_vs_scc_localpath}\n"
  #  "VS_SCC_PROVIDER ${_vs_scc_provider}"
  #)
  if(_vs_scc_projectname)
    list(APPEND target_properties_list_ VS_SCC_PROJECTNAME "${_vs_scc_projectname}")
    if(_vs_scc_localpath)
      list(APPEND target_properties_list_ VS_SCC_LOCALPATH "${_vs_scc_localpath}")
    endif(_vs_scc_localpath)
    if(_vs_scc_provider)
      list(APPEND target_properties_list_ VS_SCC_PROVIDER "${_vs_scc_provider}")
    endif(_vs_scc_provider)
    set_target_properties(${_target} PROPERTIES ${target_properties_list_})
  endif(_vs_scc_projectname)
endfunction(v2c_target_set_properties_vs_scc _target _vs_scc_projectname _vs_scc_localpath _vs_scc_provider)


if(NOT V2C_INSTALL_ENABLE)
  if(NOT V2C_INSTALL_ENABLE_SILENCE_WARNING)
    # You should make sure to provide install() handling
    # which is explicitly per-target
    # (by using our vcproj2cmake helper functions, or externally taking
    # care of per-target install() handling) - it is very important
    # to _explicitly_ install any targets we create in converted vcproj2cmake files,
    # and _not_ simply "copy-install" entire library directories,
    # since that would cause some target-specific CMake install handling
    # to get lost (e.g. CMAKE_INSTALL_RPATH tweaking will be done in case of
    # proper target-specific install() only!)
    message("WARNING: ${CMAKE_CURRENT_LIST_FILE}: vcproj2cmake-supplied install handling not activated - targets _need_ to be installed properly one way or another!")
  endif(NOT V2C_INSTALL_ENABLE_SILENCE_WARNING)
endif(NOT V2C_INSTALL_ENABLE)

# Helper to cleanly evaluate target-specific setting or, failing that,
# whether target is mentioned in a global list.
# Example: V2C_INSTALL_ENABLE_${_target}, or
#          V2C_INSTALL_ENABLE_TARGETS_LIST contains ${_target}
function(v2c_target_install_get_flag__helper _target _var_prefix _result_out)
  set(v2c_flag_result_ false)
  if(${_var_prefix}_${_target})
    set(v2c_flag_result_ true)
  else(${_var_prefix}_${_target})
    if(${_var_prefix}_TARGETS_LIST)
      foreach(v2c_target_current_ ${${_var_prefix}_TARGETS_LIST})
        if(v2c_target_current_ STREQUAL _target)
          set(v2c_flag_result_ true)
          break()
        endif(v2c_target_current_ STREQUAL _target)
      endforeach(v2c_target_current_ ${${_var_prefix}_TARGETS_LIST})
    endif(${_var_prefix}_TARGETS_LIST)
  endif(${_var_prefix}_${_target})
  set(${_result_out} ${v2c_flag_result_} PARENT_SCOPE)
endfunction(v2c_target_install_get_flag__helper _target _var_prefix _result_out)


# Determines whether a specific target is allowed to be installed.
function(v2c_target_install_is_enabled__helper _target _install_enabled_out)
  set(v2c_install_enabled_ false)
  # v2c-based installation globally enabled?
  if(V2C_INSTALL_ENABLE)
    # First, adopt all-targets setting, then, in case all-targets setting was false,
    # check whether specific setting is enabled.
    # Finally, if we think we're allowed to install it,
    # make sure to check a skip flag _last_, to veto the operation.
    set(v2c_install_enabled_ ${V2C_INSTALL_ENABLE_ALL_TARGETS})
    if(NOT v2c_install_enabled_)
      v2c_target_install_get_flag__helper(${_target} "V2C_INSTALL_ENABLE" v2c_install_enabled_)
    endif(NOT v2c_install_enabled_)
    if(v2c_install_enabled_)
      v2c_target_install_get_flag__helper(${_target} "V2C_INSTALL_SKIP" v2c_install_skip_)
      if(v2c_install_skip_)
        set(v2c_install_enabled_ false)
      endif(v2c_install_skip_)
    endif(v2c_install_enabled_)
    if(NOT v2c_install_enabled_)
      message("v2c_target_install: asked to skip install of target ${_target}")
    endif(NOT v2c_install_enabled_)
  endif(V2C_INSTALL_ENABLE)
  set(${_install_enabled_out} ${v2c_install_enabled_} PARENT_SCOPE)
endfunction(v2c_target_install_is_enabled__helper _target _install_enabled_out)

# Internal variable - lists the parameter types
# which an install() command supports. Upper-case!!
set(v2c_install_param_list EXPORT DESTINATION PERMISSIONS CONFIGURATIONS COMPONENT)

# This is the main pretty flexible install() helper function,
# as used by all vcproj2cmake-generated CMakeLists.txt.
# It is designed to provide very flexible handling of externally
# specified configuration data (global settings, or specific to each
# target).
# Within the generated CMakeLists.txt file, it is supposed to have a
# simple invocation of this function, with default behaviour here to be as
# simple/useful as possible.
# USAGE: at a minimum, you should start by enabling V2C_INSTALL_ENABLE and
# specifying a globally valid V2C_INSTALL_DESTINATION setting
# (or V2C_INSTALL_DESTINATION_EXECUTABLE and V2C_INSTALL_DESTINATION_SHARED_LIBRARY)
# at a more higher-level "configure all of my contained projects" place.
# Ideally, this is done by creating user-interface-visible/configurable
# cache variables (somewhere in your toplevel project root configuration parts)
# to hold your destination directories for libraries and executables,
# then passing down these custom settings into V2C_INSTALL_DESTINATION_* variables.
function(v2c_target_install _target)
  if(NOT TARGET ${_target})
    message("${_target} not a valid target!?")
    return()
  endif(NOT TARGET ${_target})

  # Do external configuration variables indicate
  # that we're allowed to install this target?
  v2c_target_install_is_enabled__helper(${_target} v2c_install_enabled_)
  if(NOT v2c_install_enabled_)
    return() # bummer...
  endif(NOT v2c_install_enabled_)

  # Since install() commands are (probably rightfully) very picky
  # about incomplete/incorrect parameters, we actually need to conditionally
  # compile a list of parameters to actually feed into it.
  #
  #set(v2c_install_params_values_list_ ) # no need to unset (function scope!)

  list(APPEND v2c_install_params_values_list_ TARGETS ${_target})
  foreach(v2c_install_param_ ${v2c_install_param_list})

    set(v2c_install_param_value_ )

    # First, query availability of target-specific settings,
    # then query availability of common settings.
    if(V2C_INSTALL_${v2c_install_param_}_${_target})
      set(v2c_install_param_value_ "${V2C_INSTALL_${v2c_install_param_}_${_target}}")
    else(V2C_INSTALL_${v2c_install_param_}_${_target})

      # Unfortunately, DESTINATION param needs some extra handling
      # (want to support per-target-type destinations):
      if(v2c_install_param_ STREQUAL DESTINATION)
        # result is one of STATIC_LIBRARY, MODULE_LIBRARY, SHARED_LIBRARY, EXECUTABLE
        get_property(target_type_ TARGET ${_target} PROPERTY TYPE)
        #message("target ${_target} type ${target_type_}")
        if(V2C_INSTALL_${v2c_install_param_}_${target_type_})
          set(v2c_install_param_value_ "${V2C_INSTALL_${v2c_install_param_}_${target_type_}}")
        endif(V2C_INSTALL_${v2c_install_param_}_${target_type_})
      endif(v2c_install_param_ STREQUAL DESTINATION)

      if(NOT v2c_install_param_value_)
        # Adopt global setting if specified:
        if(V2C_INSTALL_${v2c_install_param_})
          set(v2c_install_param_value_ "${V2C_INSTALL_${v2c_install_param_}}")
        endif(V2C_INSTALL_${v2c_install_param_})
      endif(NOT v2c_install_param_value_)
    endif(V2C_INSTALL_${v2c_install_param_}_${_target})
    if(v2c_install_param_value_)
      list(APPEND v2c_install_params_values_list_ ${v2c_install_param_} "${v2c_install_param_value_}")
    else(v2c_install_param_value_)
      # v2c_install_param_value_ unset? bail out in case of mandatory parameters (DESTINATION)
      if(v2c_install_param_ STREQUAL DESTINATION)
        message(FATAL_ERROR "Variable V2C_INSTALL_${v2c_install_param_}_${_target} or V2C_INSTALL_${v2c_install_param_} not specified!")
      endif(v2c_install_param_ STREQUAL DESTINATION)
    endif(v2c_install_param_value_)
  endforeach(v2c_install_param_ ${v2c_install_param_list})

  message(STATUS "v2c_target_install: install(${v2c_install_params_values_list_})")
  install(${v2c_install_params_values_list_})
endfunction(v2c_target_install _target)

# The all-in-one helper method for post setup steps
# (install handling, VS properties, CMakeLists.txt rebuilder, ...).
# This function is expected to be _very_ volatile, with frequent signature and content changes
# (--> vcproj2cmake.rb and vcproj2cmake_func.cmake versions should always be kept in sync)
function(v2c_post_setup _target _project_label _vs_keyword _vcproj_file _cmake_current_list_file)
  if(TARGET ${_target})
    v2c_target_install(${_target})

    # Make sure to keep CMake Name/Keyword (PROJECT_LABEL / VS_KEYWORD properties) in our converted file, too...
    # Hrmm, both project() _and_ PROJECT_LABEL reference the same project_name?? WEIRD.
    set_property(TARGET ${_target} PROPERTY PROJECT_LABEL "${_project_label}")
    if(NOT _vs_keyword STREQUAL V2C_NOT_PROVIDED)
      set_property(TARGET ${_target} PROPERTY VS_KEYWORD "${_vs_keyword}")
    endif(NOT _vs_keyword STREQUAL V2C_NOT_PROVIDED)
  endif(TARGET ${_target})
  # Implementation note: the last argument to
  # v2c_rebuild_on_update() should be as much of a 1:1 passthrough of
  # the input argument to the CMakeLists.txt converter ruby script execution as possible/suitable,
  # since invocation arguments of this script on rebuild should be (roughly) identical.
  v2c_rebuild_on_update(${_target} "${_vcproj_file}" "${_cmake_current_list_file}" "${V2C_SCRIPT_LOCATION}" "${V2C_MASTER_PROJECT_DIR}")
  include("${V2C_HOOK_POST}" OPTIONAL)
endfunction(v2c_post_setup _target _project_label _vs_keyword _vcproj_file _cmake_current_list_file)
