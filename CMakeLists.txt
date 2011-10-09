# We advertise that our vcproj2cmake tools (not this install handler!)
# need at least this version...
set(vcproj2cmake_cmake_compat_req "2.6.2")
# ...thus check for it here already (FIXME: this is not customer-friendly - we
# should check manually and launch a FATAL_ERROR with wording specific to
# vcproj2cmake tools).
# And perhaps even gather ("file(READ ...)") the version value directly from our
# scripts...
cmake_minimum_required(VERSION ${vcproj2cmake_cmake_compat_req} FATAL_ERROR)

project(v2c_installer NONE)

message(STATUS "Welcome to the installation handler of vcproj2cmake!")

set(v2c_vcproj_proj_source_root_doc "Path to the root directory of the Visual Studio .vcproj-based source project that you would like to CMake-enable")

# Provide a config option to let people choose to automatically
# download and convert/compile a very nice demo .vcproj app from somewhere...
set(v2c_vcproj_load_demo_app true CACHE BOOL "Do you want to install/process this converter on a demo tree downloaded from the Internet?")
if(v2c_vcproj_load_demo_app)
  # TODO: perhaps move into a demoApp.cmake file.
  function(v2c_svn_checkout _repo_url _name _dir)
    find_package(Subversion)
    if(NOT Subversion_FOUND)
      message(FATAL_ERROR "the .vcproj-based demo application ${_name} needs to be fetched via Subversion, which is not installed - please install a Subversion package!")
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

  function(v2c_fetch_demo_app_sebclient _demo_app_root_dir)
    set(demo_app_name "SebWindowsClient")
    set(demo_app_repo_url "https://seb.svn.sourceforge.net/svnroot/seb/trunk/win/SebWindowsPackage/SebWindowsClient")
    v2c_svn_checkout("${demo_app_repo_url}" "${demo_app_name}" "${_demo_app_root_dir}")
  endfunction(v2c_fetch_demo_app_sebclient _demo_app_root_dir)

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
  # Ouch, sebclient is _very_ large (139MB) - thus do not offer it as a publicly visible default.
  #v2c_fetch_demo_app_sebclient("${v2c_demo_app_root}")

  set(v2c_vcproj_proj_source_root "${v2c_demo_app_root}" CACHE STRING "${v2c_vcproj_proj_source_root_doc}" FORCE)
  # Originally we had some broken mark_as_advanced() mechanism to hide
  # the source root from the user in case of an app download,
  # but that's stupid since the user should _learn_ where it will get
  # downloaded to.
else(v2c_vcproj_load_demo_app)
  set(v2c_vcproj_proj_source_root "" CACHE STRING "${v2c_vcproj_proj_source_root_doc}")
endif(v2c_vcproj_load_demo_app)
message(STATUS "root directory of project source configured to ${v2c_vcproj_proj_source_root}")

set(v2c_vcproj2cmake_install_dir_default_setting "cmake/vcproj2cmake")
set(v2c_vcproj2cmake_install_dir "${v2c_vcproj2cmake_install_dir_default_setting}" CACHE STRING "Relative location of the newly created vcproj2cmake tools path within your project")

set(v2c_module_path_subdir_default_setting "cmake/Modules")
set(v2c_module_path_subdir "${v2c_module_path_subdir_default_setting}" CACHE STRING "Relative location of the newly created CMake module path within the project")

set(v2c_vcproj_proj_do_convert_default_setting true)
set(v2c_vcproj_proj_do_convert ${v2c_vcproj_proj_do_convert_default_setting} CACHE BOOL "Should we automatically run a recursive conversion of projects to CMakeLists.txt within the source root directory of your .vcproj-based project?")

# We don't want the user to see this - the user should be configuring our
# specific source root dir of a .vcproj project.
mark_as_advanced(CMAKE_INSTALL_PREFIX)

# We don't want the user to see this since we don't need it at all...
mark_as_advanced(CMAKE_BUILD_TYPE)

if(v2c_vcproj_proj_source_root)
  # Validate source root, but only in case of a
  # supposedly already existing manually assigned project
  # (demo apps will be downloaded later).
  if(NOT v2c_vcproj_load_demo_app)
    set(missing_source_root_is_fatal true)
  endif(NOT v2c_vcproj_load_demo_app)
else(v2c_vcproj_proj_source_root)
  message(FATAL_ERROR "invalid/empty source root directory string ${v2c_vcproj_proj_source_root}!")
endif(v2c_vcproj_proj_source_root)

if(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")
  set(v2c_installable true)
else(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")
  if(missing_source_root_is_fatal)
    message(FATAL_ERROR "ERROR: directory ${v2c_vcproj_proj_source_root} (the source root of the .vcproj-based Visual Studio project that you would like to CMake-enable) is not valid, please correct!")
  endif(missing_source_root_is_fatal)
endif(IS_DIRECTORY "${v2c_vcproj_proj_source_root}")

# If configuration appears to be valid, then we can define
# CMAKE_INSTALL_PREFIX and include subdirs which will install some
# v2c infrastructure.
if(v2c_installable)
  set(CMAKE_INSTALL_PREFIX "${v2c_vcproj_proj_source_root}")
  set(v2c_module_path_install_dir "${v2c_vcproj_proj_source_root}/${v2c_module_path_subdir}")
  set(v2c_mappings_install_dir "${v2c_vcproj_proj_source_root}/${v2c_vcproj2cmake_install_dir}")
  add_subdirectory(cmake)

  set(v2c_samples_install_dir "${v2c_vcproj_proj_source_root}/${v2c_vcproj2cmake_install_dir}")
  add_subdirectory(samples)

  set(v2c_scripts_install_dir "${v2c_vcproj2cmake_install_dir}/scripts")
  add_subdirectory(scripts)

  if(v2c_vcproj_proj_do_convert)
    v2c_scripts_convert_project_recursive("${v2c_vcproj_proj_source_root}")
  endif(v2c_vcproj_proj_do_convert)
endif(v2c_installable)
