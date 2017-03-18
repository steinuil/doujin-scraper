require 'oga'
require 'json'

class String
  def as_xml
    Oga.parse_xml self
  end

  def as_json
    JSON.load self
  end
end
