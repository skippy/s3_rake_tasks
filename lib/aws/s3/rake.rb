#TODO: for some reason, :upload => :environment causes an exception to be thrown in acts_as_paranoid...
# doing it with require works except it brings in some additional dependencies like the correct db needs to
# be valid and it is initalized....
require "config/environment"

begin
  require 'aws/s3'
rescue LoadError
  puts "you need to install the AWS::S3 gem.  Go to the nearest terminal and run"
  puts "  $ sudo gem i aws-s3 -ry"
  puts "It's the only way..."
  exit
end  


require 'yaml'
require 'erb'
require 'active_record'

require File.dirname(__FILE__) + '/rake/base'
require File.dirname(__FILE__) + '/rake/backup'
require File.dirname(__FILE__) + '/rake/static'
require File.dirname(__FILE__) + '/rake/utils'
require File.dirname(__FILE__) + '/../../float_ext'
include AWS::S3
include AWS::S3::Rake

AWS::S3::Rake::Base.init
