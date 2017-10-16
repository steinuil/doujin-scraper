require 'irb'
require_relative 'scraper'

scraper = Dojin::Scraper.new 'dojin.co'
binding.irb
