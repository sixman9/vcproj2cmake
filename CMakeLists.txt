# We advertise that our vcproj2cmake tools (not this install handler!)
# need at least this version...
set(vcproj2cmake_cmake_compat_req "2.6.2")
# ...thus check for it here already (FIXME: this is not customer-friendly - we
# should check manually and launch a FATAL_ERROR with wording specific to
# vcproj2cmake tools).
# And perhaps even gather ("file(READ ...)") the version value directly from our
# scripts...
cmake_minimum_required(VERSION ${vcproj2cmake_cmake_compat_req} FATAL_ERROR)

message(STATUS "Welcome to the installation handler of vcproj2cmake!")

set(v2c_vcproj_proj_source_root_doc "Path to the root directory of the Visual Studio .vcproj-based source project you would like to CMake-enable")

# Provide a config option to let people choose to automatically
# download and convert/compile a very nice demo .vcproj app from somewhere...
set(v2c_vcproj_load_demo_app true CACHE BOOL "Do you want to install/process this converter on a demo tree downloaded from the Internet?")
if(v2c_vcproj_load_demo_app)
  # TODO: perhaps move into a demoApp.cmake file.
  function(v2c_svn_checkout _repo_url _name _dir)
    find_package(Subversion)
    if(NOT Subversion_FOUND)
      message(FATAL_ERROR "the project ${_name} needs to be fetched via Subversion, which is not installed - please install a Subversion package!")
    endif(NOT Subversion_FOUND)
    add_custom_command(OUTPUT "${_dir}"
      COMMAND "${Subversion_SVN_EXECUTABLE}" checkout "${_repo_url}" "${_dir}"
      DEPENDS "${Subversion_SVN_EXECUTABLE}"
      COMMENT "fetching SVN repository of ${_name} into ${_dir}"
    )
    add_custom_target(svn_checkout_${_name} ALL DEPENDS "${_dir}")
  endfunction(v2c_svn_checkout _repo_url _name _dir)
  function(v2c_fetch_demo_app_osdab _demo_app_root_dir)
    set(demo_app_name "osdab")
    set(demo_app_repo_url "http://osdab.googlecode.com/svn/trunk/")
    v2c_svn_checkout("${demo_app_repo_url}" "${demo_app_name}" "${_demo_app_root_dir}")
  endfunction(v2c_fetch_demo_app_osdab _demo_app_root_dir)

  # obey TMPDIR env variable convention:
  set(tmpdir "$ENV{TMPDIR}")
  if(NOT IS_DIRECTORY "${tmpdir}")
    if(WIN32)
      set(tmpdir "C:\temp")
    else(WIN32)
      set(tmpdir "/tmp")
    endif(WIN32)
  endif(NOT IS_DIRECTORY "${tmpdir}")
  set(v2c_demo_app_root "${tmpdir}/vcproj2cmake_demo_app")
  v2c_fetch_demo_app_osdab("${v2c_demo_app_root}")

  set(v2c_vcproj_proj_source_root "${v2c_demo_app_root}" CACHE STRING "${v2c_vcproj_proj_source_root_doc}" FORCE)
  # _we_ set it, thus hide it from user.
  mark_as_advanced(v2c_vcproj_proj_source_root)
else(v2c_vcproj_load_demo_app)
  set(v2c_vcproj_proj_source_root "" CACHE STRING "${v2c_vcproj_proj_source_root_doc}")
  mark_as_advanced(CLEAR v2c_vcproj_proj_source_root)
endif(v2c_vcproj_load_demo_app)
message(STATUS "root directory of project source configured to ${v2c_vcproj_proj_source_root}")

set(v2c_vcproj2cmake_subdir_default_setting "cmake/vcproj2cmake")
set(v2c_vcproj2cmake_subdir "${v2c_vcproj2cmake_subdir_default_setting}" CACHE STRING "Relative location of the newly created vcproj2cmake tools path within your project")

set(v2c_module_path_subdir_default_setting "cmake/Modules")
set(v2c_module_path_subdir "${v2c_module_path_subdir_default_setting}" CACHE STRING "Relative location of the newly created CMake module path within the project")

set(v2c_vcproj_proj_do_convert_default_setting true)
set(v2c_vcproj_proj_do_convert ${v2c_vcproj_proj_do_convert_default_setting} CACHE BOOL "Should we automatically run a recursive conversion of projects to CMakeLists.txt within the source root directory of your .vcproj-based project?")

# We don't want the user to see this - the user should be configuring our
# specific source root dir of a .vcproj project.
mark_as_advanced(CMAKE_INSTALL_PREFIX)

if(v2c_vcproj_proj_source_root)
  # Validate source root, but only in case of a
  # supposedly already existing manually assigned project
  # (demo apps will be downloaded later).
  if(NOT v2c_vcproj_load_demo_app)
    set(validate_source_root true)
  endif(NOT v2c_vcproj_load_demo_app)
else(v2c_vcproj_proj_source_root)
  message(FATAL_ERROR "invalid source root directory ${v2c_vcproj_proj_source_root}!")
endif(v2c_vcproj_proj_source_root)

if(validate_source_root)
  if(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")
    set(CMAKE_INSTALL_PREFIX "${v2c_vcproj_proj_source_root}")
  else(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")
    message(FATAL_ERROR "ERROR: the source root of the .vcproj-based Visual Studio project (at ${v2c_vcproj_proj_source_root}) is not a valid directory, please correct!")
  endif(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")
endif(validate_source_root)

# We don't want the user to see this since we don't need it at all...
mark_as_advanced(CMAKE_BUILD_TYPE)

set(v2c_module_path_destination "${v2c_vcproj_proj_source_root}/${v2c_module_path_subdir}")
set(v2c_mappings_destination "${v2c_vcproj_proj_source_root}/${v2c_vcproj2cmake_subdir}")
add_subdirectory(cmake)

set(v2c_samples_destination "${v2c_vcproj_proj_source_root}/${v2c_vcproj2cmake_subdir}")
add_subdirectory(samples)

set(v2c_scripts_destination "${v2c_vcproj_proj_source_root}/${v2c_vcproj2cmake_subdir}/scripts")
add_subdirectory(scripts)

if(v2c_vcproj_proj_do_convert)
  v2c_scripts_convert_project_recursive("${v2c_vcproj_proj_source_root}")
endif(v2c_vcproj_proj_do_convert)
