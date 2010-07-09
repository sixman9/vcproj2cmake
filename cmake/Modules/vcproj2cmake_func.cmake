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
  # add a filter variable for someone to customize in case he/she doesn't want
  # a rebuild somewhere for some reason
  if(NOT V2C_PREVENT_AUTOMATIC_REBUILD)
    message(STATUS "${_target_name}: installing ${_cmakelists} rebuilder (watching ${_vcproj})")
    add_custom_command(OUTPUT ${_cmakelists}
      COMMAND ruby ${_script} ${_vcproj} ${_cmakelists} ${_master_proj_dir}
      # FIXME add any other relevant dependencies here
      DEPENDS ${_vcproj} ${_script}
      COMMENT "vcproj settings changed, rebuilding ${_cmakelists}"
      VERBATIM
    )

    #add_custom_target(${_target_name}_update_cmakelists VERBATIM DEPENDS ${_cmakelists})
    add_custom_target(${_target_name}_update_cmakelists ALL VERBATIM DEPENDS ${_cmakelists})

  if(TARGET ${_target_name}) # in some projects an actual target might not exist (i.e. we simply got passed the project name)
    # make sure the rebuild happens _before_ trying to build the actual target.
    add_dependencies(${_target_name} ${_target_name}_update_cmakelists)
  endif(TARGET ${_target_name})

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
  endif(NOT V2C_PREVENT_AUTOMATIC_REBUILD)
endfunction(v2c_rebuild_on_update _target_name _vcproj _cmakelists _script _master_proj_dir)
