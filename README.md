## Usage
```ruby
scraper = Dojin::Scraper.new 'example.com'
scraper.albums_from_ids scraper.changes.select { |a| a.type == :edit }.map(&:id)
scraper.albums_by /Shibayan/
```
