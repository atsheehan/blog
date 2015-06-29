helpers do
  require "date"

  def format_date(date)
    Date.parse(date).strftime("%B %-d, %Y")
  end

  def articles
    sitemap.resources.select { |res| res.path.start_with?("article") }
  end
end

set :css_dir, "css"
set :images_dir, "images"
set :build_dir, "build/foobarium"

configure :build do
  activate :minify_css
  activate :asset_hash
  activate :relative_assets
end
