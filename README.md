## Usage
```ruby
scraper = Dojin::Scraper.new 'example.com'
scraper.fetch_albums from_ids: scraper.changes.select { |a| a.type == :edit }.map(&:id)
scraper.albums /Shibayan/
```
