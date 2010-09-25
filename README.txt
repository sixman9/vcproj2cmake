vcproj2cmake.rb - .vcproj to CMakeLists.txt converter scripts
written by Jesper Eskilson and Andreas Mohr.
FIXME licensing (BSD)


vcproj2cmake has been fully tested with CMake 2.6.x only, 2.8.x support will follow.


Usage (very rough summary), with Linux/Makefile generator:
- use existing Visual Studio project source tree which contains a .vcproj file
- in the project source tree, run ruby [PATH_TO_VCPROJ2CMAKE]/scripts/vcproj2cmake.rb PROJECT.vcproj
  (alternatively, execute vcproj2cmake_recursive.rb to convert an entire hierarchy of .vcproj sub projects)
- copy all required cmake/Modules, cmake/vcproj2cmake and samples (provided by the vcproj2cmake source tree!)
  to their respective paths in your project source tree
- after successfully converting the .vcproj file to a CMakeLists.txt, start your out-of-tree CMake builds:
  - mkdir ../[PROJECT_NAME].build_toolkit1_v1.2.3_unicode_debug
  - cd ../[PROJECT_NAME].build_toolkit1_v1.2.3_unicode_debug
  - cmake ../[PROJECT_NAME] (alternatively: ccmake ../[PROJECT_NAME])
  - time make -j3 -k


NOTE: first thing to state is:
if you do not have any users who are hooked on keep using
their static .vcproj files on Visual Studio, then it perhaps makes less sense
to use our converter as a somewhat more cumbersome _online converter_ solution
- instead you may choose to go for a full-scale manual conversion
to CMakeLists.txt files (by basing your initial CMakeLists.txt layout
on the output of our script, too, of course).
That way you can avoid having to deal with the hook script includes as
required by our online conversion concept, and instead modify your
CMakeLists.txt files directly wherever needed (since _they_ are now your
authoritative project information, instead of the static .vcproj files).

OTOH by using our scripts for one-time-conversion only, you will lose out
on any of the hopefully substantial improvements done to our
online conversion script in the future
(such as automagically provided installation/packaging configuration mechanisms, ...),
thus it's a tough initial decision to make on whether to maintain an online conversion
infrastructure or to go initial-convert only and thus run _all_ sides on a CMake-based
setup.



===============================================================================
Explanation of core concepts:


=== Hook script includes ===

In the generated CMakeLists.txt file(s), you may notice lines like
include(${V2C_HOOK_PROJECT} OPTIONAL)
These are meant to provide interception points ("hooks") to enhance online-converted
CMakeLists.txt with specific static content (e.g. to call required CMake Find scripts,
or to override some undesireable .vcproj choices, to provide some user-facing
CMake setup cache variables, etc.).
One could just as easily have written this line like
include(cmake/vcproj2cmake/hook_project.txt OPTIONAL)
, but then it would be somewhat less flexible (some environments might want to
temporarily disable use of these included scripts, by changing the variable
to a different/inexistent script).
Note that these required variables like V2C_HOOK_PROJECT are pre-defined by our
vcproj2cmake_defs.cmake module.


Example hook scripts to be used by every sub project in your project hierarchy that needs
such customizations are provided in our repository's sample/ directory.


=== mappings files (definitions, dependencies, library directories, include directories) ===

Certain compiler defines in your projects may be Win32-only,
and certain other defines might need a different replacement on a certain other platform.

Dito with library dependencies, and especially with include and library directories.

This is what vcproj2cmake's mappings file mechanism is meant to solve
(see cmake/vcproj2cmake/include_mappings.txt etc.).


Basic syntax of mappings files is:

Original expression as used by the static Windows side (.vcproj content)
- note case sensitivity! -,
then ':' as separator between original content and CMake-side mappings,
then a platform-specific identifier (WIN32, APPLE, ...) which is used
  in a CMake "if(...)" conditional (or no identifier in case the mapping
  is supposed to be platform-universal),
then a '=' to assign the replacement expression to be used on that platform,
then the ensuing replacement expression.
Then an '|' (pipe, "or") for an optional series of additional platform conditionals.


Note that ideally you merely need to centrally maintain all mappings in your root project part
(ROOT_PROJECT/cmake/vcproj2cmake/*_mappings.txt), since sub projects will also
collect information from the root project in addition to their (optional) local mappings files.


=== Installation/packaging ===

Installation/packaging of a vcproj2cmake-based project is not specially supported yet,
however I'm currently in the process of setting packaging up locally,
thus hopefully this will eventually result in a nicely generic, easily usable
(and optionally overridable!) mechanism which provides a nice Bundle-like
packaging functionality on all platforms (Mac _and_ Linux, and Windows etc.).

I just finished packaging, but in my case all I had to do was to use
GetPrerequisites.cmake on the main project target (i.e., the main executable),
this listed all sub project targets already and allowed me to install them
from a global configuration part.
Thus there's no special per-project vcproj2cmake handling yet.



Whenever something needs a better explanation, just tell me and I'll try to improve it.
Dito if you think that some mechanism is poorly implemented (we're still at Alpha stage!).

Despite being at Alpha stage, the converter is now more than usable enough
to successfully build a very large project consisting of several dozen sub projects.

Happy hacking,

Andreas Mohr <andi@lisas.de>
