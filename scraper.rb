require 'net/http'
require 'json'
require 'oga'
require_relative 'core_ext'

module Dojin
  class Scraper
    # @param url [String] Gee I wonder what URL could possibly go here.
    def initialize url
      @url = URI::HTTP.build host: url.sub(/https?\/\//, '')
    end

    attr_reader :url

    def artists
      tags :artists { |name, id| Artist.new name, id }
    end

    def genres
      tags :genres { |name, id| Genre.new name, id }
    end

    def albums query
      id =
        case query
        when Integer then query
        when String then artists_hash[query]
        when Regexp
          artists.select { |a| a.name =~ query }.first.id rescue nil
        end

      return nil unless id

      fetch_albums search: { artist: id }
    end

    def newest offset = 0
      fetch_albums offset: offset.*(25)
    end

    def changes
      records = {}
      comments_query = '//ol[@id="commentList_"]//div[@class="comment_message"]/p'

      homepage.xpath(comments_query).take(25).reverse.each do |change|
        id = change.xpath('a/@href').text[6..-1].to_i

        type =
          case change.text
          when /.+? is broken\./        then :broken
          when /.+? has been editted\./ then :edit
          end

        # We only need the first ones in chronological order,
        # so we ignore those we've already seen.
        next if records[id] or type.nil?

        records[id] = type
      end

      records.map { |a| Change.new *a }
    end

    # Refresh the homepage for fetching the new changes
    # in case of a long-running process.
    def refresh!
      @homepage, @artists, @genres = nil
    end

    def fetch_albums search: nil, from_ids: nil, offset: 0
      params =
        if    search.is_a? Hash and from_ids.nil?
          params_search search
        elsif search.nil?       and from_ids.is_a? Array
          params_from_ids from_ids
        elsif search.nil?       and from_ids.nil? # fetch the new albums
          params_from_ids [], offset: offset
        else
          raise ArgumentError#.new "#{search.class.inspect} | #{from_ids.inspect}"
        end

      album_ids = from_ids || nil
      records = []

      loop do
        page = Net::HTTP
          .post_form(url.merge('/wp-admin/admin-ajax.php'), params).body
          .force_encoding('UTF-8')
          .gsub(/targetLink[^\s]+/, '') # these often fuck up the parsing
          .as_json

        return nil unless page

        album_ids ||= page['arraySet']
        
        new =
          begin
            doc = (page['album'] || page['data']).as_xml

            ids = doc.css('.music').map { |a| a.xpath('@postid').text.to_i }
            titles = doc.css('.cellInformation_edit_title').map(&:text)
            covers = doc.xpath('//div[@class="album-container"]/img/@src').map(&:text)

            broken = doc.xpath('//div[@class="album-container"]').map do |a|
              a.css('.broken_album_overlay-text').text == 'Please Fix'
            end

            links = doc.css('.cellInformation_edit_download').zip(broken).map do |l|
              l[0].text unless l[1] # return nil if the link is broken
            end

            genres = doc.css('.cellInformation_edit_style').map do |s|
              s.text.split(?,).map { |g| genres_hash[g.strip] }
            end

            artists = doc.css('.cellInformation_edit_artist').map do |as|
              as.text.split(?,).map { |a| artists_hash[a.strip] }
            end

            [ ids, titles, links, covers, genres, artists ].transpose.map do |album|
              Album.new *album
            end
          end

        records += new

        break if album_ids.nil? or records.size == album_ids.size

        params = params_from_ids(album_ids, offset: records.size)
      end

      records
    end

    private

    def artists_hash
      @artists ||= Hash[tags :artists { |name, id| [ name, id ] }]
    end

    def genres_hash
      @genres ||= Hash[tags :genres { |name, id| [ name, id ] }]
    end

    # A search returns the first
    def params_search(query: [], artist: nil, genres: [],
               excluded_artists: [], excluded_genres: [])
      { action: 'exploreLoad',
        artist: artist.to_s,
        style: genres,
        exartist: excluded_artists,
        exstyle: excluded_genres,
        searchQuery: query,
        orderType: 'downloads',
        orderDate: 'all',
        orderDateMagnitude: '', # wut
        onlyShowBroken: false
      }
    end

    # Get albums when you already know the IDs.
    def params_from_ids albums, offset: 0
      { action: 'infiniteScrollingAction',
        postsPerPage: 25, # absolutely useless
        offset: offset,
        arraySet: albums.to_json
      }
    end

    # @param type [:artists, :genres]
    # @raise [ArgumentError] If the argument is not
    #   +:artists+ or +:genres+.
    # @yield [name, id]
    # @return [Array<T>]
    def tags type
      query =
        case type
        when :artists then 'artist'
        when :genres then 'style'
        else
          raise ArgumentError.new "invalid type: #{type}"
        end

      homepage.xpath("//div[@type=\"m_#{query}\"]").map do |a|
        yield a.text, a.xpath('@value').text.to_i
      end
    end

    def homepage
      @homepage ||= Net::HTTP.get(url)
        .force_encoding('UTF-8')
        .as_xml
    end
  end

  # @attr name [String] Artist name.
  # @attr id [Integer] Artist ID in the database.
  Artist = Struct.new(:name, :id)

  # @attr name [String] Genre name.
  # @attr id [Integer] Genre ID in the database.
  Genre = Struct.new(:name, :id)

  # @attr album [Integer] Album referred to in the change.
  # @attr type [Symbol] Type of change.
  #   Can be either +:edit+ or +:broken+.
  Change = Struct.new(:album, :type)

  # @attr id [Integer] Album ID in the database.
  # @attr title [String] Album title.
  # @attr url [String, nil] Download link, +nil+ when the link is broken.
  # @attr cover [String] The URL of the cover.
  # @attr genres [Array<Integer>] Album genre IDs.
  # @attr artists [Array<Integer>] Album artists IDs.
  Album = Struct.new(
    :id, :title, :url, :cover, :genres, :artists
  )
end
