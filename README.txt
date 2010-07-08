vcproj2cmake.rb - .vcproj to CMakeLists.txt converter scripts
written by Jesper Eskilson and Andreas Mohr.
FIXME licensing (BSD)

Usage (very rough summary):
- use existing Visual Studio project dir containing .vcproj file
- in that dir, run ruby ......./vcproj2cmake.rb PROJECT.vcproj CMakeLists.txt
  (alternatively, execute vcproj2cmake_recursive.rb to convert an entire hierarchy of .vcproj sub projects)
- upon success, in that dir, run "mkdir build_toolkit1_v2.4_unicode_debug"
- copy all required cmake/Modules, cmake/vcproj2cmake and samples to their respective paths in your project
- cd build_toolkit1_v2.4_unicode_debug
- cmake ..
- make -j3 -k


NOTE: first thing to state is:
if you do not have any users who are hooked on keep using
their static .vcproj files on Visual Studio, then it perhaps makes less sense
to use our converter as a somewhat more cumbersome online converter solution
- instead you may choose to go for a full-scale manual conversion
to CMakeLists.txt files (by basing your initial CMakeLists.txt layout
on the output of our script, too, of course).
That way you can avoid having to deal with the hook script includes as
required by our online conversion concept, and instead modify your
CMakeLists.txt files directly wherever needed (since _they_ are now your
authoritative project information, instead of the static .vcproj files).

OTOH by using our scripts for one-time-conversion only, you will lose out
on any improvements done to our online conversion script in the future
(such as automagically provided installation/packaging configuration mechanisms, ...),
thus it's a tough initial decision to make on whether to maintain an online conversion
infrastructure or to go initial-convert only.



===============================================================================
Explanation of core concepts:

=== Hook script includes ===

In the generated CMakeLists.txt file(s), you may notice lines like
include(${V2C_HOOK_PROJECT} OPTIONAL)
These are meant to provide interception points ("hooks") to enhance online-converted
CMakeLists.txt with specific static content (e.g. to call required CMake Find scripts,
or to override some undesireable .vcproj choices, etc.).
One could just as easily have written this line like
include(cmake/vcproj2cmake/hook_project.txt OPTIONAL)
, but then it would be somewhat less flexible (some environments might want to
temporarily disable use of these included scripts).
Note that variables like V2C_HOOK_PROJECT are defined by our
vcproj2cmake_defs.cmake module.

Example hook scripts to be used by every sub project in your project hierarchy that needs
such customizations are provided in our repository's sample/ directory.

=== mappings files (definitions, dependencies, includes) ===

Certain compiler defines might be Win32-only, and certain other defines might need
a different replacement on a certain other platform.

Dito with library dependencies, and especially with include directories.

This is what vcproj2cmake's mappings file mechanism is meant to solve
(see cmake/vcproj2cmake/include_mappings.txt etc.).


Basic syntax of mappings files is:

Original expression as used by the static Windows side (.vcproj content)
- note case sensitivity! -,
then ':' as separator,
then a platform-specific identifier (WIN32, APPLE, ...) which is used
  in a CMake "if(...)" conditional (or no identifier in case the mapping
  is supposed to be platform-universal),
then a '=' to assign the replacement expression to be used on that platform,
then the ensuing replacement expression.
Then an '|' (pipe, "or") for an optional series of additional platform conditionals.


Note that ideally you merely needs to centrally maintain mappings in your root project part
(ROOT_PROJECT/cmake/vcproj2cmake/*_mappings.txt), since sub projects will also
collect information from the root project in addition to their (optional) local mappings files.




Whenever something needs a better explanation, just tell me and I'll try to improve it.
Dito if you think that some mechanism is poorly implemented (we're still at Alpha stage!).

Happy hacking,

Andreas Mohr <andi@lisas.de>
