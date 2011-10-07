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

# FIXME: should obey V2C_LOCAL_CONFIG_DIR setting!!
set(v2c_mappings_files "cmake/vcproj2cmake/*_mappings.txt")

file(GLOB root_mappings "${CMAKE_SOURCE_DIR}/${v2c_mappings_files}")


# Function to automagically rebuild our converted CMakeLists.txt
# by the original converter script in case any relevant files changed.
function(v2c_rebuild_on_update _target_name _vcproj _cmakelists_file _script _master_proj_dir)
  if(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
    message(STATUS "${_target_name}: providing ${_cmakelists_file} rebuilder (watching ${_vcproj})")
    if(NOT v2c_ruby) # avoid repeated checks (see cmake --trace)
      find_program(v2c_ruby NAMES ruby)
      if(NOT v2c_ruby)
        message("could not detect your ruby installation (perhaps forgot to set CMAKE_PREFIX_PATH?), aborting: won't automagically rebuild CMakeLists.txt on changes...")
        return()
      endif(NOT v2c_ruby)
    endif(NOT v2c_ruby)
    # there are some uncertainties about how to locate the ruby script.
    # for now, let's just hardcode a "must have been converted from root project" requirement.
    ## canonicalize script, to be able to precisely launch it via a CMAKE_SOURCE_DIR root dir base
    #file(RELATIVE_PATH _script_rel "${CMAKE_SOURCE_DIR}" "${_script}")
    ##message(FATAL_ERROR "_script ${_script} _script_rel ${_script_rel}")
    # need an intermediate stamp file, otherwise "make clean" will clean
    # our live output file (CMakeLists.txt), yet we need to preserve it
    # since it hosts this very CMakeLists.txt rebuilder...
    set(stamp_file "${CMAKE_CURRENT_BINARY_DIR}/cmakelists_rebuilder.stamp")
    # add dependencies for mappings files in both root project and current project
    list(APPEND v2c_mappings ${root_mappings})
    file(GLOB proj_mappings "${v2c_mappings_files}")
    list(APPEND v2c_mappings ${proj_mappings})
    #message("v2c_mappings ${v2c_mappings}")
    add_custom_command(OUTPUT "${stamp_file}"
      COMMAND "${v2c_ruby}" "${_script}" "${_vcproj}" "${_cmakelists_file}" "${_master_proj_dir}"
      COMMAND "${CMAKE_COMMAND}" -E touch "${stamp_file}"
      # FIXME add any other relevant dependencies here
      DEPENDS "${_vcproj}" "${_script}" ${v2c_mappings} "${v2c_ruby}"
      COMMENT "vcproj settings changed, rebuilding ${_cmakelists_file}"
      VERBATIM
    )
    # TODO: do we have to set_source_files_properties(GENERATED) on ${_cmakelists_file}?

    # NOTE: we use update_cmakelists_[TARGET] names instead of [TARGET]_...
    # since in certain IDEs these peripheral targets will end up as user-visible folders
    # and we want to keep them darn out of sight via suitable sorting!
    set(target_update_cmakelists update_cmakelists_${_target_name})
    #add_custom_target(${target_update_cmakelists} DEPENDS "${_cmakelists_file}")
    add_custom_target(${target_update_cmakelists} ALL DEPENDS "${stamp_file}")

    if(TARGET ${_target_name}) # in some projects an actual target might not exist (i.e. we simply got passed the project name)
      # make sure the rebuild happens _before_ trying to build the actual target.
      add_dependencies(${_target_name} ${target_update_cmakelists})
    else(TARGET ${_target_name})
      message(STATUS "INFO: hmm, no target available to setup CMakeLists.txt updater target ordering.")
    endif(TARGET ${_target_name})
    # and have an update_cmakelists_ALL target to be able to update all
    # outdated CMakeLists.txt files within a project hierarchy
    if(NOT TARGET update_cmakelists_ALL)
      add_custom_target(update_cmakelists_ALL)
    endif(NOT TARGET update_cmakelists_ALL)
    add_dependencies(update_cmakelists_ALL ${target_update_cmakelists})

# FIXME!!: we should definitely achieve aborting build process directly
# after a new CMakeLists.txt has been generated (we don't want to go
# full steam ahead with _old_ CMakeLists.txt content),
# however I don't quite know yet how to hook up those targets
# to actually get it to work.
# ok, well, in fact ideally processing should be aborted after _all_ sub projects
# have been converted, but _before_ any of these progresses towards building.
# Which is even harder to achieve, I guess... (set a marker variable
# or marker file and check for it somewhere global at the end of it all,
# then abort, that would be the idea)
#  add_custom_target(update_cmakelists_abort_build ALL
##    COMMAND /bin/false
#    COMMAND sdfgsdf
#    DEPENDS "${_cmakelists_file}"
#    VERBATIM
#  )
#
#  add_dependencies(update_cmakelists_abort_build update_cmakelists)
  endif(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
endfunction(v2c_rebuild_on_update _target_name _vcproj _cmakelists_file _script _master_proj_dir)


# This function will set up target properties gathered from
# Visual Studio Source Control Management (SCM) elements.
function(v2c_target_set_properties_vs_scc _target _vs_scc_projectname _vs_scc_localpath _vs_scc_provider)
  #message(STATUS
  #  "v2c_target_set_properties_vs_scc: target ${_target}"
  #  "VS_SCC_PROJECTNAME ${_vs_scc_projectname} VS_SCC_LOCALPATH ${_vs_scc_localpath}\n"
  #  "VS_SCC_PROVIDER ${_vs_scc_provider}"
  #)
  if(_vs_scc_projectname)
    set_property(TARGET ${_target} PROPERTY VS_SCC_PROJECTNAME "${_vs_scc_projectname}")
    if(_vs_scc_localpath)
      set_property(TARGET ${_target} PROPERTY VS_SCC_LOCALPATH "${_vs_scc_localpath}")
    endif(_vs_scc_localpath)
    if(_vs_scc_provider)
      set_property(TARGET ${_target} PROPERTY VS_SCC_PROVIDER "${_vs_scc_provider}")
    endif(_vs_scc_provider)
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
  set(v2c_flag_result false)
  if(${_var_prefix}_${_target})
    set(v2c_flag_result true)
  else(${_var_prefix}_${_target})
    if(${_var_prefix}_TARGETS_LIST)
      foreach(v2c_target_current ${${_var_prefix}_TARGETS_LIST})
        if(v2c_target_current STREQUAL _target)
          set(v2c_flag_result true)
          break()
        endif(v2c_target_current STREQUAL _target)
      endforeach(enable_target ${${_var_prefix}_TARGETS_LIST})
    endif(${_var_prefix}_TARGETS_LIST)
  endif(${_var_prefix}_${_target})
  set(${_result_out} ${v2c_flag_result} PARENT_SCOPE)
endfunction(v2c_target_install_get_flag__helper _target _var_prefix _result_out)


# Determines whether a specific target is allowed to be installed.
function(v2c_target_install_is_enabled__helper _target _install_enabled_out)
  set(v2c_install_enabled false)
  # v2c-based installation globally enabled?
  if(V2C_INSTALL_ENABLE)
    # First, adopt all-targets setting, then, in case all-targets setting was false,
    # check whether specific setting is enabled.
    # Finally, if we think we're allowed to install it,
    # make sure to check a skip flag _last_, to veto the operation.
    set(v2c_install_enabled ${V2C_INSTALL_ENABLE_ALL_TARGETS})
    if(NOT v2c_install_enabled)
      v2c_target_install_get_flag__helper(${_target} "V2C_INSTALL_ENABLE" v2c_install_enabled)
    endif(NOT v2c_install_enabled)
    if(v2c_install_enabled)
      v2c_target_install_get_flag__helper(${_target} "V2C_INSTALL_SKIP" v2c_install_skip)
      if(v2c_install_skip)
        set(v2c_install_enabled false)
      endif(v2c_install_skip)
    endif(v2c_install_enabled)
    if(NOT v2c_install_enabled)
      message("v2c_target_install: asked to skip install of target ${_target}")
    endif(NOT v2c_install_enabled)
  endif(V2C_INSTALL_ENABLE)
  set(${_install_enabled_out} ${v2c_install_enabled} PARENT_SCOPE)
endfunction(v2c_target_install_is_enabled__helper _target)

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
# At a minimum, you should start by enabling V2C_INSTALL_ENABLE and
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
  v2c_target_install_is_enabled__helper(${_target} v2c_install_enabled)
  if(NOT v2c_install_enabled)
    return() # bummer...
  endif(NOT v2c_install_enabled)

  # Since install() commands are (probably rightfully) very picky
  # about incomplete/incorrect parameters, we actually need to conditionally
  # compile a list of parameters to actually feed into it.
  #
  #set(v2c_install_params_list ) # no need to unset (function scope!)

  list(APPEND v2c_install_params_list TARGETS ${_target})
  foreach(v2c_install_param ${v2c_install_param_list})

    set(v2c_install_param_value )

    # First, query availability of target-specific settings,
    # then query availability of common settings.
    if(V2C_INSTALL_${v2c_install_param}_${_target})
      set(v2c_install_param_value "${V2C_INSTALL_${v2c_install_param}_${_target}}")
    else(V2C_INSTALL_${v2c_install_param}_${_target})

      # Unfortunately, DESTINATION param needs some extra handling
      # (want to support per-target-type destinations):
      if(v2c_install_param STREQUAL DESTINATION)
        # result is one of STATIC_LIBRARY, MODULE_LIBRARY, SHARED_LIBRARY, EXECUTABLE
        get_property(target_type TARGET ${_target} PROPERTY TYPE)
        #message("target ${_target} type ${target_type}")
        if(V2C_INSTALL_${v2c_install_param}_${target_type})
          set(v2c_install_param_value "${V2C_INSTALL_${v2c_install_param}_${target_type}}")
        endif(V2C_INSTALL_${v2c_install_param}_${target_type})
      endif(v2c_install_param STREQUAL DESTINATION)

      if(NOT v2c_install_param_value)
        # Adopt global setting if specified:
        if(V2C_INSTALL_${v2c_install_param})
          set(v2c_install_param_value "${V2C_INSTALL_${v2c_install_param}}")
        endif(V2C_INSTALL_${v2c_install_param})
      endif(NOT v2c_install_param_value)
    endif(V2C_INSTALL_${v2c_install_param}_${_target})
    if(v2c_install_param_value)
      list(APPEND v2c_install_params_list ${v2c_install_param} "${v2c_install_param_value}")
    else(v2c_install_param_value)
      # v2c_install_param_value unset? bail out in case of mandatory parameters (DESTINATION)
      if(v2c_install_param STREQUAL DESTINATION)
        message(FATAL_ERROR "Variable V2C_INSTALL_${v2c_install_param}_${_target} or V2C_INSTALL_${v2c_install_param} not specified!")
      endif(v2c_install_param STREQUAL DESTINATION)
    endif(v2c_install_param_value)
  endforeach(v2c_install_param ${v2c_install_param_list})

  message(STATUS "v2c_target_install: install(${v2c_install_params_list})")
  install(${v2c_install_params_list})
endfunction(v2c_target_install _target)
