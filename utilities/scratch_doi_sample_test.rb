require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

abort 'provide a comma-separated DOI list as ARGV[0]' unless ARGV[0]

allpubs, messages = CBGP::Loaders.bulk_load_from_dois(dois: ARGV[0])

puts
messages.each { |m| puts m }
puts
puts "#{allpubs.size} publication(s) actually written."
