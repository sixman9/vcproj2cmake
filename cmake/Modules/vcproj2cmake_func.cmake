# This vcproj2cmake-specific CMake module should be available
# at least in your root project (i.e., PROJECT/cmake/Modules/)

# Some helper functions to be used by all converted projects in the tree

# avoid useless repeated parsing
if(V2C_FUNC_DEFINED)
  return()
endif(V2C_FUNC_DEFINED)
set(V2C_FUNC_DEFINED true)


# Function to automagically rebuild our converted CMakeLists.txt
# by the original converter script in case any relevant files changed.
function(v2c_rebuild_on_update _target_name _vcproj _cmakelists _script _master_proj_dir)
  if(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
    message(STATUS "${_target_name}: installing ${_cmakelists} rebuilder (watching ${_vcproj})")
    find_program(v2c_ruby NAMES ruby)
    if(NOT v2c_ruby)
      message("could not detect your ruby installation (perhaps forgot to set CMAKE_PREFIX_PATH?), aborting: won't automagically rebuild CMakeLists.txt on changes...")
      return()
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
    # FIXME: should obey V2C_LOCAL_CONFIG_DIR setting!!
    set(mappings_files "cmake/vcproj2cmake/*_mappings.txt")
    file(GLOB mappings "${CMAKE_SOURCE_DIR}/${mappings_files}")
    list(APPEND v2c_mappings ${mappings})
    file(GLOB mappings "${mappings_files}")
    list(APPEND v2c_mappings ${mappings})
    #message("v2c_mappings ${v2c_mappings}")
    add_custom_command(OUTPUT "${stamp_file}"
      COMMAND ${v2c_ruby} ${_script} ${_vcproj} ${_cmakelists} ${_master_proj_dir}
      COMMAND "${CMAKE_COMMAND}" -E touch "${stamp_file}"
      # FIXME add any other relevant dependencies here
      DEPENDS ${_vcproj} ${_script} ${v2c_mappings}
      COMMENT "vcproj settings changed, rebuilding ${_cmakelists}"
      VERBATIM
    )
    # TODO: do we have to set_source_files_properties(GENERATED) on ${_cmakelists}?

    # NOTE: we use update_cmakelists_[TARGET] names instead of [TARGET]_...
    # since in certain IDEs these peripheral targets will end up as user-visible folders
    # and we want to keep them darn out of sight via suitable sorting!
    set(target_update_cmakelists update_cmakelists_${_target_name})
    #add_custom_target(${target_update_cmakelists} DEPENDS ${_cmakelists} VERBATIM)
    add_custom_target(${target_update_cmakelists} ALL VERBATIM DEPENDS "${stamp_file}" VERBATIM)

    if(TARGET ${_target_name}) # in some projects an actual target might not exist (i.e. we simply got passed the project name)
      # make sure the rebuild happens _before_ trying to build the actual target.
      add_dependencies(${_target_name} ${target_update_cmakelists})
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
#    DEPENDS "${_cmakelists}"
#    VERBATIM
#  )
#
#  add_dependencies(update_cmakelists_abort_build update_cmakelists)
  endif(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER)
endfunction(v2c_rebuild_on_update _target_name _vcproj _cmakelists _script _master_proj_dir)
