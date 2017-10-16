require 'net/http'
require 'json'
require 'oga'
require_relative 'core_ext'

module Dojin
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

  class Scraper
    ALBUMS_PER_PAGE = 25

    def initialize url
      @url = URI::HTTP.build host: url.sub(/https?\/\//, '')
    end

    attr_reader :url

    # Returns an array of Artists
    # with all the artists on the homepage
    def artists
      tags :artists { |name, id| Artist.new name, id }
    end

    # Returns an array of all Genres
    def genres
      tags :genres { |name, id| Genre.new name, id }
    end

    # Search for all the albums by a certain artist
    def albums_by query
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

    # Returns the newest albums
    def newest offset = 0
      fetch_albums offset: offset.*(ALBUMS_PER_PAGE)
    end

    # Refresh the homepage for fetching the new changes
    # in case of a long-running process.
    def refresh!
      @homepage, @artists, @genres = nil
    end

    # Return all albums that match a certain query
    def search query
      raise TypeError unless query.is_a? Array or query.is_a? String
      query = [query] if query.is_a? String
      fetch_albums search: { query: query }
    end

    # Return albums from a list of album IDs
    def albums_from_ids ids
      raise TypeError unless ids.is_a? Array
      fetch_albums from_ids: ids
    end

    # Returns a list of changes
    def changes
      records = {}
      comments_query =
        '//ol[@class="commentlist snap_preview"]//div[@class="comment_message"]/p'

      homepage.xpath(comments_query).each do |change|
        id = change.xpath('a/@href').text[6..-1].to_i

        type =
          case change.text
          when /.+? is broken\./        then :broken
          when /.+? has been editted\./ then :edit
          end

        next if type.nil?

        # We're only interested in the latest change
        # to any given album ID.
        records[id] = type
      end

      records.map { |a| Change.new *a }.reverse
    end

    private

    def fetch_albums search: nil, from_ids: nil, offset: 0
      params =
        if    search.is_a? Hash and from_ids.nil?
          params_search search
        elsif search.nil?       and from_ids.is_a? Array
          params_from_ids from_ids
        elsif search.nil?       and from_ids.nil? # fetch the new albums
          params_from_ids [], offset: offset
        else
          raise ArgumentError
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

        album_ids.shift(ALBUMS_PER_PAGE)

        break if album_ids.nil? or album_ids.empty?

        params = params_from_ids(album_ids)
      end

      records
    end

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
        postsPerPage: ALBUMS_PER_PAGE, # absolutely useless
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
end
