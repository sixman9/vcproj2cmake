# compat module to abstract away the fileutils / ftools unreliable
# dependency.
# fileutils not available on Ruby 1.6.8 (RHEL3),
# but ftools exists.
# fileutils is provided starting from 1.8.0 or some such.
#
# TODO: do some dynamic probing of dependency availability.
# . require 'rubygems' if RUBY_VERSION < "1.9"
# . http://brettterpstra.com/gvoice-command-line-sms-revisited/
# . http://titusd.co.uk/2010/04/07/a-beginners-sinatra-tutorial/
# . http://stackoverflow.com/questions/6830510/problem-when-doing-heroku-rake-dbmigrate-to-rails-app
# . do dynamic method detection:
#   . http://stackoverflow.com/questions/5774947/get-all-local-variables-or-available-methods-from-irb
#   . http://mlomnicki.com/ruby/tricks-and-quirks/2011/01/26/ruby-tricks1.html
#   . http://stackoverflow.com/questions/175655/how-to-find-where-a-ruby-method-is-defined-at-runtime


#require 'fileutils'
#include FileUtils::Verbose

require 'ftools'


# http://wiki.ruby-portal.de/Modul

module V2C_Util_File
  def chmod(mode, *files)
    return File.chmod(mode, *files)
  end
  module_function :chmod
  def cmp(a, b)
    return File.cmp(a, b)
  end
  module_function :cmp

  def makedirs(list)
    return File.makedirs(list)
  end
  module_function :makedirs

  def move(from, to, verbose = false)
    return File.move(from, to, verbose)
  end
  alias mv move
  module_function :mv
end
