vcproj2cmake.rb - .vcproj to CMakeLists.txt converter scripts
written by Jesper Eskilson and Andreas Mohr.
FIXME licensing (BSD)

Usage:
- use existing Visual Studio project dir containing .vcproj file
- in that dir, run ruby ......./vcproj2cmake.rb PROJECT.vcproj CMakeLists.txt .
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


Whenever something needs a better explanation, just tell me and I'll try to improve it.

Happy hacking,

Andreas Mohr <andi@lisas.de>
